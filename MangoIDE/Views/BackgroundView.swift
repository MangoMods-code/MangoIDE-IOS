import SwiftUI
import UIKit
import AVFoundation
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

/// Picture, GIF, video or Live Photo shown behind the whole app.
struct AppBackground: View {
    let url: URL
    let kind: String
    let fit: String
    let dim: Double
    let frost: Double
    let animate: Bool

    var body: some View {
        ZStack {
            Color.black
            Group {
                switch kind {
                case "video": VideoBackground(url: url, fill: fit == "fill", playing: animate)
                case "gif": GIFBackground(url: url, fill: fit == "fill", playing: animate)
                default: StillBackground(url: url, fill: fit == "fill")
                }
            }
            if frost > 0.01 {
                Rectangle().fill(.ultraThinMaterial).opacity(frost)
            }
            if dim > 0.01 {
                Color.black.opacity(dim)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: Still image (downsampled so a huge photo doesn't eat memory)

struct StillBackground: UIViewRepresentable {
    let url: URL
    let fill: Bool

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.clipsToBounds = true
        load(into: v)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        v.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        if v.accessibilityIdentifier != url.path { load(into: v) }
    }

    private func load(into v: UIImageView) {
        v.accessibilityIdentifier = url.path
        v.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        let u = url
        DispatchQueue.global(qos: .userInitiated).async {
            let img = BackgroundStore.downsample(u, maxPixels: 2400)
            DispatchQueue.main.async { if v.accessibilityIdentifier == u.path { v.image = img } }
        }
    }
}

// MARK: GIF (frames decoded one at a time by ImageIO)

struct GIFBackground: UIViewRepresentable {
    let url: URL
    let fill: Bool
    let playing: Bool

    func makeUIView(context: Context) -> GIFView {
        let v = GIFView()
        v.clipsToBounds = true
        v.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        v.play(url: url, playing: playing)
        return v
    }

    func updateUIView(_ v: GIFView, context: Context) {
        v.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        v.play(url: url, playing: playing)
    }

    static func dismantleUIView(_ v: GIFView, coordinator: ()) { v.stop() }
}

final class GIFView: UIImageView {
    private var currentURL: URL?
    private var token = 0
    private var isPlaying = false

    func play(url: URL, playing: Bool) {
        if url == currentURL && playing == isPlaying { return }
        stop()
        currentURL = url
        isPlaying = playing
        guard playing else {
            // Show the first frame when paused.
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let first = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                image = UIImage(cgImage: first)
            }
            return
        }
        token += 1
        let mine = token
        _ = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, frame, stop in
            guard let self, self.token == mine else { stop.pointee = true; return }
            self.image = UIImage(cgImage: frame)
        }
    }

    func stop() { token += 1 }
}

// MARK: Video / Live Photo (looping, muted, doesn't interrupt your music)

struct VideoBackground: UIViewRepresentable {
    let url: URL
    let fill: Bool
    let playing: Bool

    func makeUIView(context: Context) -> VideoView {
        let v = VideoView()
        v.load(url)
        v.setFill(fill)
        v.setPlaying(playing)
        return v
    }

    func updateUIView(_ v: VideoView, context: Context) {
        v.load(url)
        v.setFill(fill)
        v.setPlaying(playing)
    }

    static func dismantleUIView(_ v: VideoView, coordinator: ()) { v.teardown() }
}

final class VideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var url: URL?

    func load(_ newURL: URL) {
        guard newURL != url else { return }
        teardown()
        url = newURL
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        let item = AVPlayerItem(url: newURL)
        let p = AVQueuePlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        p.allowsExternalPlayback = false
        looper = AVPlayerLooper(player: p, templateItem: item)
        player = p
        playerLayer.player = p
    }

    func setFill(_ fill: Bool) {
        playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    func setPlaying(_ on: Bool) {
        if on { player?.play() } else { player?.pause() }
    }

    func teardown() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        playerLayer.player = nil
        url = nil
    }
}

// MARK: - Picking and storing backgrounds

enum BackgroundStore {
    static func downsample(_ url: URL, maxPixels: CGFloat) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        let thumbOpts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                         kCGImageSourceCreateThumbnailWithTransform: true,
                         kCGImageSourceShouldCacheImmediately: true,
                         kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func kind(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "gif" { return "gif" }
        if let t = UTType(filenameExtension: ext), t.conforms(to: .movie) || t.conforms(to: .video) { return "video" }
        return "image"
    }

    /// Moves/copies a file into the app's Backgrounds folder and switches the background to it.
    static func install(_ source: URL, kind: String? = nil, move: Bool) throws {
        let fm = FileManager.default
        let dir = AppSettings.backgroundsFolder
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "dat" : source.pathExtension.lowercased()
        let name = "background-\(UUID().uuidString.prefix(8)).\(ext)"
        let dest = dir.appendingPathComponent(name)
        if move { try fm.moveItem(at: source, to: dest) } else { try fm.copyItem(at: source, to: dest) }
        let k = kind ?? self.kind(for: dest)
        DispatchQueue.main.async {
            let s = AppSettings.shared
            let old = s.backgroundURL
            s.backgroundFile = name
            s.backgroundKind = k
            if let old, old != dest { try? fm.removeItem(at: old) }
        }
    }

    static func remove() {
        let s = AppSettings.shared
        if let old = s.backgroundURL { try? FileManager.default.removeItem(at: old) }
        s.backgroundKind = "none"
        s.backgroundFile = ""
    }

    // MARK: Photos picker (images, GIFs, videos and Live Photos)

    fileprivate final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
        let done: (Error?) -> Void
        init(done: @escaping (Error?) -> Void) { self.done = done }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            BackgroundStore.activePicker = nil
            guard let provider = results.first?.itemProvider else { return }
            BackgroundStore.handle(provider, done: done)
        }
    }

    fileprivate static var activePicker: PickerDelegate?

    static func pickFromPhotos(done: @escaping (Error?) -> Void) {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .livePhotos, .videos])
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        let delegate = PickerDelegate(done: done)
        activePicker = delegate
        picker.delegate = delegate
        FilePicker.topViewController()?.present(picker, animated: true)
    }

    private static func finish(_ done: @escaping (Error?) -> Void, _ error: Error?) {
        DispatchQueue.main.async { done(error) }
    }

    private static func handle(_ provider: NSItemProvider, done: @escaping (Error?) -> Void) {
        let types = provider.registeredTypeIdentifiers
        // Live Photo: use its video part so it actually moves.
        if provider.canLoadObject(ofClass: PHLivePhoto.self) {
            provider.loadObject(ofClass: PHLivePhoto.self) { obj, _ in
                if let live = obj as? PHLivePhoto,
                   let res = PHAssetResource.assetResources(for: live).first(where: { $0.type == .pairedVideo }) {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                    PHAssetResourceManager.default().writeData(for: res, toFile: tmp, options: nil) { err in
                        if err == nil, (try? install(tmp, kind: "video", move: true)) != nil { finish(done, nil) }
                        else { loadBundleOrStill(provider, done: done) }
                    }
                } else {
                    loadBundleOrStill(provider, done: done)
                }
            }
            return
        }
        if types.contains(UTType.gif.identifier) {
            loadFile(provider, UTType.gif.identifier, kind: "gif", done: done); return
        }
        if let movie = types.first(where: { UTType($0)?.conforms(to: .movie) == true }) {
            loadFile(provider, movie, kind: "video", done: done); return
        }
        if let image = types.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            loadFile(provider, image, kind: "image", done: done); return
        }
        finish(done, ArchiveError.failed("That item can't be used as a background."))
    }

    /// Fallbacks for Live Photos: the bundle (which holds the .mov), then the still photo.
    private static func loadBundleOrStill(_ provider: NSItemProvider, done: @escaping (Error?) -> Void) {
        let bundleType = "com.apple.live-photo-bundle"
        if provider.hasItemConformingToTypeIdentifier(bundleType) {
            provider.loadFileRepresentation(forTypeIdentifier: bundleType) { url, _ in
                if let url,
                   let mov = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                    .first(where: { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }),
                   (try? install(mov, kind: "video", move: false)) != nil {
                    finish(done, nil)
                } else {
                    loadStill(provider, done: done)
                }
            }
        } else {
            loadStill(provider, done: done)
        }
    }

    private static func loadStill(_ provider: NSItemProvider, done: @escaping (Error?) -> Void) {
        if let image = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            loadFile(provider, image, kind: "image", done: done)
        } else {
            finish(done, ArchiveError.failed("Couldn't read that Live Photo."))
        }
    }

    private static func loadFile(_ provider: NSItemProvider, _ type: String, kind: String, done: @escaping (Error?) -> Void) {
        provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
            // The file is deleted when this returns, so copy it now.
            guard let url else { finish(done, error ?? ArchiveError.failed("Couldn't load that item.")); return }
            do { try install(url, kind: kind, move: false); finish(done, nil) }
            catch { finish(done, error) }
        }
    }

    static func pickFromFiles(done: @escaping (Error?) -> Void) {
        FilePicker.present(types: [.gif, .movie, .image], multiple: false, asCopy: true) { urls in
            guard let u = urls.first else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do { try install(u, move: true); finish(done, nil) }
                catch { finish(done, error) }
            }
        }
    }
}

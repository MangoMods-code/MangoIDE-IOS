import SwiftUI
import UIKit
import PDFKit
import AVKit
import QuickLook
import WebKit
import UniformTypeIdentifiers

/// How a file that isn't editable text gets shown.
enum FileViewerKind: Equatable {
    case image, gif, svg, pdf, media, quickLook, hex

    /// Picked from the file type without reading the file, so big videos never get loaded into memory.
    static func forURL(_ url: URL) -> FileViewerKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "svg" { return nil }          // SVG is text: edit it, preview with ▶
        if ext == "gif" { return .gif }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) { return .media }
        let quickLookTypes: [UTType] = [.spreadsheet, .presentation, .rtf, .rtfd, .usdz, .threeDContent, .font, .epub]
        if quickLookTypes.contains(where: { type.conforms(to: $0) }) { return .quickLook }
        if ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "usdz", "reality", "ttf", "otf", "woff", "woff2", "epub", "ics", "vcf"].contains(ext) { return .quickLook }
        if ArchiveService.isArchive(url) || ["ipa", "app", "dmg", "exe", "dll", "so", "dylib", "o", "a", "class", "jar", "wasm", "bin", "dat", "sqlite", "db", "sqlite3", "realm"].contains(ext) { return .hex }
        return nil
    }
}

struct FileViewer: View {
    let url: URL
    let kind: FileViewerKind
    @EnvironmentObject var router: Router
    @State private var showQuickLook = false

    private var sizeText: String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: FileIcons.icon(for: url, isDirectory: false, open: false).0)
                Text("\(UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? url.pathExtension.uppercased()) · \(sizeText)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if ArchiveService.isArchive(url) {
                    Button { router.extractConfirm = url } label: { Label("Extract", systemImage: "arrow.up.bin") }.font(.caption)
                }
                if kind != .quickLook {
                    Button { showQuickLook = true } label: { Image(systemName: "eye") }
                }
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .chromeBackground()
            Divider()
            Group {
                switch kind {
                case .image: ZoomImageView(url: url, animated: false)
                case .gif: ZoomImageView(url: url, animated: true)
                case .svg: SVGView(url: url)
                case .pdf: PDFViewer(url: url)
                case .media: MediaPlayerView(url: url)
                case .quickLook: QuickLookView(url: url)
                case .hex: HexView(url: url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showQuickLook) { QuickLookView(url: url).ignoresSafeArea() }
    }
}

// MARK: Images (pinch to zoom, double-tap to zoom)

struct ZoomImageView: UIViewRepresentable {
    let url: URL
    let animated: Bool

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.delegate = context.coordinator
        scroll.backgroundColor = .secondarySystemBackground
        let iv = GIFView()
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            iv.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            iv.centerXAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerYAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: iv.widthAnchor),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: iv.heightAnchor)
        ])
        context.coordinator.imageView = iv
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        if animated {
            iv.play(url: url, playing: true)
        } else {
            let u = url
            DispatchQueue.global(qos: .userInitiated).async {
                let img = BackgroundStore.downsample(u, maxPixels: 4096)
                DispatchQueue.main.async { iv.image = img }
            }
        }
        return scroll
    }

    func updateUIView(_ v: UIScrollView, context: Context) {}

    static func dismantleUIView(_ v: UIScrollView, coordinator: Coordinator) { coordinator.imageView?.stop() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: GIFView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let s = g.view as? UIScrollView else { return }
            s.setZoomScale(s.zoomScale > 1 ? 1 : 3, animated: true)
        }
    }
}

struct SVGView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return wv
    }
    func updateUIView(_ wv: WKWebView, context: Context) {}
}

// MARK: PDF

struct PDFViewer: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.usePageViewController(false)
        let u = url
        DispatchQueue.global(qos: .userInitiated).async {
            let doc = PDFDocument(url: u)
            DispatchQueue.main.async { v.document = doc }
        }
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
}

// MARK: Audio / video

struct MediaPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                player = AVPlayer(url: url)
            }
            .onDisappear {
                player?.pause()
                player = nil
                try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            }
    }
}

// MARK: Quick Look (Office docs, Keynote/Pages/Numbers, 3D, fonts, and anything else iOS can preview)

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let q = QLPreviewController()
        q.dataSource = context.coordinator
        return q
    }
    func updateUIViewController(_ q: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

// MARK: Hex (read-only, first 1 MB, rows built lazily)

struct HexView: View {
    let url: URL
    @State private var data = Data()
    @State private var total = 0
    static let limit = 1_048_576

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 1) {
                if total > HexView.limit {
                    Text("Showing the first 1 MB of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)).")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                }
                ForEach(0..<((data.count + 15) / 16), id: \.self) { row in
                    Text(line(row)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(10)
        }
        .onAppear(perform: load)
    }

    private func load() {
        let u = url
        DispatchQueue.global(qos: .userInitiated).async {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var chunk = Data()
            if let h = try? FileHandle(forReadingFrom: u) {
                chunk = (try? h.read(upToCount: HexView.limit)) ?? Data()
                try? h.close()
            }
            DispatchQueue.main.async { data = chunk; total = size }
        }
    }

    private func line(_ row: Int) -> String {
        let start = row * 16
        let end = min(start + 16, data.count)
        let bytes = data[data.startIndex + start ..< data.startIndex + end]
        var hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        hex += String(repeating: "   ", count: 16 - bytes.count)
        let ascii = String(bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return String(format: "%08X  ", start) + hex + "  " + ascii
    }
}

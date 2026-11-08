import Foundation
import ZIPFoundation

enum ArchiveError: LocalizedError {
    case unsupported(String)
    case needsPassword
    case wrongPassword
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return ".\(ext) files can't be opened here. MangoIDE supports .zip and .rar."
        case .needsPassword: return "This archive is password protected."
        case .wrongPassword: return "That password didn't work."
        case .failed(let m): return m
        }
    }
}

/// Extracting .zip/.rar and making .zip files. Work runs off the main thread; results come back on it.
enum ArchiveService {
    static let extractable: Set<String> = ["zip", "rar", "cbz", "cbr", "mcaddon", "mcpack", "mcworld", "mctemplate"]

    static func isArchive(_ url: URL) -> Bool { extractable.contains(url.pathExtension.lowercased()) }

    private static let queue = DispatchQueue(label: "mango.archives", qos: .userInitiated)

    /// Extracts into a new folder next to the archive (or into `dir`), named after the archive.
    static func extract(_ archive: URL, into dir: URL? = nil, password: String? = nil,
                        completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            let scoped = archive.startAccessingSecurityScopedResource()
            defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
            let parent = dir ?? archive.deletingLastPathComponent()
            let base = archive.deletingPathExtension().lastPathComponent
            let dest = Workspace.shared.uniqueURL(in: parent, name: base)
            do {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                switch archive.pathExtension.lowercased() {
                case "zip", "cbz", "mcpack", "mcworld", "mctemplate":
                    try FileManager.default.unzipItem(at: archive, to: dest)
                case "mcaddon":
                    try FileManager.default.unzipItem(at: archive, to: dest)
                    Minecraft.expandNested(in: dest)
                case "rar", "cbr":
                    try RarExtractor.extract(archive, to: dest, password: password)
                default:
                    throw ArchiveError.unsupported(archive.pathExtension)
                }
                let result = flattenSingleFolder(dest)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                try? FileManager.default.removeItem(at: dest)
                let mapped = mapZipError(error)
                DispatchQueue.main.async { completion(.failure(mapped)) }
            }
        }
    }

    /// Zips one or more files/folders into `<name>.zip` inside `dir`.
    static func compress(_ items: [URL], name: String? = nil, into dir: URL? = nil,
                         completion: @escaping (Result<URL, Error>) -> Void) {
        guard let first = items.first else { return }
        queue.async {
            let fm = FileManager.default
            let parent = dir ?? first.deletingLastPathComponent()
            let baseName = name ?? (items.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive")
            let zipURL = Workspace.shared.uniqueURL(in: parent, name: baseName + ".zip")
            do {
                if items.count == 1 {
                    try fm.zipItem(at: first, to: zipURL, shouldKeepParent: true, compressionMethod: .deflate)
                } else {
                    // Gather everything in a temporary folder so the zip has one clean top level.
                    let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                    defer { try? fm.removeItem(at: staging) }
                    for u in items {
                        try fm.copyItem(at: u, to: staging.appendingPathComponent(u.lastPathComponent))
                    }
                    try fm.zipItem(at: staging, to: zipURL, shouldKeepParent: false, compressionMethod: .deflate)
                }
                DispatchQueue.main.async { completion(.success(zipURL)) }
            } catch {
                try? fm.removeItem(at: zipURL)
                DispatchQueue.main.async { completion(.failure(ArchiveError.failed("Couldn't make the zip: \(error.localizedDescription)"))) }
            }
        }
    }

    /// If an archive held exactly one folder (very common), drop the extra level.
    private static func flattenSingleFolder(_ dest: URL) -> URL {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let junk = (try? fm.contentsOfDirectory(atPath: dest.path))?.filter { $0 == "__MACOSX" } ?? []
        for j in junk { try? fm.removeItem(at: dest.appendingPathComponent(j)) }
        let real = items.filter { $0.lastPathComponent != "__MACOSX" }
        guard real.count == 1, Workspace.shared.isDirectory(real[0]) else { return dest }
        let inner = real[0]
        let target = Workspace.shared.uniqueURL(in: dest.deletingLastPathComponent(), name: inner.lastPathComponent)
        do {
            try fm.moveItem(at: inner, to: target)
            try fm.removeItem(at: dest)
            return target
        } catch {
            return dest
        }
    }

    private static func mapZipError(_ error: Error) -> Error {
        if error is ArchiveError { return error }
        let text = String(describing: error)
        if text.contains("unsupported") || text.contains("Encrypt") || text.contains("encrypt") {
            return ArchiveError.failed("This zip is password protected or uses a format MangoIDE can't open yet.")
        }
        return ArchiveError.failed("Couldn't extract it: \(error.localizedDescription)")
    }

    /// Makes a path from inside an archive safe to write under `root` (no "..", no absolute paths).
    static func safeURL(for entryPath: String, under root: URL) -> URL? {
        let parts = entryPath.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !parts.isEmpty else { return nil }
        var url = root
        for p in parts { url.appendPathComponent(p) }
        return url
    }
}

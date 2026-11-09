import Foundation

/// Unsaved edits kept privately (in the app's Application Support folder, not your files) so they
/// survive the app closing. Your real file only changes when you save.
enum DraftStore {
    private struct Draft: Codable { let path: String; let text: String; let savedAt: Date }
    private static let queue = DispatchQueue(label: "mango.drafts", qos: .utility)

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Drafts", isDirectory: true)
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    private static func file(for url: URL) -> URL {
        var h: UInt64 = 5381
        for b in key(url).utf8 { h = (h &* 33) ^ UInt64(b) }
        return folder.appendingPathComponent(String(h, radix: 36) + ".json")
    }

    static func save(_ text: String, for url: URL, sync: Bool = false) {
        let target = file(for: url), path = key(url)
        let work = {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(Draft(path: path, text: text, savedAt: Date())) {
                try? data.write(to: target, options: .atomic)
            }
        }
        if sync { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    static func load(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: file(for: url)),
              let d = try? JSONDecoder().decode(Draft.self, from: data), d.path == key(url) else { return nil }
        return d.text
    }

    static func remove(for url: URL) {
        let target = file(for: url)
        queue.async { try? FileManager.default.removeItem(at: target) }
    }
}

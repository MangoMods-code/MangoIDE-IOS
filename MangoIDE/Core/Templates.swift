import Foundation

/// A ready-made project. Templates ship inside the app as templates-<language>.json files, which are
/// built from the readable packs in the repo's templates/ folder (see tools/build_templates.py).
struct ProjectTemplate: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let icon: String
    let summary: String
    let language: String
    let entry: String
    let files: [String: String]

    var sortedPaths: [String] {
        files.keys.sorted { a, b in
            if a == entry { return true }
            if b == entry { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}

enum TemplateError: LocalizedError {
    case badName, exists(String)
    var errorDescription: String? {
        switch self {
        case .badName: return "Give the project a name (without / in it)."
        case .exists(let n): return "There's already a folder called \(n) there."
        }
    }
}

enum TemplateLibrary {
    /// Every bundled template. Loaded once, the first time it's needed.
    static let all: [ProjectTemplate] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        var out: [ProjectTemplate] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.lastPathComponent.hasPrefix("templates-") {
            if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([ProjectTemplate].self, from: data) { out += list }
        }
        return out
    }()

    static func languageName(_ id: String) -> String {
        ["python": "Python", "tweak": "iOS Tweaks", "javascript": "JavaScript", "html": "Web", "cpp": "C++", "csharp": "C#"][id]
            ?? id.prefix(1).uppercased() + id.dropFirst()
    }

    /// A name that's safe inside code and file names: "My Tweak!" → "MyTweak".
    static func identifier(_ name: String) -> String {
        var s = String(name.unicodeScalars.filter { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" }.map(Character.init))
        if s.isEmpty { s = "MyProject" }
        if s.first?.isNumber == true { s = "_" + s }
        return s
    }

    /// Makes the project folder and its files. Returns the folder and the file to open first.
    static func create(_ t: ProjectTemplate, named raw: String, in parent: URL) throws -> (folder: URL, entry: URL) {
        let fm = FileManager.default
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw TemplateError.badName }
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: folder.path) else { throw TemplateError.exists(name) }
        let ident = identifier(name)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for (path, content) in t.files {
                let rel = path.replacingOccurrences(of: "__PROJECT__", with: ident)
                guard SafePath.ok(rel) else { continue }
                let url = folder.appendingPathComponent(rel)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.replacingOccurrences(of: "__PROJECT__", with: ident).write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        let entryRel = t.entry.replacingOccurrences(of: "__PROJECT__", with: ident)
        let entry = folder.appendingPathComponent(entryRel)
        // ▶ runs the template's main file no matter which file is open.
        if ExtensionManager.shared.language(for: entry).runner != nil {
            var config = RunConfig()
            config.entry = entryRel
            config.save(folder)
        }
        return (folder, entry)
    }
}

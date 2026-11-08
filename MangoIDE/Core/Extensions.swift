import Foundation
import SwiftUI

struct Snippet: Codable, Identifiable, Hashable {
    var name: String
    /// Language id, or "*" for every language.
    var language: String
    var body: String
    var prefix: String?
    var id: String { language + "/" + name }
}

/// The JSON file every extension ships as `extension.json`.
struct ExtensionManifest: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var version: String
    var author: String?
    var description: String?
    var themes: [EditorTheme]?
    var languages: [LanguageDef]?
    var snippets: [Snippet]?

    var summary: String {
        var parts: [String] = []
        if let t = themes, !t.isEmpty { parts.append("\(t.count) theme\(t.count == 1 ? "" : "s")") }
        if let l = languages, !l.isEmpty { parts.append("\(l.count) language\(l.count == 1 ? "" : "s")") }
        if let s = snippets, !s.isEmpty { parts.append("\(s.count) snippet\(s.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "No contributions" : parts.joined(separator: " · ")
    }
}

struct InstalledExtension: Identifiable, Hashable {
    var manifest: ExtensionManifest
    var folder: URL
    var enabled: Bool
    var id: String { manifest.id }
}

enum ExtensionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let m): return m }
    }
}

final class ExtensionManager: ObservableObject {
    static let shared = ExtensionManager()

    @Published private(set) var installed: [InstalledExtension] = []
    @Published var lastError: String?

    private var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "ext.disabled") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ext.disabled") }
    }

    var folder: URL { Workspace.shared.extensionsFolder }

    private var active: [ExtensionManifest] {
        guard AppSettings.shared.extensionsEnabled else { return [] }
        return installed.filter { $0.enabled }.map { $0.manifest }
    }

    // MARK: Registry lookups used by the whole app

    var allThemes: [EditorTheme] {
        ThemeLibrary.builtIn + active.flatMap { $0.themes ?? [] }
    }

    func theme(id: String) -> EditorTheme {
        allThemes.first { $0.id == id } ?? ThemeLibrary.builtIn[0]
    }

    var allLanguages: [LanguageDef] {
        active.flatMap { $0.languages ?? [] } + LanguageLibrary.builtIn
    }

    func language(for url: URL?) -> LanguageDef {
        guard let url else { return .plain }
        let ext = url.pathExtension
        let name = url.lastPathComponent.lowercased()
        if name == "dockerfile" || name == "makefile" { return allLanguages.first { $0.id == "shell" } ?? .plain }
        if ext.isEmpty { return .plain }
        return allLanguages.first { $0.extensions.contains(ext) }
            ?? allLanguages.first { $0.extensions.contains(ext.lowercased()) }
            ?? .plain
    }

    func language(id: String) -> LanguageDef {
        allLanguages.first { $0.id == id } ?? .plain
    }

    func snippets(for language: LanguageDef) -> [Snippet] {
        let all = BuiltInSnippets.all + active.flatMap { $0.snippets ?? [] }
        return all.filter { $0.language == language.id || $0.language == "*" }
    }

    // MARK: Install / remove

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var found: [InstalledExtension] = []
        let off = disabled
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items {
            var manifestURL = item
            var isDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            if isDir.boolValue { manifestURL = item.appendingPathComponent("extension.json") }
            else if item.pathExtension.lowercased() != "json" { continue }
            guard let data = try? Data(contentsOf: manifestURL),
                  let m = try? JSONDecoder().decode(ExtensionManifest.self, from: data) else { continue }
            found.append(InstalledExtension(manifest: m, folder: isDir.boolValue ? item : manifestURL, enabled: !off.contains(m.id)))
        }
        SyntaxHighlighter.clearCache()
        installed = found.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }

    func setEnabled(_ ext: InstalledExtension, _ on: Bool) {
        var d = disabled
        if on { d.remove(ext.id) } else { d.insert(ext.id) }
        disabled = d
        reload()
    }

    @discardableResult
    func install(data: Data) throws -> ExtensionManifest {
        let m: ExtensionManifest
        do { m = try JSONDecoder().decode(ExtensionManifest.self, from: data) }
        catch { throw ExtensionError.invalid("That file isn't a valid MangoIDE extension: \(error.localizedDescription)") }
        let safeID = m.id.replacingOccurrences(of: "/", with: "-")
        guard !safeID.isEmpty else { throw ExtensionError.invalid("The extension needs an id.") }
        let dir = folder.appendingPathComponent(safeID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("extension.json"), options: .atomic)
        reload()
        return m
    }

    func install(from remote: URL, completion: @escaping (Result<ExtensionManifest, Error>) -> Void) {
        URLSession.shared.dataTask(with: remote) { data, _, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                guard let data else { completion(.failure(ExtensionError.invalid("Nothing downloaded."))); return }
                do { completion(.success(try self.install(data: data))) }
                catch { completion(.failure(error)) }
            }
        }.resume()
    }

    func remove(_ ext: InstalledExtension) {
        try? FileManager.default.removeItem(at: ext.folder)
        reload()
    }

    /// Writes a working example so people can see (and copy) the format.
    func createSample() {
        let sample = ExtensionManifest(
            id: "mango.sample-pack", name: "Sample Pack", version: "1.0.0", author: "MangoIDE",
            description: "An example extension: one theme, one language and a few snippets. Edit extension.json to make your own.",
            themes: [EditorTheme(id: "sunset", name: "Sunset", isDark: true, background: "#2B1B2E", foreground: "#F5E6E8",
                                 gutterBackground: "#24162A", gutterForeground: "#7A5C80", gutterActive: "#FF9E64",
                                 selection: "#FF9E6440", cursor: "#FF9E64", keyword: "#FF6E91", type: "#FFD580",
                                 string: "#B5E8A0", number: "#C9A0FF", comment: "#7A6680", function: "#7FD1FF",
                                 attribute: "#FF9E64", tag: "#FF6E91", panel: "#21141F")],
            languages: [LanguageDef(id: "mango-script", name: "MangoScript", extensions: ["mango"],
                                    keywords: ["peel", "slice", "if", "else", "loop", "give"],
                                    literals: ["ripe", "raw"], lineComment: "//", quotes: ["\""])],
            snippets: [Snippet(name: "TODO comment", language: "*", body: "// TODO: "),
                       Snippet(name: "Python main guard", language: "python", body: "if __name__ == \"__main__\":\n    main()\n")])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(sample) { _ = try? install(data: data) }
    }
}

enum BuiltInSnippets {
    static let all: [Snippet] = [
        Snippet(name: "Function", language: "swift", body: "func name() {\n    \n}\n"),
        Snippet(name: "For loop", language: "swift", body: "for i in 0..<10 {\n    print(i)\n}\n"),
        Snippet(name: "Struct", language: "swift", body: "struct Name {\n    var value: Int\n}\n"),
        Snippet(name: "Function", language: "python", body: "def name():\n    pass\n"),
        Snippet(name: "For loop", language: "python", body: "for i in range(10):\n    print(i)\n"),
        Snippet(name: "Class", language: "python", body: "class Name:\n    def __init__(self):\n        pass\n"),
        Snippet(name: "Try/except", language: "python", body: "try:\n    pass\nexcept Exception as e:\n    print(e)\n"),
        Snippet(name: "Function", language: "javascript", body: "function name() {\n  \n}\n"),
        Snippet(name: "Arrow function", language: "javascript", body: "const name = () => {\n  \n};\n"),
        Snippet(name: "For loop", language: "javascript", body: "for (let i = 0; i < 10; i++) {\n  console.log(i);\n}\n"),
        Snippet(name: "Fetch", language: "javascript", body: "const res = await fetch(url);\nconst data = await res.json();\n"),
        Snippet(name: "Function", language: "typescript", body: "function name(): void {\n  \n}\n"),
        Snippet(name: "Interface", language: "typescript", body: "interface Name {\n  id: number;\n}\n"),
        Snippet(name: "Main method", language: "java", body: "public static void main(String[] args) {\n    \n}\n"),
        Snippet(name: "For loop", language: "java", body: "for (int i = 0; i < 10; i++) {\n    System.out.println(i);\n}\n"),
        Snippet(name: "For loop", language: "c", body: "for (int i = 0; i < 10; i++) {\n    printf(\"%d\\n\", i);\n}\n"),
        Snippet(name: "For loop", language: "cpp", body: "for (int i = 0; i < 10; i++) {\n    std::cout << i << std::endl;\n}\n"),
        Snippet(name: "Function", language: "go", body: "func name() {\n\t\n}\n"),
        Snippet(name: "If err", language: "go", body: "if err != nil {\n\treturn err\n}\n"),
        Snippet(name: "Function", language: "rust", body: "fn name() {\n    \n}\n"),
        Snippet(name: "Match", language: "rust", body: "match value {\n    _ => {}\n}\n"),
        Snippet(name: "Function", language: "lua", body: "local function name()\n  \nend\n"),
        Snippet(name: "HTML page", language: "html", body: "<!DOCTYPE html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n  <title></title>\n</head>\n<body>\n  \n</body>\n</html>\n"),
        Snippet(name: "Div", language: "html", body: "<div class=\"\">\n  \n</div>\n"),
        Snippet(name: "Flex center", language: "css", body: "display: flex;\nalign-items: center;\njustify-content: center;\n"),
        Snippet(name: "Code block", language: "markdown", body: "```\n\n```\n"),
        Snippet(name: "Table", language: "markdown", body: "| Column | Column |\n| --- | --- |\n| Cell | Cell |\n"),
        Snippet(name: "TODO", language: "*", body: "TODO: "),
        Snippet(name: "Date", language: "*", body: "DATE")
    ]
}

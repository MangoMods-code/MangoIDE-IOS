import Foundation
import JavaScriptCore
import UIKit

// Smarter editing: error checking, autocomplete words, symbols (outline / go to definition) and formatting.

// MARK: - Runner requests

enum RunnerAPI {
    static var isConfigured: Bool { !AppSettings.shared.runnerURL.trimmingCharacters(in: .whitespaces).isEmpty }

    static func request(_ path: String, body: [String: Any]? = nil, method: String = "POST", timeout: TimeInterval = 30) -> URLRequest? {
        guard let url = RunService.runnerEndpoint(AppSettings.shared.runnerURL, path: path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        RunService.authorize(&req)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    static func json(_ req: URLRequest) async throws -> (Int, [String: Any]) {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }
}

// MARK: - Problems (error checking)

struct Diagnostic: Hashable, Identifiable {
    enum Severity: String { case error, warning, info }
    let line: Int        // 1-based
    let col: Int         // 1-based
    let severity: Severity
    let message: String
    var id: String { "\(line):\(col):\(message)" }
}

/// Checks files for errors a moment after you stop typing.
/// JSON and JavaScript are checked on the phone; Python, C, C++, Go, Rust, Swift, Java, Ruby, PHP, Lua,
/// shell and Perl are checked by your runner server when one is set up.
final class DiagnosticsCenter {
    static let shared = DiagnosticsCenter()
    static let localLanguages: Set<String> = ["json", "javascript"]
    static let runnerLanguages: Set<String> = ["python", "javascript", "c", "c++", "go", "rust", "swift", "java", "ruby", "php", "lua", "bash", "perl"]

    private var work: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var generation: [ObjectIdentifier: Int] = [:]
    private let queue = DispatchQueue(label: "mango.diagnostics", qos: .utility)
    private let known = NSHashTable<EditorDocument>.weakObjects()

    /// Settings changed: check every open file again.
    static func recheckAll() {
        DispatchQueue.main.async { for doc in shared.known.allObjects { shared.schedule(doc, delay: 0.2) } }
    }

    func schedule(_ doc: EditorDocument, delay: Double = 1.2) {
        known.add(doc)
        let key = ObjectIdentifier(doc)
        work[key]?.cancel()
        guard AppSettings.shared.checkErrors, !doc.isBinary else {
            if !doc.diagnostics.isEmpty { doc.setDiagnostics([]) }
            return
        }
        let item = DispatchWorkItem { [weak self, weak doc] in
            guard let self, let doc else { return }
            self.run(doc)
        }
        work[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func run(_ doc: EditorDocument) {
        let key = ObjectIdentifier(doc)
        let gen = (generation[key] ?? 0) + 1
        generation[key] = gen
        let lang = ExtensionManager.shared.language(for: doc.url)
        let text = doc.text
        let name = doc.name
        guard (text as NSString).length < 1_000_000 else { doc.setDiagnostics([]); return }
        let deliver: ([Diagnostic]) -> Void = { [weak self, weak doc] list in
            DispatchQueue.main.async {
                guard let self, let doc, self.generation[key] == gen, doc.text == text else { return }
                doc.setDiagnostics(list)
            }
        }
        if lang.id == "json" {
            queue.async { deliver(Self.checkJSON(text)) }
        } else if lang.id == "javascript" && !(RunnerAPI.isConfigured && AppSettings.shared.checkWithRunner) {
            queue.async { deliver(Self.checkJS(text)) }
        } else if let runner = lang.runner, Self.runnerLanguages.contains(runner) || Self.runnerLanguages.contains(lang.id),
                  RunnerAPI.isConfigured, AppSettings.shared.checkWithRunner {
            let language = Self.runnerLanguages.contains(runner) ? runner : lang.id
            guard let req = RunnerAPI.request("check", body: ["language": language, "files": [["name": name, "content": text]]], timeout: 25) else { return }
            Task {
                guard let reply = try? await RunnerAPI.json(req), reply.0 == 200 else { return }
                deliver(Self.parse(reply.1["diagnostics"]))
            }
        } else if !doc.diagnostics.isEmpty {
            doc.setDiagnostics([])
        }
    }

    static func parse(_ any: Any?) -> [Diagnostic] {
        (any as? [[String: Any]] ?? []).compactMap { d in
            guard let msg = d["message"] as? String else { return nil }
            return Diagnostic(line: (d["line"] as? NSNumber)?.intValue ?? 1, col: (d["col"] as? NSNumber)?.intValue ?? 1,
                              severity: Diagnostic.Severity(rawValue: d["severity"] as? String ?? "error") ?? .error, message: msg)
        }
    }

    static func checkJSON(_ text: String) -> [Diagnostic] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let data = text.data(using: .utf8) else { return [] }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return []
        } catch {
            let ns = error as NSError
            let desc = (ns.userInfo["NSDebugDescription"] as? String) ?? ns.localizedDescription
            var line = 1, col = 1
            if let m = desc.range(of: #"line (\d+), column (\d+)"#, options: .regularExpression) {
                let nums = desc[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if nums.count >= 2 { line = nums[0]; col = nums[1] }
            } else if let m = desc.range(of: #"character (\d+)"#, options: .regularExpression),
                      let offset = Int(desc[m].filter(\.isNumber)) {
                let prefix = (text as NSString).substring(to: min(offset, (text as NSString).length))
                line = prefix.components(separatedBy: "\n").count
                col = (prefix.components(separatedBy: "\n").last?.utf16.count ?? 0) + 1
            }
            let clean = desc.replacingOccurrences(of: #"\s*around line \d+, column \d+\.?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*around character \d+\.?"#, with: "", options: .regularExpression)
            return [Diagnostic(line: line, col: col, severity: .error, message: clean.isEmpty ? "Invalid JSON" : clean)]
        }
    }

    /// Syntax check without running anything.
    static func checkJS(_ text: String) -> [Diagnostic] {
        guard let ctx = JSGlobalContextCreate(nil) else { return [] }
        defer { JSGlobalContextRelease(ctx) }
        let script = JSStringCreateWithCFString(text as CFString)
        defer { JSStringRelease(script) }
        var exception: JSValueRef?
        if JSCheckScriptSyntax(ctx, script, nil, 1, &exception) { return [] }
        guard let exception, let context = JSContext(jsGlobalContextRef: ctx),
              let value = JSValue(jsValueRef: exception, in: context) else { return [] }
        let line = value.objectForKeyedSubscript("line")?.toInt32() ?? 1
        let col = value.objectForKeyedSubscript("column")?.toInt32() ?? 1
        return [Diagnostic(line: max(1, Int(line)), col: max(1, Int(col)), severity: .error, message: value.toString() ?? "Syntax error")]
    }
}

// MARK: - Autocomplete

enum Completion {
    static func isWordChar(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127
    }

    /// Counts the identifiers in a file (how often each appears), for ranking suggestions.
    static func index(_ text: String) -> [String: Int] {
        let ns = text as NSString
        let length = min(ns.length, 400_000)
        var out: [String: Int] = [:]
        var buf = [unichar](repeating: 0, count: length)
        ns.getCharacters(&buf, range: NSRange(location: 0, length: length))
        var i = 0
        while i < length {
            if isWordChar(buf[i]) && !(buf[i] >= 48 && buf[i] <= 57) {
                let start = i
                while i < length && isWordChar(buf[i]) { i += 1 }
                if i - start >= 3 && i - start <= 60 {
                    let w = String(utf16CodeUnits: Array(buf[start..<i]), count: i - start)
                    out[w, default: 0] += 1
                }
            } else if buf[i] >= 48 && buf[i] <= 57 {
                while i < length && isWordChar(buf[i]) { i += 1 }
            } else { i += 1 }
        }
        return out
    }

    struct Item: Equatable {
        let label: String
        let insert: String
        let isSnippet: Bool
    }

    /// The word being typed just before the cursor.
    static func prefix(in ns: NSString, at caret: Int) -> NSRange? {
        guard caret > 0, caret <= ns.length else { return nil }
        var start = caret
        while start > 0 && isWordChar(ns.character(at: start - 1)) { start -= 1 }
        guard caret - start >= 1, !(ns.character(at: start) >= 48 && ns.character(at: start) <= 57) else { return nil }
        return NSRange(location: start, length: caret - start)
    }

    static func suggestions(prefix: String, words: [String: Int], language: LanguageDef, snippets: [Snippet], limit: Int = 12) -> [Item] {
        let lower = prefix.lowercased()
        var scored: [(Item, Int)] = []
        var seen = Set<String>()
        func consider(_ w: String, _ base: Int) {
            guard w != prefix, w.count > prefix.count || w.lowercased() != lower, !seen.contains(w),
                  w.lowercased().hasPrefix(lower) else { return }
            seen.insert(w)
            var score = base
            if w.hasPrefix(prefix) { score += 1000 }
            score -= w.count
            scored.append((Item(label: w, insert: w, isSnippet: false), score))
        }
        for s in snippets {
            guard let p = s.prefix, p.lowercased().hasPrefix(lower), !seen.contains("snip:" + p) else { continue }
            seen.insert("snip:" + p)
            scored.append((Item(label: p + " …", insert: s.body, isSnippet: true), 5000 + (p.hasPrefix(prefix) ? 1000 : 0)))
        }
        for k in (language.keywords ?? []) + (language.types ?? []) + (language.literals ?? []) { consider(k, 300) }
        for (w, n) in words { consider(w, min(n, 200) * 4) }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

// MARK: - Symbols (outline and go to definition)

struct CodeSymbol: Identifiable, Hashable {
    let name: String
    let kind: String
    let line: Int        // 1-based
    let url: URL?
    var id: String { "\(url?.path ?? ""):\(line):\(name)" }

    var icon: String {
        switch kind {
        case "class", "struct", "actor", "object", "record": return "c.square"
        case "enum": return "e.square"
        case "protocol", "interface", "trait": return "p.square"
        case "type", "typealias": return "t.square"
        case "var", "let", "const", "property": return "v.square"
        case "heading": return "number"
        default: return "f.square"
        }
    }
}

enum Symbols {
    private static let keywordPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:(?:export|default|public|private|protected|internal|fileprivate|open|static|final|abstract|async|override|pub(?:\([a-z]+\))?|inline|virtual|extern|unsafe|const|mutating|nonisolated|@\w+)[ \t]+)*(func|function|def|fn|fun|class|struct|enum|protocol|interface|trait|impl|extension|actor|typealias|type|module|object|record|sub|proc|macro|let|var|const)[ \t]+\*?([A-Za-z_$][\w$]*)"#,
        options: [.anchorsMatchLines])
    // C-style function definitions: "int main(int argc) {" / "static void foo(...)" at the start of a line.
    private static let cFunction = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:[A-Za-z_][\w:<>,*& \t]*[ \t*&]+)([A-Za-z_]\w*)[ \t]*\([^;{}]*\)[ \t]*(?:const[ \t]*)?(?:\{|$)"#,
        options: [.anchorsMatchLines])
    private static let jsAssigned = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:export[ \t]+)?(?:const|let|var)[ \t]+([A-Za-z_$][\w$]*)[ \t]*=[ \t]*(?:async[ \t]*)?(?:function|\([^)]*\)[ \t]*=>|[A-Za-z_$][\w$]*[ \t]*=>)"#,
        options: [.anchorsMatchLines])
    private static let mdHeading = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.+)$"#, options: [.anchorsMatchLines])
    private static let skipNames: Set<String> = ["if", "for", "while", "switch", "return", "else", "catch", "sizeof", "new", "delete", "case"]
    private static let cLike: Set<String> = ["c", "cpp", "objc", "java", "csharp", "go", "dart", "kotlin", "scala", "d", "zig"]

    static func scan(_ text: String, languageID: String, url: URL? = nil) -> [CodeSymbol] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: min(ns.length, 1_000_000))
        var lineStarts: [Int] = [0]
        for i in 0..<full.length where ns.character(at: i) == 10 { lineStarts.append(i + 1) }
        func line(_ loc: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if lineStarts[mid] <= loc { lo = mid } else { hi = mid - 1 } }
            return lo + 1
        }
        var out: [CodeSymbol] = []
        var seenLines = Set<Int>()
        if languageID == "markdown" {
            for m in mdHeading.matches(in: text, range: full) {
                out.append(CodeSymbol(name: ns.substring(with: m.range(at: 2)), kind: "heading", line: line(m.range.location), url: url))
            }
            return out
        }
        for m in keywordPattern.matches(in: text, range: full) {
            let kind = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2))
            let l = line(m.range.location)
            // Only top-level-ish variables (no indent) to keep the outline readable.
            if ["let", "var", "const"].contains(kind) && ns.substring(with: NSRange(location: m.range.location, length: 1)).first?.isWhitespace == true { continue }
            seenLines.insert(l)
            out.append(CodeSymbol(name: name, kind: kind, line: l, url: url))
        }
        if ["javascript", "typescript", "jsx", "tsx"].contains(languageID) {
            for m in jsAssigned.matches(in: text, range: full) {
                let l = line(m.range.location)
                if let i = out.firstIndex(where: { $0.line == l }) { out[i] = CodeSymbol(name: out[i].name, kind: "function", line: l, url: url) }
                else { out.append(CodeSymbol(name: ns.substring(with: m.range(at: 1)), kind: "function", line: l, url: url)) }
            }
        }
        if cLike.contains(languageID) {
            for m in cFunction.matches(in: text, range: full) {
                let l = line(m.range.location)
                let name = ns.substring(with: m.range(at: 1))
                guard !seenLines.contains(l), !skipNames.contains(name) else { continue }
                out.append(CodeSymbol(name: name, kind: "function", line: l, url: url))
            }
        }
        return out.sorted { $0.line < $1.line }
    }

    /// Looks for where `name` is defined: this file first, then the rest of the project.
    static func findDefinition(_ name: String, in project: URL?, current: (text: String, url: URL, language: String)) async -> [CodeSymbol] {
        let here = scan(current.text, languageID: current.language, url: current.url).filter { $0.name == name }
        if !here.isEmpty { return here }
        guard let project else { return [] }
        return await Task.detached(priority: .userInitiated) {
            var found: [CodeSymbol] = []
            for (_, url) in ProjectFiles.textFiles(in: project, limit: 3000) where url != current.url {
                guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(name) else { continue }
                let lang = ExtensionManager.shared.languageID(for: url)
                found += Symbols.scan(text, languageID: lang, url: url).filter { $0.name == name }
                if found.count >= 30 { break }
            }
            return found
        }.value
    }
}

// MARK: - Project files

enum ProjectFiles {
    static let skip: Set<String> = [".git", "node_modules", ".build", "build", "dist", "DerivedData", "__pycache__", ".venv", "venv", "Pods", ".gradle", "target", ".next", "__MACOSX", ".mango"]
    static let maxTextFile = 2_000_000

    /// Text-looking files in a folder (relative path → URL), skipping dependency and build folders.
    static func textFiles(in root: URL, limit: Int = 5000) -> [(String, URL)] {
        var out: [(String, URL)] = []
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return out }
        for case let u as URL in e {
            if skip.contains(u.lastPathComponent) || u.lastPathComponent == ".DS_Store" { e.skipDescendants(); continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true, (v?.fileSize ?? 0) <= maxTextFile else { continue }
            if FileViewerKind.forURL(u) != nil { continue }
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path
            guard p.hasPrefix(rootPath + "/") else { continue }
            out.append((String(p.dropFirst(rootPath.count + 1)), u))
            if out.count >= limit { break }
        }
        return out.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
}

// MARK: - Format Document

enum CodeFormatter {
    /// JSON is formatted on the phone; everything else needs the runner's formatters
    /// (Prettier, clang-format, gofmt, rustfmt, black, shfmt).
    static func format(_ text: String, fileName: String) async throws -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext == "json" {
            guard let data = text.data(using: .utf8) else { throw FormatError.failed("Couldn't read this file.") }
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed])
            return (String(data: out, encoding: .utf8) ?? text) + "\n"
        }
        guard RunnerAPI.isConfigured, let req = RunnerAPI.request("format", body: ["filename": fileName, "content": text], timeout: 30) else {
            throw FormatError.failed("Formatting .\(ext) files needs your runner server (Settings › Run & Console). JSON formats on the phone.")
        }
        let (status, json) = try await RunnerAPI.json(req)
        if status == 404 { throw FormatError.failed("Your runner server needs updating to format code.") }
        guard status == 200, let content = json["content"] as? String else {
            throw FormatError.failed(json["message"] as? String ?? "The formatter didn't work (\(status)).")
        }
        return content
    }

    enum FormatError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
    }
}

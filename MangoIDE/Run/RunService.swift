import Foundation
import JavaScriptCore
import SwiftUI

struct ConsoleLine: Identifiable {
    enum Kind { case out, err, info, success }
    let id = UUID()
    let kind: Kind
    let text: String
}

final class ConsoleModel: ObservableObject {
    @Published var lines: [ConsoleLine] = []
    @Published var isVisible = false
    @Published var isRunning = false
    @Published var stdin = ""
    @Published var preview: PreviewItem?

    func clear() { lines = [] }

    func append(_ kind: ConsoleLine.Kind, _ text: String) {
        let add = { self.lines.append(ConsoleLine(kind: kind, text: text)); if self.lines.count > 3000 { self.lines.removeFirst(500) } }
        if Thread.isMainThread { add() } else { DispatchQueue.main.async(execute: add) }
    }

    var plainText: String { lines.map { $0.text }.joined(separator: "\n") }
}

struct PreviewItem: Identifiable {
    let id = UUID()
    let title: String
    let html: String?
    let fileURL: URL?
}

/// Runs the active file: JavaScript on the device, HTML/Markdown as a preview,
/// everything else on a Piston-compatible runner server.
enum RunService {
    static func run(_ doc: EditorDocument, language: LanguageDef, console: ConsoleModel) {
        let s = AppSettings.shared
        if s.saveBeforeRun { doc.save(applyCleanup: false) }
        guard let runner = language.runner else {
            console.isVisible = true
            console.append(.err, "Don't know how to run \(language.name) files yet. You can still edit them.")
            return
        }
        switch runner {
        case "html":
            console.preview = PreviewItem(title: doc.name, html: nil, fileURL: doc.url)
            return
        case "markdown":
            console.preview = PreviewItem(title: doc.name, html: MarkdownHTML.render(doc.text), fileURL: nil)
            return
        default: break
        }
        if s.clearConsoleOnRun { console.clear() }
        if s.showConsoleOnRun { console.isVisible = true }
        s.haptic(.medium)
        console.append(.info, "▶ Running \(doc.name)…")
        console.isRunning = true
        let start = Date()
        let finish: (Bool) -> Void = { ok in
            DispatchQueue.main.async {
                console.isRunning = false
                if s.showExecutionTime {
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    console.append(ok ? .success : .err, ok ? "✓ Finished in \(ms) ms" : "✗ Stopped after \(ms) ms")
                }
            }
        }
        if runner == "js" {
            runJavaScript(doc.text, stdin: console.stdin, strict: s.jsStrictMode, console: console, done: finish)
        } else {
            runRemote(code: doc.text, fileName: doc.name, language: runner, stdin: console.stdin, console: console, done: finish)
        }
    }

    // MARK: JavaScript (on device)

    private static let jsQueue = DispatchQueue(label: "mango.js", qos: .userInitiated)

    static func runJavaScript(_ code: String, stdin: String, strict: Bool, console: ConsoleModel, done: @escaping (Bool) -> Void) {
        jsQueue.async {
            guard let ctx = JSContext() else { done(false); return }
            var failed = false
            ctx.exceptionHandler = { _, ex in
                failed = true
                let line = ex?.objectForKeyedSubscript("line")?.toString() ?? "?"
                console.append(.err, "\(ex?.toString() ?? "Error") (line \(line))")
            }
            let fmt: @convention(block) () -> String = {
                let args = JSContext.currentArguments() as? [JSValue] ?? []
                return args.map { v -> String in
                    if v.isString { return v.toString() }
                    if v.isObject && !v.isNull, let json = JSContext.current()?.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [v, NSNull(), 2]), json.isString {
                        return json.toString()
                    }
                    return v.toString()
                }.joined(separator: " ")
            }
            ctx.setObject(fmt, forKeyedSubscript: "__fmt" as NSString)
            let out: @convention(block) (String) -> Void = { console.append(.out, $0) }
            let err: @convention(block) (String) -> Void = { console.append(.err, $0) }
            ctx.setObject(out, forKeyedSubscript: "__out" as NSString)
            ctx.setObject(err, forKeyedSubscript: "__err" as NSString)
            var inputLines = stdin.components(separatedBy: "\n")
            let readLine: @convention(block) () -> String? = {
                if inputLines.isEmpty { return nil }
                return inputLines.removeFirst()
            }
            ctx.setObject(readLine, forKeyedSubscript: "readLine" as NSString)
            ctx.evaluateScript("""
            var console = {
              log: function() { __out(__fmt.apply(null, arguments)); },
              info: function() { __out(__fmt.apply(null, arguments)); },
              debug: function() { __out(__fmt.apply(null, arguments)); },
              warn: function() { __err("⚠ " + __fmt.apply(null, arguments)); },
              error: function() { __err(__fmt.apply(null, arguments)); },
              table: function(t) { __out(JSON.stringify(t, null, 2)); },
              clear: function() {}
            };
            var prompt = function(msg) { var l = readLine(); return l === undefined ? null : l; };
            var print = console.log;
            var __timers = [];
            var setTimeout = function(fn, ms) { __timers.push({fn: fn, ms: ms || 0}); return __timers.length; };
            var setInterval = function(fn, ms) { __timers.push({fn: fn, ms: ms || 0}); return __timers.length; };
            var clearTimeout = function() {}; var clearInterval = function() {};
            """)
            let source = (strict ? "\"use strict\";\n" : "") + code
            ctx.evaluateScript(source)
            // Run queued timers in order once (enough for simple async demos).
            ctx.evaluateScript("__timers.sort(function(a,b){return a.ms-b.ms}); while (__timers.length) { var t = __timers.shift(); try { t.fn(); } catch (e) { console.error(String(e)); } }")
            done(!failed)
        }
    }

    // MARK: Remote runner (Piston API)

    static func runnerEndpoint(_ base: String, path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return nil }
        if !b.lowercased().hasPrefix("http") { b = "https://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/api/v2/execute") { b = String(b.dropLast("/api/v2/execute".count)) }
        if b.hasSuffix("/api/v2") { b = String(b.dropLast("/api/v2".count)) }
        return URL(string: b + "/api/v2/" + path)
    }

    static func runRemote(code: String, fileName: String, language: String, stdin: String, console: ConsoleModel, done: @escaping (Bool) -> Void) {
        let s = AppSettings.shared
        guard let url = runnerEndpoint(s.runnerURL, path: "execute") else {
            console.append(.err, "No runner server set.")
            console.append(.info, "JavaScript runs on your phone, but \(language) needs a runner server. Add one in Settings › Run (any Piston-compatible server works).")
            done(false)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: max(5, s.runnerTimeout))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&req)
        let body: [String: Any] = [
            "language": language, "version": "*",
            "files": [["name": fileName, "content": code]],
            "stdin": stdin
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error {
                console.append(.err, "Couldn't reach the runner: \(error.localizedDescription)")
                done(false); return
            }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                console.append(.err, "The runner sent back something unexpected (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)).")
                done(false); return
            }
            if let message = json["message"] as? String {
                console.append(.err, message)
                done(false); return
            }
            var ok = true
            if let compile = json["compile"] as? [String: Any] {
                if let out = compile["stdout"] as? String, !out.isEmpty { console.append(.out, out.trimmingCharacters(in: .newlines)) }
                if let err = compile["stderr"] as? String, !err.isEmpty { console.append(.err, err.trimmingCharacters(in: .newlines)); ok = false }
                if let code = compile["code"] as? Int, code != 0 { ok = false }
            }
            if let run = json["run"] as? [String: Any] {
                if let out = run["stdout"] as? String, !out.isEmpty { console.append(.out, out.trimmingCharacters(in: .newlines)) }
                if let err = run["stderr"] as? String, !err.isEmpty { console.append(.err, err.trimmingCharacters(in: .newlines)) }
                if let code = run["code"] as? Int, code != 0 { ok = false; console.append(.info, "Exit code \(code)") }
                if let signal = run["signal"] as? String, !signal.isEmpty { ok = false; console.append(.info, "Stopped by \(signal)") }
            }
            done(ok)
        }.resume()
    }

    static func authorize(_ req: inout URLRequest) {
        let key = AppSettings.shared.runnerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
    }

        static func listRuntimes(completion: @escaping (Result<[String], Error>) -> Void) {
        guard let url = runnerEndpoint(AppSettings.shared.runnerURL, path: "runtimes") else {
            completion(.failure(ExtensionError.invalid("Enter a runner address first."))); return
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        authorize(&req)
        URLSession.shared.dataTask(with: req) { data, resp, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                if (resp as? HTTPURLResponse)?.statusCode == 401 {
                    completion(.failure(ExtensionError.invalid("The runner refused the key. Check the Runner Key field."))); return
                }
                guard let data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    completion(.failure(ExtensionError.invalid("That address didn't answer like a runner server."))); return
                }
                let names = list.compactMap { r -> String? in
                    guard let l = r["language"] as? String else { return nil }
                    return "\(l) \(r["version"] as? String ?? "")"
                }
                completion(.success(names.sorted()))
            }
        }.resume()
    }
}

/// Small Markdown → HTML converter for the preview (headings, lists, code, emphasis, links, quotes).
enum MarkdownHTML {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ s: String) -> String {
        var t = escape(s)
        let rules: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("!\\[([^\\]]*)\\]\\(([^)]+)\\)", "<img alt=\"$1\" src=\"$2\">"),
            ("\\[([^\\]]+)\\]\\(([^)]+)\\)", "<a href=\"$2\">$1</a>"),
            ("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>"),
            ("__([^_]+)__", "<strong>$1</strong>"),
            ("(?<![*\\w])\\*([^*]+)\\*(?!\\*)", "<em>$1</em>"),
            ("~~([^~]+)~~", "<del>$1</del>")
        ]
        for (p, r) in rules {
            t = t.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return t
    }

    static func render(_ md: String) -> String {
        var html = ""
        var inCode = false, inList = false, inOrdered = false, para: [String] = []
        func flushPara() { if !para.isEmpty { html += "<p>" + inline(para.joined(separator: " ")) + "</p>\n"; para = [] } }
        func closeLists() {
            if inList { html += "</ul>\n"; inList = false }
            if inOrdered { html += "</ol>\n"; inOrdered = false }
        }
        for raw in md.components(separatedBy: "\n") {
            let line = raw
            if line.hasPrefix("```") {
                flushPara(); closeLists()
                html += inCode ? "</code></pre>\n" : "<pre><code>"
                inCode.toggle(); continue
            }
            if inCode { html += escape(line) + "\n"; continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flushPara(); closeLists(); continue }
            if let r = t.range(of: "^#{1,6} ", options: .regularExpression) {
                flushPara(); closeLists()
                let level = t[r].count - 1
                html += "<h\(level)>\(inline(String(t[r.upperBound...])))</h\(level)>\n"; continue
            }
            if t == "---" || t == "***" { flushPara(); closeLists(); html += "<hr>\n"; continue }
            if t.hasPrefix("> ") { flushPara(); closeLists(); html += "<blockquote>\(inline(String(t.dropFirst(2))))</blockquote>\n"; continue }
            if let r = t.range(of: "^[-*+] ", options: .regularExpression) {
                flushPara(); if inOrdered { html += "</ol>\n"; inOrdered = false }
                if !inList { html += "<ul>\n"; inList = true }
                html += "<li>\(inline(String(t[r.upperBound...])))</li>\n"; continue
            }
            if let r = t.range(of: "^\\d+\\. ", options: .regularExpression) {
                flushPara(); if inList { html += "</ul>\n"; inList = false }
                if !inOrdered { html += "<ol>\n"; inOrdered = true }
                html += "<li>\(inline(String(t[r.upperBound...])))</li>\n"; continue
            }
            if t.hasPrefix("|") {
                flushPara(); closeLists()
                if t.range(of: "^\\|[\\s:|-]+\\|$", options: .regularExpression) != nil { continue }
                let cells = t.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                html += "<table><tr>" + cells.map { "<td>\(inline($0.trimmingCharacters(in: .whitespaces)))</td>" }.joined() + "</tr></table>\n"
                continue
            }
            para.append(t)
        }
        flushPara(); closeLists()
        if inCode { html += "</code></pre>" }
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; font-family: -apple-system, sans-serif; padding: 16px 20px; line-height: 1.55; max-width: 820px; margin: auto; }
        code { font-family: ui-monospace, Menlo, monospace; background: rgba(127,127,127,.15); padding: 1px 5px; border-radius: 5px; }
        pre { background: rgba(127,127,127,.12); padding: 12px; border-radius: 10px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 4px solid #ff9a1a; margin: 8px 0; padding: 2px 12px; opacity: .85; }
        a { color: #ff8a00; } img { max-width: 100%; } table { border-collapse: collapse; } td { border: 1px solid rgba(127,127,127,.4); padding: 4px 8px; }
        h1, h2 { border-bottom: 1px solid rgba(127,127,127,.25); padding-bottom: 4px; }
        </style></head><body>
        \(html)
        </body></html>
        """
    }
}

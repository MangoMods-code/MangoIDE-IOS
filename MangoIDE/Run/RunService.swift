import Foundation
import JavaScriptCore
import SwiftUI

struct ConsoleLine: Identifiable {
    enum Kind { case out, err, info, success, input }
    let id = UUID()
    let kind: Kind
    var text: String
    /// Continues the previous line (a prompt like "Name? " followed by what you typed).
    var joinsPrevious = false
}

final class ConsoleModel: ObservableObject {
    @Published private(set) var lines: [ConsoleLine] = []
    @Published var isVisible = false
    @Published var isRunning = false
    @Published var stdin = ""
    @Published var preview: PreviewItem?
    /// Set while an interactive program is running on the runner: you can type input to it.
    @Published private(set) var sessionID: String?
    private var lastLineOpen = false

    static let maxLines = 2000
    static let maxLineLength = 4000

    /// Output is collected here and pushed to the screen at most ~20 times a second,
    /// so a program printing thousands of lines can't freeze the app.
    private var pending: [ConsoleLine] = []
    private let lock = NSLock()
    private var flushScheduled = false

    func clear() {
        lock.lock(); pending.removeAll(); lastLineOpen = false; lock.unlock()
        lines = []
    }

    /// Output that arrives in pieces: text without a newline stays on the same line until one comes.
    func write(_ kind: ConsoleLine.Kind, _ chunk: String) {
        guard !chunk.isEmpty else { return }
        var parts = chunk.components(separatedBy: "\n")
        let endsOpen = !chunk.hasSuffix("\n")
        if !endsOpen { parts.removeLast() }
        lock.lock()
        for (i, p) in parts.enumerated() {
            let t = p.count > ConsoleModel.maxLineLength ? String(p.prefix(ConsoleModel.maxLineLength)) + " …" : p
            pending.append(ConsoleLine(kind: kind, text: t, joinsPrevious: i == 0 && lastLineOpen))
        }
        lastLineOpen = endsOpen
        if pending.count > ConsoleModel.maxLines { pending.removeFirst(pending.count - ConsoleModel.maxLines) }
        let needsSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if needsSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.flush() }
        }
    }

    // MARK: Typing into a running program

    func attachSession(_ id: String?) { DispatchQueue.main.async { self.sessionID = id } }

    func sendInput(_ text: String) {
        guard let id = sessionID else { return }
        write(.input, text + "\n")
        RunService.sessionPost(id, "input", ["data": text + "\n"])
    }

    func sendEndOfInput() {
        guard let id = sessionID else { return }
        write(.info, "^D\n")
        RunService.sessionPost(id, "input", ["eof": true])
    }

    func stop() {
        guard let id = sessionID else { return }
        RunService.sessionPost(id, "kill", [:])
    }

    func append(_ kind: ConsoleLine.Kind, _ text: String) {
        var parts = text.components(separatedBy: "\n")
        if parts.count > ConsoleModel.maxLines { parts = Array(parts.suffix(ConsoleModel.maxLines)) }
        let new = parts.map { p -> ConsoleLine in
            let t = p.count > ConsoleModel.maxLineLength ? String(p.prefix(ConsoleModel.maxLineLength)) + " …" : p
            return ConsoleLine(kind: kind, text: t)
        }
        lock.lock()
        lastLineOpen = false
        pending.append(contentsOf: new)
        if pending.count > ConsoleModel.maxLines { pending.removeFirst(pending.count - ConsoleModel.maxLines) }
        let needsSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if needsSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }
        var next = lines
        for line in batch {
            if line.joinsPrevious, var last = next.last {
                last.text += line.text
                next[next.count - 1] = last
            } else {
                next.append(line)
            }
        }
        if next.count > ConsoleModel.maxLines { next.removeFirst(next.count - ConsoleModel.maxLines) }
        lines = next
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
    static func run(_ doc: EditorDocument, language docLanguage: LanguageDef, console: ConsoleModel) {
        let s = AppSettings.shared
        // A project can pick its own entry file, arguments and input (Run Settings).
        let project = Workspace.shared.projectFolder(containing: doc.url)
        let config = project.map(RunConfig.load) ?? RunConfig()
        var target = doc.url
        var code = doc.text
        var language = docLanguage
        if let project, !config.entry.isEmpty {
            let entry = project.appendingPathComponent(config.entry)
            if FileManager.default.fileExists(atPath: entry.path) {
                target = entry
                language = ExtensionManager.shared.language(for: entry)
                if let open = openDocument(entry) { code = open.text } else { code = (try? String(contentsOf: entry, encoding: .utf8)) ?? "" }
            }
        }
        let name = target.lastPathComponent
        if s.saveBeforeRun || language.runner == "html" {
            doc.saveNow()
            if target != doc.url { openDocument(target)?.saveNow() }
        }
        if target.pathExtension.lowercased() == "svg" {
            console.preview = PreviewItem(title: name, html: nil, fileURL: target)
            return
        }
        guard let runner = language.runner else {
            console.isVisible = true
            console.append(.err, "Don't know how to run \(language.name) files yet. You can still edit them.")
            return
        }
        switch runner {
        case "html":
            console.preview = PreviewItem(title: name, html: nil, fileURL: target)
            return
        case "markdown":
            console.preview = PreviewItem(title: name, html: MarkdownHTML.render(code), fileURL: nil)
            return
        case "csv":
            console.preview = PreviewItem(title: name, html: CSVTable.html(code, tabs: target.pathExtension.lowercased() == "tsv"), fileURL: nil)
            return
        default: break
        }
        if let old = console.sessionID { sessionPost(old, "kill", [:]); console.attachSession(nil) }
        if s.clearConsoleOnRun { console.clear() }
        if s.showConsoleOnRun { console.isVisible = true }
        s.haptic(.medium)
        let args = config.argList
        console.append(.info, "▶ Running \(name)" + (args.isEmpty ? "" : " " + args.joined(separator: " ")) + "…")
        console.isRunning = true
        let start = Date()
        let finish: (Bool) -> Void = { ok in
            DispatchQueue.main.async {
                console.isRunning = false
                console.attachSession(nil)
                if s.showExecutionTime {
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    console.append(ok ? .success : .err, ok ? "✓ Finished in \(ms) ms" : "✗ Stopped after \(ms) ms")
                }
            }
        }
        let stdin = config.input.isEmpty ? console.stdin : config.input
        if runner == "js" {
            runJavaScript(code, stdin: stdin, strict: s.jsStrictMode, console: console, done: finish)
            return
        }
        var files: [[String: Any]] = [["name": project.flatMap { relative(target, in: $0) } ?? name, "content": code]]
        if let project, config.includeProjectFiles {
            files += projectFiles(project, excluding: target)
        }
        if s.interactiveRuns {
            runSession(files: files, language: runner, args: args, stdin: stdin, keepNames: project != nil, console: console, done: finish)
        } else {
            runRemote(files: files, language: runner, args: args, stdin: stdin, keepNames: project != nil, console: console, done: finish)
        }
    }

    @discardableResult
    private static func openDocument(_ url: URL) -> EditorDocument? {
        EditorState.current?.documents.values.first { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    private static func relative(_ url: URL, in root: URL) -> String? {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path, p = url.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : nil
    }

    /// The project's other text files (unsaved edits included), so imports between files work.
    private static func projectFiles(_ project: URL, excluding: URL) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var total = 0
        for (path, url) in ProjectFiles.textFiles(in: project, limit: 300) where url.standardizedFileURL != excluding.standardizedFileURL {
            if path.hasPrefix(".mango/") { continue }
            let text = openDocument(url)?.text ?? (try? String(contentsOf: url, encoding: .utf8))
            guard let text else { continue }
            total += text.utf8.count
            if total > 4_000_000 { break }
            out.append(["name": path, "content": text])
        }
        return out
    }

    // MARK: JavaScript (on device)

    /// JavaScriptCore can stop a script that runs too long (e.g. an infinite loop). The function is
    /// exported by the framework but not in the public headers, so it's looked up at runtime.
    private typealias SetLimitFn = @convention(c) (OpaquePointer?, Double, (@convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool)?, UnsafeMutableRawPointer?) -> Void
    private static let setTimeLimit: SetLimitFn? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(sym, to: SetLimitFn.self)
    }()

    static func runJavaScript(_ code: String, stdin: String, strict: Bool, console: ConsoleModel, done: @escaping (Bool) -> Void) {
        // Each run gets its own queue so one stuck script can never block the next run.
        DispatchQueue(label: "mango.js.\(UUID().uuidString)", qos: .userInitiated).async {
            guard let ctx = JSContext() else { done(false); return }
            if let setLimit = setTimeLimit {
                let group = JSContextGetGroup(ctx.jsGlobalContextRef)
                setLimit(group, max(3, AppSettings.shared.runnerTimeout), { _, _ in true }, nil)
            }
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
            let started = Date()
            ctx.evaluateScript(source)
            if failed && Date().timeIntervalSince(started) >= max(3, AppSettings.shared.runnerTimeout) - 0.5 {
                console.append(.err, "Stopped: the script ran longer than \(Int(max(3, AppSettings.shared.runnerTimeout))) seconds (change the limit in Settings › Run).")
                done(false)
                return
            }
            // Run queued timers in order once (enough for simple async demos).
            ctx.evaluateScript("__timers.sort(function(a,b){return a.ms-b.ms}); while (__timers.length) { var t = __timers.shift(); try { t.fn(); } catch (e) { console.error(String(e)); } }")
            done(!failed)
        }
    }

    /// Runs code and hands back everything it printed, for the agent (doesn't touch the visible console).
    static func runCapture(code: String, fileName: String, runner: String, stdin: String, completion: @escaping (String) -> Void) {
        let capture = ConsoleModel()
        let done: (Bool) -> Void = { ok in
            // Console output is flushed in small batches; give the last batch a moment to land.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let text = capture.lines.map { line -> String in
                    line.kind == .err ? "[stderr] " + line.text : line.text
                }.joined(separator: "\n")
                completion((ok ? "" : "[exit: failed]\n") + text)
            }
        }
        if runner == "js" {
            runJavaScript(code, stdin: stdin, strict: AppSettings.shared.jsStrictMode, console: capture, done: done)
        } else {
            runRemote(code: code, fileName: fileName, language: runner, stdin: stdin, console: capture, done: done)
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
        runRemote(files: [["name": fileName, "content": code]], language: language, args: [], stdin: stdin, keepNames: false, console: console, done: done)
    }

    static func runRemote(files: [[String: Any]], language: String, args: [String], stdin: String, keepNames: Bool,
                          console: ConsoleModel, done: @escaping (Bool) -> Void) {
        let s = AppSettings.shared
        guard let url = runnerEndpoint(s.runnerURL, path: "execute") else {
            noRunner(language, console); done(false); return
        }
        var req = URLRequest(url: url, timeoutInterval: max(5, s.runnerTimeout))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&req)
        let body: [String: Any] = ["language": language, "version": "*", "files": files, "stdin": stdin, "args": args, "keep_names": keepNames]
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
            var ok = showCompile(json["compile"], console)
            if let run = json["run"] as? [String: Any] {
                if let out = run["stdout"] as? String, !out.isEmpty { console.append(.out, out.trimmingCharacters(in: .newlines)) }
                if let err = run["stderr"] as? String, !err.isEmpty { console.append(.err, err.trimmingCharacters(in: .newlines)) }
                if let code = run["code"] as? Int, code != 0 { ok = false; console.append(.info, "Exit code \(code)") }
                if let signal = run["signal"] as? String, !signal.isEmpty { ok = false; console.append(.info, "Stopped by \(signal)") }
            }
            done(ok)
        }.resume()
    }

    private static func noRunner(_ language: String, _ console: ConsoleModel) {
        console.append(.err, "No runner server set.")
        console.append(.info, "JavaScript runs on your phone, but \(language) needs a runner server. Add one in Settings › Run & Console (any Piston-compatible server works).")
    }

    /// Prints compiler output. Returns false if compiling failed.
    @discardableResult
    private static func showCompile(_ any: Any?, _ console: ConsoleModel) -> Bool {
        guard let compile = any as? [String: Any] else { return true }
        var ok = true
        if let out = compile["stdout"] as? String, !out.isEmpty { console.append(.out, out.trimmingCharacters(in: .newlines)) }
        if let code = compile["code"] as? Int, code != 0 { ok = false }
        if let err = compile["stderr"] as? String, !err.isEmpty { console.append(ok ? .info : .err, err.trimmingCharacters(in: .newlines)) }
        return ok
    }

    // MARK: Interactive runs (type into the program while it runs)

    static func sessionPost(_ id: String, _ action: String, _ body: [String: Any]) {
        guard let req = RunnerAPI.request("sessions/\(id)/\(action)", body: body, timeout: 15) else { return }
        URLSession.shared.dataTask(with: req).resume()
    }

    static func runSession(files: [[String: Any]], language: String, args: [String], stdin: String, keepNames: Bool,
                           console: ConsoleModel, done: @escaping (Bool) -> Void) {
        guard var start = RunnerAPI.request("sessions", body: ["language": language, "files": files, "args": args, "keep_names": keepNames],
                                            timeout: max(30, AppSettings.shared.runnerTimeout + 60)) else {
            noRunner(language, console); done(false); return
        }
        start.timeoutInterval = 120
        Task {
            do {
                let (status, json) = try await RunnerAPI.json(start)
                if status == 404 {
                    // Older runner without interactive runs: run it the classic way.
                    runRemote(files: files, language: language, args: args, stdin: stdin, keepNames: keepNames, console: console, done: done)
                    return
                }
                if let message = json["message"] as? String { console.append(.err, message); done(false); return }
                let compiled = showCompile(json["compile"], console)
                guard compiled, let id = json["id"] as? String else { done(false); return }
                console.attachSession(id)
                if !stdin.isEmpty { sessionPost(id, "input", ["data": stdin.hasSuffix("\n") ? stdin : stdin + "\n"]) }
                guard var streamReq = RunnerAPI.request("sessions/\(id)/stream", method: "GET", timeout: 120) else { done(false); return }
                streamReq.httpBody = nil
                let (bytes, resp) = try await URLSession.shared.bytes(for: streamReq)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { console.append(.err, "The runner lost the program."); done(false); return }
                var exitOK: Bool?
                for try await line in bytes.lines {
                    guard let data = line.data(using: .utf8), let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                    switch ev["t"] as? String {
                    case "out": console.write(.out, ev["data"] as? String ?? "")
                    case "err": console.write(.err, ev["data"] as? String ?? "")
                    case "exit":
                        let code = (ev["code"] as? NSNumber)?.intValue
                        if let code, code != 0 { console.append(.info, "Exit code \(code)") }
                        if let sig = ev["signal"] as? String, !sig.isEmpty { console.append(.info, "Stopped by \(sig)") }
                        exitOK = code == 0
                    default: break
                    }
                    if exitOK != nil { break }
                }
                if exitOK == nil { console.append(.err, "Lost the connection to the running program.") }
                done(exitOK ?? false)
            } catch {
                console.append(.err, "Couldn't reach the runner: \(error.localizedDescription)")
                done(false)
            }
        }
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


/// CSV/TSV preview as a scrollable table (first 2,000 rows).
enum CSVTable {
    static func parse(_ text: String, tabs: Bool, maxRows: Int = 2000) -> [[String]] {
        if tabs { return text.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxRows).map { $0.components(separatedBy: "\t") } }
        var rows: [[String]] = [], row: [String] = [], field = "", inQuotes = false
        func handle(_ c: Character) {
            switch c {
            case "\"": inQuotes = true
            case ",": row.append(field); field = ""
            case "\n", "\r\n": row.append(field); field = ""; rows.append(row); row = []
            case "\r": break
            default: field.append(c)
            }
        }
        var it = text.makeIterator()
        while let c = it.next() {
            if inQuotes {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; handle(n) }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else { handle(c) }
            if rows.count >= maxRows { break }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func html(_ text: String, tabs: Bool) -> String {
        let rows = parse(text, tabs: tabs)
        let esc = MarkdownHTML.escape
        var body = "<table>"
        for (i, r) in rows.enumerated() {
            let tag = i == 0 ? "th" : "td"
            body += "<tr>" + r.map { "<\(tag)>\(esc($0))</\(tag)>" }.joined() + "</tr>"
        }
        body += "</table>"
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:light dark} body{font-family:-apple-system,sans-serif;margin:0;padding:12px}
        table{border-collapse:collapse;font-size:13px} th,td{border:1px solid rgba(127,127,127,.35);padding:4px 8px;white-space:nowrap}
        th{position:sticky;top:0;background:rgba(255,154,26,.25)} tr:nth-child(even) td{background:rgba(127,127,127,.08)}</style>
        </head><body><p style="opacity:.6;font-size:12px">\(rows.count) rows\(rows.count >= 2000 ? " (first 2,000 shown)" : "")</p>\(body)</body></html>
        """
    }
}

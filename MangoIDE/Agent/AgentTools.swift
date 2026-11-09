import Foundation

/// Everything the agent can do, limited to one project folder.
/// Files that are open in the editor are read/written through the editor so nothing gets out of sync.
final class AgentToolbox {
    let root: URL
    weak var editor: EditorState?
    /// Original contents before the agent first touched each file (nil = the file didn't exist).
    private(set) var checkpoints: [(url: URL, original: Data?)] = []
    private(set) var changedFiles: [String] = []

    init(root: URL, editor: EditorState?) {
        self.root = root
        self.editor = editor
    }

    static let memoryLimit = 4000
    var notesURL: URL { root.appendingPathComponent(".mango/agent-notes.md") }

    // MARK: Tool definitions sent to the model

    static let definitions: [[String: Any]] = [
        tool("list_files", "List files and folders in the project (skips node_modules, .git, build folders). Paths are relative to the project root.",
             ["path": str("Folder to list, relative to the project root. Empty for the root."), "depth": int("How many levels deep (1-6, default 3).")], []),
        tool("read_file", "Read a text file with line numbers. Use start_line/end_line for big files.",
             ["path": str("File path relative to the project root."), "start_line": int("First line (1-based)."), "end_line": int("Last line.")], ["path"]),
        tool("search", "Search file contents in the project (case-insensitive). Returns matching lines with paths and line numbers.",
             ["query": str("Text to find."), "path": str("Folder to search in (optional).")], ["query"]),
        tool("edit_file", "Replace one exact piece of text in a file. old_text must appear exactly once; include enough surrounding lines to make it unique. Prefer this over write_file for changes.",
             ["path": str("File path."), "old_text": str("Exact text to replace."), "new_text": str("Replacement text.")], ["path", "old_text", "new_text"]),
        tool("write_file", "Create a new file, or replace a whole file's contents. Folders are created as needed.",
             ["path": str("File path."), "content": str("Full file contents.")], ["path", "content"]),
        tool("delete_file", "Delete a file or folder. The user is asked to approve.",
             ["path": str("Path to delete.")], ["path"]),
        tool("rename_file", "Rename or move a file or folder within the project.",
             ["from": str("Current path."), "to": str("New path.")], ["from", "to"]),
        tool("run_file", "Run a file (JavaScript on the device, other languages on the runner server) and get its output. Use it to test your changes.",
             ["path": str("File to run."), "stdin": str("Optional program input.")], ["path"]),
        tool("remember", "Save a short fact to the project memory. Only use this when the user asks you to remember something.",
             ["note": str("One short line to remember.")], ["note"]),
        tool("update_overview", "Rewrite the project overview in memory: what the project is, its tech stack and how it runs. Keep it under 12 short lines.",
             ["overview": str("The new overview.")], ["overview"])
    ]

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": desc, "input_schema": ["type": "object", "properties": props, "required": required]]
    }
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }

    /// Tools that need the user's OK before they run (decided by the approval setting).
    func needsApproval(_ name: String, _ input: [String: Any], askForEverything: Bool) -> Bool {
        switch name {
        case "delete_file": return true
        case "write_file":
            if askForEverything { return true }
            guard let p = input["path"] as? String, let u = try? resolve(p) else { return false }
            return FileManager.default.fileExists(atPath: u.path)   // overwriting an existing file
        case "edit_file", "rename_file": return askForEverything
        default: return false
        }
    }

    /// Short human description shown in the chat and approval cards.
    func describe(_ name: String, _ input: [String: Any]) -> String {
        let p = input["path"] as? String ?? ""
        switch name {
        case "list_files": return "Looked at files in \(p.isEmpty ? "the project" : p)"
        case "read_file": return "Read \(p)"
        case "search": return "Searched for “\(input["query"] as? String ?? "")”"
        case "edit_file": return "Edit \(p)"
        case "write_file": return FileManager.default.fileExists(atPath: (try? resolve(p))?.path ?? "") ? "Overwrite \(p)" : "Create \(p)"
        case "delete_file": return "Delete \(p)"
        case "rename_file": return "Rename \(input["from"] as? String ?? "") → \(input["to"] as? String ?? "")"
        case "run_file": return "Run \(p)"
        case "remember": return "Remember: \(input["note"] as? String ?? "")"
        case "update_overview": return "Updated the project overview"
        default: return name
        }
    }

    // MARK: Paths (never outside the project)

    struct ToolError: LocalizedError { let message: String; var errorDescription: String? { message } }

    func resolve(_ relative: String) throws -> URL {
        let cleaned = relative.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = cleaned.split(separator: "/").map(String.init)
        if parts.contains("..") { throw ToolError(message: "Paths can't use “..”. Stay inside the project.") }
        var url = root
        for part in parts where part != "." { url.appendPathComponent(part) }
        guard Workspace.shared.isInside(url, root) else { throw ToolError(message: "That path is outside the project.") }
        return url
    }

    func relative(_ url: URL) -> String {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        return String(p.dropFirst(r.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Reading/writing through the editor when a file is open

    private func openDocument(_ url: URL) -> EditorDocument? {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        return editor?.documents.values.first { $0.url.standardizedFileURL.resolvingSymlinksInPath().path == key }
    }

    private func readText(_ url: URL) throws -> String {
        if let doc = openDocument(url), !doc.isBinary { return doc.text }
        let data = try Data(contentsOf: url)
        if data.prefix(8000).contains(0) { throw ToolError(message: "\(relative(url)) is a binary file, not text.") }
        return String(decoding: data, as: UTF8.self)
    }

    private func checkpoint(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard !checkpoints.contains(where: { $0.url.standardizedFileURL.path == key }) else { return }
        var original: Data? = nil
        if let doc = openDocument(url) { original = Data(doc.text.utf8) }
        else if FileManager.default.fileExists(atPath: url.path) && !Workspace.shared.isDirectory(url) { original = try? Data(contentsOf: url) }
        checkpoints.append((url, original))
    }

    private func writeText(_ url: URL, _ text: String) throws {
        checkpoint(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let doc = openDocument(url) {
            doc.replaceAll(text, markDirty: true)
            doc.saveNow()
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let rel = relative(url)
        if !changedFiles.contains(rel) { changedFiles.append(rel) }
    }

    // MARK: Running a tool

    /// Runs one tool and returns the text sent back to the model. Must be called on the main thread.
    func run(_ name: String, _ input: [String: Any], completion: @escaping (String, Bool) -> Void) {
        do {
            switch name {
            case "list_files": completion(try listFiles(input), false)
            case "read_file": completion(try readFile(input), false)
            case "search": completion(try search(input), false)
            case "edit_file": completion(try editFile(input), false)
            case "write_file":
                let url = try resolve(input["path"] as? String ?? "")
                let existed = FileManager.default.fileExists(atPath: url.path)
                try writeText(url, input["content"] as? String ?? "")
                Workspace.shared.refresh()
                completion("\(existed ? "Overwrote" : "Created") \(relative(url)).", false)
            case "delete_file":
                let url = try resolve(input["path"] as? String ?? "")
                guard url.standardizedFileURL != root.standardizedFileURL else { throw ToolError(message: "Can't delete the project itself.") }
                guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError(message: "\(relative(url)) doesn't exist.") }
                if !Workspace.shared.isDirectory(url) { checkpoint(url) }
                editor?.fileDeleted(url)
                try FileManager.default.removeItem(at: url)
                Workspace.shared.refresh()
                completion("Deleted \(relative(url)).", false)
            case "rename_file":
                let from = try resolve(input["from"] as? String ?? ""), to = try resolve(input["to"] as? String ?? "")
                guard FileManager.default.fileExists(atPath: from.path) else { throw ToolError(message: "\(relative(from)) doesn't exist.") }
                guard !FileManager.default.fileExists(atPath: to.path) else { throw ToolError(message: "\(relative(to)) already exists.") }
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: from, to: to)
                editor?.fileRenamed(from: from, to: to)
                Workspace.shared.refresh()
                completion("Renamed \(relative(from)) to \(relative(to)). (Rename can't be undone automatically.)", false)
            case "run_file": runFile(input, completion: completion)
            case "remember": completion(try remember(input["note"] as? String ?? ""), false)
            case "update_overview": completion(try updateOverview(input["overview"] as? String ?? ""), false)
            default: completion("Unknown tool \(name).", true)
            }
        } catch {
            completion("Error: \(error.localizedDescription)", true)
        }
    }

    private func listFiles(_ input: [String: Any]) throws -> String {
        let start = try resolve(input["path"] as? String ?? "")
        let depth = max(1, min(6, input["depth"] as? Int ?? 3))
        var lines: [String] = []
        func walk(_ dir: URL, _ level: Int) {
            guard lines.count < 400 else { return }
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDir = Workspace.shared.isDirectory(u)
                let indent = String(repeating: "  ", count: level)
                if isDir {
                    lines.append("\(indent)\(u.lastPathComponent)/")
                    if SidebarModel.heavyFolders.contains(u.lastPathComponent) { lines.append("\(indent)  (skipped)"); continue }
                    if level + 1 < depth { walk(u, level + 1) }
                } else {
                    let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    lines.append("\(indent)\(u.lastPathComponent)  (\(size) bytes)")
                }
            }
        }
        walk(start, 0)
        if lines.count >= 400 { lines.append("… (list cut off at 400 entries; list a subfolder for more)") }
        return lines.isEmpty ? "(empty folder)" : lines.joined(separator: "\n")
    }

    private func readFile(_ input: [String: Any]) throws -> String {
        let url = try resolve(input["path"] as? String ?? "")
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError(message: "\(relative(url)) doesn't exist.") }
        let lines = try readText(url).components(separatedBy: "\n")
        let from = max(1, input["start_line"] as? Int ?? 1)
        var to = min(lines.count, input["end_line"] as? Int ?? lines.count)
        if to - from > 1500 { to = from + 1500 }
        guard from <= max(1, lines.count) else { return "(file has \(lines.count) lines)" }
        var out = (from...max(from, to)).compactMap { i -> String? in i <= lines.count ? "\(i)\t\(lines[i - 1])" : nil }.joined(separator: "\n")
        if out.count > 60_000 { out = String(out.prefix(60_000)) + "\n… (cut off; read a smaller line range)" }
        if to < lines.count { out += "\n… (\(lines.count) lines total; read more with start_line \(to + 1))" }
        return out
    }

    private func search(_ input: [String: Any]) throws -> String {
        let q = (input["query"] as? String ?? "").lowercased()
        guard !q.isEmpty else { throw ToolError(message: "Empty search.") }
        let start = try resolve(input["path"] as? String ?? "")
        var hits: [String] = []
        guard let en = FileManager.default.enumerator(at: start, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return "No matches." }
        for case let u as URL in en {
            if SidebarModel.heavyFolders.contains(u.lastPathComponent) { en.skipDescendants(); continue }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard !Workspace.shared.isDirectory(u), size < 2_000_000, let text = try? readText(u) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated() where line.lowercased().contains(q) {
                hits.append("\(relative(u)):\(i + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(200))")
                if hits.count >= 100 { break }
            }
            if hits.count >= 100 { hits.append("… (stopped at 100 matches)"); break }
        }
        return hits.isEmpty ? "No matches." : hits.joined(separator: "\n")
    }

    private func editFile(_ input: [String: Any]) throws -> String {
        let url = try resolve(input["path"] as? String ?? "")
        let old = input["old_text"] as? String ?? "", new = input["new_text"] as? String ?? ""
        guard !old.isEmpty else { throw ToolError(message: "old_text is empty. Use write_file to create files.") }
        let text = try readText(url)
        let count = text.components(separatedBy: old).count - 1
        if count == 0 { throw ToolError(message: "old_text wasn't found in \(relative(url)). Read the file again and copy the text exactly.") }
        if count > 1 { throw ToolError(message: "old_text appears \(count) times in \(relative(url)). Include more surrounding lines so it's unique.") }
        try writeText(url, text.replacingOccurrences(of: old, with: new))
        let added = new.components(separatedBy: "\n").count, removed = old.components(separatedBy: "\n").count
        return "Edited \(relative(url)) (+\(added) −\(removed) lines)."
    }

    private func runFile(_ input: [String: Any], completion: @escaping (String, Bool) -> Void) {
        do {
            let url = try resolve(input["path"] as? String ?? "")
            let code = try readText(url)
            let lang = ExtensionManager.shared.language(for: url)
            guard let runner = lang.runner, !["html", "markdown", "csv"].contains(runner) else {
                completion("\(lang.name) files can't be run, only previewed.", true); return
            }
            RunService.runCapture(code: code, fileName: url.lastPathComponent, runner: runner, stdin: input["stdin"] as? String ?? "") { out in
                completion(out.isEmpty ? "(no output)" : String(out.suffix(20_000)), false)
            }
        } catch {
            completion("Error: \(error.localizedDescription)", true)
        }
    }

    // MARK: Memory (.mango/agent-notes.md: Overview + Remembered)

    func loadNotes() -> String {
        (try? String(contentsOf: notesURL, encoding: .utf8)) ?? ""
    }

    private func section(_ name: String, in text: String) -> String {
        guard let r = text.range(of: "## \(name)\n") else { return "" }
        let rest = text[r.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveNotes(overview: String, remembered: String) throws {
        let text = "# Agent notes\n\n## Overview\n\(overview)\n\n## Remembered\n\(remembered)\n"
        if text.count > AgentToolbox.memoryLimit {
            throw ToolError(message: "Memory is full (\(text.count)/\(AgentToolbox.memoryLimit) characters). Shorten the overview or combine remembered notes first.")
        }
        try FileManager.default.createDirectory(at: notesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: notesURL, atomically: true, encoding: .utf8)
        Workspace.shared.refresh()
    }

    private func remember(_ note: String) throws -> String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !n.isEmpty else { throw ToolError(message: "Empty note.") }
        let text = loadNotes()
        var remembered = section("Remembered", in: text)
        remembered += (remembered.isEmpty ? "" : "\n") + "- " + n
        try saveNotes(overview: section("Overview", in: text), remembered: remembered)
        return "Saved to memory."
    }

    private func updateOverview(_ overview: String) throws -> String {
        let text = loadNotes()
        try saveNotes(overview: overview.trimmingCharacters(in: .whitespacesAndNewlines), remembered: section("Remembered", in: text))
        return "Overview updated."
    }

    // MARK: Undo

    /// Puts every file the agent changed back the way it was. Returns how many were restored.
    @discardableResult
    func undoAll() -> Int {
        var n = 0
        for cp in checkpoints.reversed() {
            if let data = cp.original {
                if let doc = openDocument(cp.url) {
                    doc.replaceAll(String(decoding: data, as: UTF8.self), markDirty: true)
                    doc.saveNow()
                } else {
                    try? FileManager.default.createDirectory(at: cp.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: cp.url, options: .atomic)
                }
            } else {
                editor?.fileDeleted(cp.url)
                try? FileManager.default.removeItem(at: cp.url)
            }
            n += 1
        }
        checkpoints.removeAll()
        changedFiles.removeAll()
        Workspace.shared.refresh()
        return n
    }
}

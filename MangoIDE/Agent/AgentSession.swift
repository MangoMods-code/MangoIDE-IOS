import Foundation
import SwiftUI

/// One chat with the coding agent: sends messages to Claude (through your runner server),
/// runs the tools it asks for, and keeps track of cost and changes.
final class AgentSession: ObservableObject {
    struct Item: Identifiable {
        enum Kind { case user, assistant, tool, error, info }
        let id = UUID()
        let kind: Kind
        let text: String
        var path: String? = nil
        var failed = false
    }

    struct Approval: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let resolve: (Bool) -> Void
    }

    static let models: [(id: String, name: String, input: Double, output: Double, cacheWrite: Double, cacheRead: Double)] = [
        ("claude-haiku-5-5", "Haiku 5.5 · cheapest", 0.10, 0.50, 0.125, 0.01),
        ("claude-sonnet-5-5", "Sonnet 5.5 · best value", 2, 10, 2.5, 0.10),
        ("claude-opus-5-5", "Opus 5.5 · strongest", 4, 20, 5, 0.20)
    ]

    @Published private(set) var items: [Item] = []
    @Published private(set) var isWorking = false
    @Published private(set) var cost: Double = 0
    @Published var approval: Approval?
    @Published private(set) var project: URL?

    private(set) var toolbox: AgentToolbox?
    private var messages: [[String: Any]] = []
    private var cancelled = false
    private var steps = 0
    weak var editor: EditorState?

    var changedCount: Int { toolbox?.changedFiles.count ?? 0 }

    // MARK: Starting

    /// The project the agent works in: the open project, the project of the last file, or the active file's folder.
    func currentProject() -> URL? {
        let ws = Workspace.shared
        if let p = ws.activeProject { return p }
        if let p = editor?.lastProject { return p }
        if let doc = editor?.activeDocument, ws.isKnownLocation(doc.url) { return doc.url.deletingLastPathComponent() }
        return nil
    }

    func newChat() {
        cancelled = true
        items = []
        messages = []
        cost = 0
        steps = 0
        approval = nil
        isWorking = false
        toolbox = nil
        project = nil
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }
        guard let root = currentProject() else {
            items.append(Item(kind: .error, text: "Open a project (or a file inside one) first, so I know which folder to work in."))
            return
        }
        if project?.standardizedFileURL != root.standardizedFileURL {
            if project != nil { items.append(Item(kind: .info, text: "Switched to \(root.lastPathComponent).")) }
            project = root
            toolbox = AgentToolbox(root: root, editor: editor)
            messages = []
        }
        items.append(Item(kind: .user, text: trimmed))
        messages.append(["role": "user", "content": [["type": "text", "text": trimmed]]])
        cancelled = false
        steps = 0
        isWorking = true
        step()
    }

    func stop() {
        cancelled = true
        isWorking = false
        approval?.resolve(false)
        approval = nil
        items.append(Item(kind: .info, text: "Stopped."))
    }

    func undoChanges() {
        guard let tb = toolbox else { return }
        let n = tb.undoAll()
        items.append(Item(kind: .info, text: "Undid changes to \(n) file\(n == 1 ? "" : "s")."))
        messages.append(["role": "user", "content": [["type": "text", "text": "(The user undid all of your file changes so far. Files are back to how they were.)"]]])
    }

    // MARK: The loop

    private func finish(_ note: String? = nil, error: Bool = false) {
        if let note { items.append(Item(kind: error ? .error : .info, text: note)) }
        isWorking = false
    }

    private func step() {
        let s = AppSettings.shared
        guard !cancelled else { return }
        if cost >= s.agentSpendCap {
            finish(String(format: "Stopped at the $%.2f spending limit for this chat (change it in Settings › Agent).", s.agentSpendCap), error: true)
            return
        }
        steps += 1
        if steps > s.agentMaxSteps {
            finish("Stopped after \(s.agentMaxSteps) steps. Say “keep going” to continue.", error: true)
            return
        }
        // With your own key on this phone, talk to Anthropic directly. Otherwise go through the runner server.
        let ownKey = s.agentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var req: URLRequest
        if !ownKey.isEmpty {
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 200)
            req.setValue(ownKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if let account = AccountManager.shared.token {
            // Signed in: use your MangoIDE AI credit.
            req = URLRequest(url: AccountManager.server.appendingPathComponent("ai/messages"), timeoutInterval: 200)
            req.setValue("Bearer " + account, forHTTPHeaderField: "Authorization")
        } else {
            guard let url = RunService.runnerEndpoint(s.runnerURL, path: "x")?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("agent/messages") else {
                finish("Sign in (Settings › Account) to use AI credit, or add your own Anthropic key in Settings › Agent.", error: true)
                return
            }
            req = URLRequest(url: url, timeoutInterval: 200)
            RunService.authorize(&req)
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: requestBody())

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            DispatchQueue.main.async {
                if let left = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Credits"), let v = Double(left) {
                    AccountManager.shared.updateCredits(v)
                }
                self?.handle(data: data, response: resp, error: error)
            }
        }.resume()
    }

    private func requestBody() -> [String: Any] {
        var tools = AgentToolbox.definitions(cloud: AppSettings.shared.agentCloudWorkspace)
        if var last = tools.last { last["cache_control"] = ["type": "ephemeral"]; tools[tools.count - 1] = last }
        // Cache everything up to the newest message so each step only pays full price for what's new.
        var msgs = messages
        if var last = msgs.last, var content = last["content"] as? [[String: Any]], !content.isEmpty {
            content[content.count - 1]["cache_control"] = ["type": "ephemeral"]
            last["content"] = content
            msgs[msgs.count - 1] = last
        }
        return [
            "model": AppSettings.shared.agentModel,
            "max_tokens": 8000,
            "system": [["type": "text", "text": systemPrompt(), "cache_control": ["type": "ephemeral"]]],
            "tools": tools,
            "messages": msgs
        ]
    }

    private func systemPrompt() -> String {
        let name = project?.lastPathComponent ?? "project"
        let notes = toolbox?.loadNotes().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var open: [String] = []
        if let tb = toolbox, let ed = editor {
            for d in ed.documents.values where Workspace.shared.isInside(d.url, tb.root) {
                open.append(tb.relative(d.url) + (d.isDirty ? " (unsaved changes)" : ""))
            }
        }
        let active = editor?.activeDocument.flatMap { d in toolbox.map { $0.relative(d.url) } } ?? "none"
        return """
        You are the coding agent inside MangoIDE, a code editor on the user's iPhone. You work in the project folder "\(name)". Every path you use is relative to that folder, and you can't reach anything outside it.

        How to work:
        - Look before you change: use list_files, read_file and search. Never guess what a file contains.
        - Make focused changes with edit_file. Use write_file for new files or full rewrites.
        - Test with run_file when it helps.\(AppSettings.shared.agentCloudWorkspace ? "\n        - You also have run_command: a Linux workspace with a synced copy of this project (Python, Node, Swift, Go, Rust, Java and more installed). Use it for installs, running the project, tests, builds and git. Keep editing files with edit_file/write_file; they sync before each command." : "")
        - Keep your messages short and plain; the user reads them on a phone. Say what you changed in a sentence or two.
        - Deletes and overwrites ask the user first. If they decline, don't retry the same thing.

        Memory (.mango/agent-notes.md) is shown below. Keep it short.
        - If the overview is missing or out of date (what the project is, tech stack, how to run it), fix it with update_overview.
        - Only use remember when the user explicitly asks you to remember something.

        Open files: \(open.isEmpty ? "none" : open.joined(separator: ", ")). Active file: \(active).

        ## Project memory
        \(notes.isEmpty ? "(empty — add an overview once you've looked at the project)" : notes)
        """
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?) {
        guard !cancelled else { return }
        if let error { finish("Couldn't reach the server: \(error.localizedDescription)", error: true); return }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            finish("The server sent back something unexpected (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).", error: true); return
        }
        if let err = json["error"] as? [String: Any] {
            let msg = err["message"] as? String ?? "Unknown error"
            let low = msg.lowercased()
            if low.contains("api key") || low.contains("x-api-key") || low.contains("authentication") {
                finish("Anthropic didn't accept the API key. Check it in Settings › Agent.", error: true)
            } else if low.contains("credit") || low.contains("balance") || low.contains("billing") {
                finish("Your Anthropic account is out of credit. Add some at console.anthropic.com, then try again.", error: true)
            } else {
                finish("AI error: \(msg)", error: true)
            }
            return
        }
        if let msg = json["message"] as? String, json["content"] == nil {
            finish(msg.contains("ANTHROPIC_API_KEY") ? "Add your Anthropic API key in Settings › Agent." : msg, error: true); return
        }

        if let usage = json["usage"] as? [String: Any] { addCost(usage) }
        let content = json["content"] as? [[String: Any]] ?? []
        messages.append(["role": "assistant", "content": content])
        for block in content where block["type"] as? String == "text" {
            if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(Item(kind: .assistant, text: t))
            }
        }
        let calls = content.filter { $0["type"] as? String == "tool_use" }
        if calls.isEmpty {
            if json["stop_reason"] as? String == "max_tokens" { finish("The reply got cut off. Say “continue”.", error: true) }
            else { finish() }
            return
        }
        runTools(calls, index: 0, results: [])
    }

    private func runTools(_ calls: [[String: Any]], index: Int, results: [[String: Any]]) {
        guard !cancelled, let tb = toolbox else { return }
        if index >= calls.count {
            messages.append(["role": "user", "content": results])
            step()
            return
        }
        let call = calls[index]
        let id = call["id"] as? String ?? UUID().uuidString
        let name = call["name"] as? String ?? ""
        let input = call["input"] as? [String: Any] ?? [:]
        let title = tb.describe(name, input)

        let proceed: (Bool) -> Void = { [weak self] approved in
            guard let self, !self.cancelled else { return }
            self.approval = nil
            guard approved else {
                self.items.append(Item(kind: .tool, text: "Declined: \(title)", failed: true))
                var r = results
                r.append(["type": "tool_result", "tool_use_id": id, "content": "The user declined this action.", "is_error": true])
                self.runTools(calls, index: index + 1, results: r)
                return
            }
            tb.run(name, input) { [weak self] output, isError in
                guard let self, !self.cancelled else { return }
                let quiet = ["list_files", "read_file", "search"].contains(name)
                let showsOutput = name == "run_file" || name == "run_command"
                let path = input["path"] as? String ?? input["to"] as? String
                if !quiet || isError {
                    self.items.append(Item(kind: .tool, text: isError ? "\(title) — \(output.replacingOccurrences(of: "Error: ", with: ""))" : (showsOutput ? "\(title)\n\(output.suffix(600))" : title),
                                           path: path, failed: isError))
                } else {
                    self.items.append(Item(kind: .tool, text: title, path: name == "read_file" ? path : nil))
                }
                var r = results
                var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": output]
                if isError { result["is_error"] = true }
                r.append(result)
                self.runTools(calls, index: index + 1, results: r)
            }
        }

        if tb.needsApproval(name, input, askForEverything: AppSettings.shared.agentApproval == "all") {
            var detail = ""
            if name == "write_file" { detail = String((input["content"] as? String ?? "").prefix(800)) }
            if name == "edit_file" { detail = "− " + String((input["old_text"] as? String ?? "").prefix(400)) + "\n+ " + String((input["new_text"] as? String ?? "").prefix(400)) }
            approval = Approval(title: title, detail: detail, resolve: proceed)
        } else {
            proceed(true)
        }
    }

    private func addCost(_ usage: [String: Any]) {
        let m = AgentSession.models.first { $0.id == AppSettings.shared.agentModel } ?? AgentSession.models[0]
        func n(_ k: String) -> Double { Double(usage[k] as? Int ?? 0) }
        cost += (n("input_tokens") * m.input + n("output_tokens") * m.output
                 + n("cache_creation_input_tokens") * m.cacheWrite + n("cache_read_input_tokens") * m.cacheRead) / 1_000_000
    }
}

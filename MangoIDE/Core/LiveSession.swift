import Foundation
import Combine
import UIKit

/// A live session: several people editing the same project at once.
///
/// Each shared file keeps the server's last confirmed text plus at most one edit waiting for the server
/// to confirm it and one batch of newer edits (the ot.js client model). Edits from others are adjusted
/// around your pending edits, so everyone always ends up with identical text.
@MainActor
final class LiveSession: ObservableObject {
    static let shared = LiveSession()

    struct Person: Identifiable, Equatable {
        let id: String
        let login: String
        let avatar: String?
        let color: String
        let host: Bool
        let path: String?
    }

    enum Status: Equatable { case idle, connecting, live, reconnecting }

    @Published private(set) var code: String?
    @Published private(set) var name = ""
    @Published private(set) var hostLogin = ""
    @Published private(set) var isHost = false
    @Published private(set) var people: [Person] = []
    @Published private(set) var me: Person?
    @Published private(set) var status: Status = .idle
    @Published var message: String?
    @Published private(set) var root: URL?

    weak var editor: EditorState?

    var link: URL? { code.map { AccountManager.server.appendingPathComponent("j/\($0)") } }
    var isActive: Bool { code != nil }

    private final class FileState {
        var confirmed: String
        var text: String
        var rev: Int
        var out: TextOp?
        var buf: TextOp?
        weak var doc: EditorDocument?
        var write: DispatchWorkItem?
        var peers: [String: (a: Int, b: Int)] = [:]
        init(_ text: String, rev: Int) { confirmed = text; self.text = text; self.rev = rev }
    }

    private var files: [String: FileState] = [:]
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var docWatch: AnyCancellable?
    private var selWork: DispatchWorkItem?
    private var pendingFolderName: String?
    private var retryDelay: Double = 1

    static let maxFile = 1_000_000

    // MARK: Start / join / leave

    /// Starts a session on a project (Pro). Shares its text files.
    func host(_ project: URL) async throws {
        guard AccountManager.shared.isSignedIn else { throw CloudError.message("Sign in with GitHub first.") }
        if isActive { leave() }
        let docs = editor.map { Array($0.documents.values) } ?? []
        let open = Dictionary(docs.filter { !$0.isBinary }.map { ($0.url.standardizedFileURL.path, $0.text) }, uniquingKeysWith: { a, _ in a })
        let limit = LiveSession.maxFile
        let shared: [String: String] = await Task.detached {
            var out: [String: String] = [:]
            for (path, url) in GitHub.scan(project) {
                if let t = open[url.standardizedFileURL.path] { out[path] = t; continue }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit,
                      let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0),
                      let s = String(data: data, encoding: .utf8) else { continue }
                out[path] = s
            }
            return out
        }.value
        guard var req = GitHub.request("collab/start", method: "POST", body: ["name": project.lastPathComponent, "files": shared]) else {
            throw CloudError.message("Sign in with GitHub first.")
        }
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let c = json["code"] as? String else {
            let m = json["message"] as? String ?? "Couldn't start the session (\(status))."
            throw status == 402 ? CloudError.needsPro(m) : CloudError.message(m)
        }
        files = [:]
        root = project
        isHost = true
        start(code: c)
    }

    /// Looks up a session before joining.
    func info(_ code: String) async throws -> (name: String, host: String, people: Int) {
        guard let req = GitHub.request("collab/info", query: ["code": code.uppercased()]) else { throw CloudError.message("Sign in with GitHub to join.") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw CloudError.message(json["message"] as? String ?? "That session wasn't found.") }
        return (json["name"] as? String ?? "Project", json["host"] as? String ?? "", (json["people"] as? NSNumber)?.intValue ?? 0)
    }

    /// Joins someone's session. The files arrive in a new folder in your projects.
    func join(_ code: String) {
        if isActive { leave() }
        files = [:]
        root = nil
        isHost = false
        start(code: code.uppercased())
    }

    private func start(code c: String) {
        code = c
        status = .connecting
        retryDelay = 1
        save()
        connect()
        watchDocuments()
    }

    /// Leave (or, for the host, end) the session. Your files stay where they are.
    func leave() {
        if isHost { send(["t": "end"]) }
        flushWrites()
        teardown()
    }

    private func teardown() {
        generation += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        docWatch = nil
        for f in files.values {
            f.doc?.onLocalChange = nil
            f.doc?.onLocalSelection = nil
            f.doc?.setPeers([])
        }
        files = [:]
        code = nil
        people = []
        me = nil
        status = .idle
        isHost = false
        root = nil
        UserDefaults.standard.removeObject(forKey: "live.session")
    }

    // MARK: Survive app restarts and backgrounding

    private func save() {
        guard let code else { return }
        var d: [String: Any] = ["code": code, "host": isHost]
        if let root { d["folder"] = root.lastPathComponent }
        UserDefaults.standard.set(d, forKey: "live.session")
    }

    /// Reconnects to the session you were in when the app closed.
    func restore() {
        guard code == nil, let d = UserDefaults.standard.dictionary(forKey: "live.session"),
              let c = d["code"] as? String, AccountManager.shared.isSignedIn else { return }
        isHost = d["host"] as? Bool ?? false
        if let folder = d["folder"] as? String {
            let parent = Workspace.shared.projectsRoot ?? Workspace.shared.projectsFolder
            let url = parent.appendingPathComponent(folder, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { root = url }
        }
        if root == nil && isHost { UserDefaults.standard.removeObject(forKey: "live.session"); return }
        start(code: c)
    }

    func appWentToBackground() {
        flushWrites()
        guard isActive else { return }
        generation += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .reconnecting
    }

    func appBecameActive() {
        if isActive, socket == nil { status = .reconnecting; connect() } else if !isActive { restore() }
    }

    // MARK: Socket

    private func connect() {
        guard let code, var req = GitHub.request("collab/ws", query: ["code": code]),
              var comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false) else {
            message = "Sign in with GitHub to use live sessions."
            teardown()
            return
        }
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        req.url = comps.url
        generation += 1
        let gen = generation
        let task = URLSession.shared.webSocketTask(with: req)
        task.maximumMessageSize = 64 * 1024 * 1024
        socket = task
        task.resume()
        receive(task, gen)
    }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let msg):
                    var data: Data?
                    switch msg {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { self.handle(json) }
                    self.receive(task, gen)
                case .failure:
                    self.dropped(task)
                }
            }
        }
    }

    private func dropped(_ task: URLSessionWebSocketTask) {
        socket = nil
        let http = task.response as? HTTPURLResponse
        if http?.statusCode == 404 {
            message = "That live session has ended or the code is wrong."
            flushWrites(); teardown(); return
        }
        if http?.statusCode == 401 { message = "Sign in again to rejoin the live session."; flushWrites(); teardown(); return }
        if http?.statusCode == 403 { message = "That live session is full."; teardown(); return }
        guard isActive else { return }
        status = .reconnecting
        guard UIApplication.shared.applicationState == .active else { return }
        let gen = generation
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isActive, self.socket == nil, gen == self.generation else { return }
            self.connect()
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(s)) { _ in }
    }

    // MARK: Messages

    private func person(_ any: Any?) -> Person? {
        guard let d = any as? [String: Any], let id = d["id"] as? String else { return nil }
        return Person(id: id, login: d["login"] as? String ?? "?", avatar: d["avatar"] as? String,
                      color: d["color"] as? String ?? "#ff9f0a", host: d["host"] as? Bool ?? false, path: d["path"] as? String)
    }

    private func handle(_ m: [String: Any]) {
        switch m["t"] as? String {
        case "welcome": welcome(m)
        case "people":
            people = (m["people"] as? [Any] ?? []).compactMap(person)
            let ids = Set(people.map(\.id))
            for (path, f) in files where f.peers.keys.contains(where: { !ids.contains($0) }) {
                f.peers = f.peers.filter { ids.contains($0.key) }
                pushPeers(path)
            }
        case "ack":
            guard let path = m["path"] as? String, let f = files[path], let rev = (m["rev"] as? NSNumber)?.intValue else { return }
            if let out = f.out, let c = try? out.apply(f.confirmed) { f.confirmed = c }
            f.rev = rev
            f.out = f.buf
            f.buf = nil
            if let out = f.out { sendOp(path, f, out) }
        case "op":
            guard let path = m["path"] as? String, let f = files[path], var op = TextOp(json: m["op"]),
                  let rev = (m["rev"] as? NSNumber)?.intValue else { return }
            do {
                f.confirmed = try op.apply(f.confirmed)
                if let out = f.out {
                    let (o2, r2) = try TextOp.transform(out, op)
                    f.out = TextOp(comps: o2.comps, id: out.id); op = r2
                    if let buf = f.buf { let (b2, r3) = try TextOp.transform(buf, op); f.buf = b2; op = r3 }
                }
                f.text = try op.apply(f.text)
                f.rev = rev
                shiftPeers(f, by: op, except: m["by"] as? String)
                if let doc = f.doc { doc.applyRemote(op.edits, newText: f.text); scheduleSave(path, f) } else { scheduleWrite(path, f) }
                pushPeers(path)
            } catch {
                send(["t": "op", "path": path, "rev": -1, "op": [Any]()])   // asks the server for a resync
            }
        case "resync":
            guard let path = m["path"] as? String, let text = m["text"] as? String, let rev = (m["rev"] as? NSNumber)?.intValue else { return }
            let f = files[path] ?? FileState(text, rev: rev)
            files[path] = f
            f.confirmed = text; f.text = text; f.rev = rev; f.out = nil; f.buf = nil
            if let doc = f.doc { doc.replaceFromRemote(text); scheduleSave(path, f) } else { scheduleWrite(path, f) }
        case "added":
            guard let path = m["path"] as? String, let text = m["text"] as? String else { return }
            if let f = files[path] { f.rev = (m["rev"] as? NSNumber)?.intValue ?? 0; return }
            let f = FileState(text, rev: (m["rev"] as? NSNumber)?.intValue ?? 0)
            files[path] = f
            scheduleWrite(path, f)
            Workspace.shared.refresh()
        case "sel":
            guard let path = m["path"] as? String, let by = m["by"] as? String, by != me?.id,
                  let a = (m["a"] as? NSNumber)?.intValue, let b = (m["b"] as? NSNumber)?.intValue else { return }
            for (p, f) in files where p != path && f.peers[by] != nil { f.peers[by] = nil; pushPeers(p) }
            files[path]?.peers[by] = (a, b)
            pushPeers(path)
        case "ended":
            message = m["reason"] as? String ?? "The session ended."
            flushWrites()
            teardown()
        case "error":
            message = m["message"] as? String
        default: break
        }
    }

    private func welcome(_ m: [String: Any]) {
        me = person(m["you"])
        let session = m["session"] as? [String: Any] ?? [:]
        name = session["name"] as? String ?? "Project"
        hostLogin = session["host"] as? String ?? ""
        people = (m["people"] as? [Any] ?? []).compactMap(person)
        if let meHost = me?.host { isHost = meHost }
        retryDelay = 1
        let server = m["files"] as? [String: [String: Any]] ?? [:]

        if root == nil {
            // Joining: put the files in a new folder next to your projects.
            let parent = Workspace.shared.projectsRoot ?? Workspace.shared.projectsFolder
            let folder = Workspace.shared.uniqueURL(in: parent, name: "\(name) (live)")
            let scoped = parent.startAccessingSecurityScopedResource()
            defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (path, v) in server {
                    let url = folder.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try (v["text"] as? String ?? "").write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                message = "Couldn't save the session's files: \(error.localizedDescription)"
                leave(); return
            }
            root = folder
            save()
            Workspace.shared.refresh()
            if let editor {
                editor.lastProject = folder
                let first = server.keys.sorted().first { $0.lowercased().hasPrefix("readme") } ?? server.keys.sorted().first
                if let first { editor.open(folder.appendingPathComponent(first)) }
            }
        }

        for (path, v) in server {
            let text = v["text"] as? String ?? ""
            let rev = (v["rev"] as? NSNumber)?.intValue ?? 0
            let ids = Set(v["ids"] as? [String] ?? [])
            if let f = files[path] {
                // Reconnecting: our in-flight edit may already have landed.
                if let out = f.out, let id = out.id, ids.contains(id), let c = try? out.apply(f.confirmed) {
                    f.confirmed = c; f.out = f.buf; f.buf = nil
                }
                var local: TextOp? = f.out
                if let buf = f.buf { local = local.flatMap { try? TextOp.compose($0, buf) } ?? buf }
                let remote = TextOp.diff(f.confirmed, text)
                var newText = f.text
                var resend: TextOp?
                switch (local, remote) {
                case let (l?, r?):
                    if let pair = try? TextOp.transform(l, r), let t = try? pair.1.apply(f.text) { newText = t; resend = pair.0 }
                    else { newText = text }
                case (nil, let r?): newText = (try? r.apply(f.text)) ?? text
                case (let l?, nil): resend = l
                default: break
                }
                f.confirmed = text; f.rev = rev; f.out = nil; f.buf = nil
                if newText != f.text {
                    let op = TextOp.diff(f.text, newText)
                    f.text = newText
                    if let doc = f.doc, let op { doc.applyRemote(op.edits, newText: newText); scheduleSave(path, f) } else { scheduleWrite(path, f) }
                }
                if let resend { f.out = TextOp(comps: resend.comps, id: UUID().uuidString); sendOp(path, f, f.out!) }
            } else {
                files[path] = FileState(text, rev: rev)
            }
        }
        status = .live
        linkOpenDocuments()
    }

    // MARK: Local edits

    private func watchDocuments() {
        guard let editor else { return }
        docWatch = editor.$documents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.linkOpenDocuments() } }
    }

    private func relativePath(_ url: URL) -> String? {
        guard let root else { return nil }
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard p.hasPrefix(r + "/") else { return nil }
        return String(p.dropFirst(r.count + 1))
    }

    private func linkOpenDocuments() {
        guard status == .live, let editor else { return }
        for doc in editor.documents.values where !doc.isBinary && doc.onLocalChange == nil {
            guard let path = relativePath(doc.url), !path.hasPrefix(".mango/"), !path.hasPrefix(".git/") else { continue }
            if let f = files[path] {
                if doc.text != f.text {
                    if doc.isDirty { localChange(path, old: f.text, new: doc.text) }   // your unsaved edits join the session
                    else { doc.replaceFromRemote(f.text); doc.saveNow() }
                }
                f.doc = doc
            } else if TextOp.len(doc.text) <= LiveSession.maxFile {
                // A file that isn't shared yet (new, or opened for the first time): add it.
                let f = FileState(doc.text, rev: 0)
                files[path] = f
                f.doc = doc
                send(["t": "add", "path": path, "text": doc.text])
            } else { continue }
            doc.onLocalChange = { [weak self] old, new in self?.localChange(path, old: old, new: new) }
            doc.onLocalSelection = { [weak self] r in self?.localSelection(path, r) }
            pushPeers(path)
        }
    }

    private func localChange(_ path: String, old: String, new: String) {
        guard let f = files[path] else { return }
        guard let op = TextOp.diff(f.text == old ? old : f.text, new) else { return }
        f.text = new
        shiftPeers(f, by: op, except: nil)
        pushPeers(path)
        if f.out == nil {
            f.out = TextOp(comps: op.comps, id: UUID().uuidString)
            sendOp(path, f, f.out!)
        } else if let buf = f.buf {
            f.buf = (try? TextOp.compose(buf, op)) ?? buf
        } else {
            f.buf = op
        }
        if let doc = f.doc { scheduleSave(path, f, doc: doc) }
    }

    private func sendOp(_ path: String, _ f: FileState, _ op: TextOp) {
        var msg: [String: Any] = ["t": "op", "path": path, "rev": f.rev, "op": op.json]
        if let id = op.id { msg["id"] = id }
        send(msg)
    }

    private func localSelection(_ path: String, _ r: NSRange) {
        selWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.send(["t": "sel", "path": path, "a": r.location, "b": NSMaxRange(r)])
        }
        selWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: Cursors

    private func shiftPeers(_ f: FileState, by op: TextOp, except: String?) {
        for (id, s) in f.peers where id != except {
            f.peers[id] = (op.transformIndex(s.a), op.transformIndex(s.b))
        }
    }

    private func pushPeers(_ path: String) {
        guard let f = files[path], let doc = f.doc else { return }
        let byId = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let carets = f.peers.compactMap { id, s -> PeerCaret? in
            guard let p = byId[id] else { return nil }
            return PeerCaret(id: id, name: p.login, color: p.color, location: min(s.a, s.b), length: abs(s.b - s.a))
        }
        doc.setPeers(AppSettings.shared.showPeerCursors ? carets : [])
    }

    // MARK: Saving (live sessions save as you go)

    private func scheduleSave(_ path: String, _ f: FileState, doc: EditorDocument? = nil) {
        guard let doc = doc ?? f.doc else { return }
        f.write?.cancel()
        let work = DispatchWorkItem { [weak doc] in if let doc, doc.isDirty { doc.save(applyCleanup: false) } }
        f.write = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func scheduleWrite(_ path: String, _ f: FileState) {
        guard let root else { return }
        f.write?.cancel()
        let url = root.appendingPathComponent(path)
        let work = DispatchWorkItem { [weak f] in
            guard let text = f?.text else { return }
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        f.write = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func flushWrites() {
        for f in files.values {
            guard let w = f.write, !w.isCancelled else { continue }
            w.cancel()
            if let doc = f.doc { if doc.isDirty { doc.saveNow() } }
            else if let root, let path = files.first(where: { $0.value === f })?.key {
                try? f.text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            f.write = nil
        }
    }
}

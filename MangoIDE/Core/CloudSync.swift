import Foundation
import CryptoKit
import UIKit

// Cloud Sync & Backup (Pro, off by default).
//
// Every project in your Projects folder is kept in step across your devices through the accounts server.
// Each project remembers what it looked like at its last sync (.mango/cloud.json), so a sync can tell
// "changed here" from "changed on another device":
//   • changed only here → uploaded      • changed only elsewhere → downloaded
//   • changed in both → yours is kept, and the other device's copy is saved next to it as "name (cloud).ext"
// Nothing is ever silently overwritten. The last 20 syncs of each project are kept as backups.

struct CloudProject: Decodable, Identifiable, Hashable {
    let name: String
    let updatedAt: String
    let snapshot: Int?
    let files: Int
    let size: Double
    let device: String?
    var id: String { name }
}

struct CloudList: Decodable {
    let pro: Bool
    let used: Double
    let quota: Double
    let projects: [CloudProject]
}

struct CloudBackup: Decodable, Identifiable, Hashable {
    let id: Int
    let files: Int
    let size: Double
    let device: String?
    let createdAt: String
}

struct CloudHistory: Decodable { let snapshots: [CloudBackup] }

enum CloudError: LocalizedError {
    case message(String), needsPro(String), behind, notFound, full(String)
    var errorDescription: String? {
        switch self {
        case .message(let m), .needsPro(let m), .full(let m): return m
        case .behind: return "Another device synced this project at the same moment. Sync again."
        case .notFound: return "That isn't in the cloud."
        }
    }
}

/// What a project looked like at its last sync. Saved as .mango/cloud.json (never uploaded).
struct CloudState: Codable {
    var snapshot: Int?
    var files: [String: String]   // path → SHA-256
}

struct CloudSummary {
    var uploaded = 0, downloaded = 0, removed = 0
    var conflicts: [String] = []
    var skipped: [String] = []
    var changedPaths: [URL] = []
    var deletedPaths: [URL] = []
}

/// The sync work itself. An actor, so hashing, file reads and network never touch the main thread.
actor CloudEngine {
    static let shared = CloudEngine()
    private let fm = FileManager.default
    private var hashCache: [String: (size: Int, date: Date, sha: String)] = [:]

    static let skipNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", "__MACOSX", ".DS_Store", "Pods"]
    static let stateFile = ".mango/cloud.json"
    static let maxFile = 25 * 1024 * 1024

    struct Entry: Equatable { let sha: String; let size: Int }

    // MARK: Network

    private func call(_ path: String, query: [String: String] = [:], method: String = "GET", body: Any? = nil,
                      timeout: TimeInterval = 120, signedIn: Bool = true) async throws -> [String: Any] {
        var request = GitHub.request(path, query: query, method: method, body: body)
        if request == nil && !signedIn, var comps = URLComponents(url: AccountManager.server.appendingPathComponent(path), resolvingAgainstBaseURL: false) {
            // Public endpoints (opening a shared link) work without an account.
            if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
            if let url = comps.url {
                var r = URLRequest(url: url)
                r.httpMethod = method
                if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
                request = r
            }
        }
        guard var req = request else {
            throw CloudError.message("Sign in with GitHub first (Settings › Account).")
        }
        req.timeoutInterval = timeout
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200..<300).contains(status) { return json }
        let msg = json["message"] as? String ?? "Cloud request failed (\(status))."
        switch status {
        case 402: throw CloudError.needsPro(msg)
        case 404: throw CloudError.notFound
        case 409 where json["behind"] as? Bool == true: throw CloudError.behind
        case 507: throw CloudError.full(msg)
        default: throw CloudError.message(msg)
        }
    }

    func list() async throws -> CloudList {
        let obj = try await call("cloud/projects")
        return try JSONDecoder().decode(CloudList.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    func history(_ name: String) async throws -> [CloudBackup] {
        let obj = try await call("cloud/history", query: ["project": name])
        return try JSONDecoder().decode(CloudHistory.self, from: JSONSerialization.data(withJSONObject: obj)).snapshots
    }

    func deleteFromCloud(_ name: String, folder: URL?) async throws {
        _ = try await call("cloud/delete", method: "POST", body: ["project": name])
        if let folder { try? fm.removeItem(at: folder.appendingPathComponent(Self.stateFile)) }
    }

    private func snapshot(_ name: String, id: Int? = nil) async throws -> (id: Int, files: [String: Entry])? {
        var q = ["project": name]
        if let id { q["id"] = String(id) }
        do {
            let obj = try await call("cloud/snapshot", query: q)
            guard let sid = (obj["id"] as? NSNumber)?.intValue, let m = obj["manifest"] as? [String: [Any]] else {
                throw CloudError.message("The cloud sent a damaged file list.")
            }
            var files: [String: Entry] = [:]
            for (p, v) in m {
                guard SafePath.ok(p), v.count >= 2, let sha = v[0] as? String, let size = (v[1] as? NSNumber)?.intValue else { continue }
                files[p] = Entry(sha: sha, size: size)
            }
            return (sid, files)
        } catch CloudError.notFound {
            return nil
        }
    }

    /// Downloads the given files' contents, batching so no single reply is huge.
    private func fetch(_ wanted: [String: Int], endpoint: String = "cloud/download", extra: [String: Any] = [:], signedIn: Bool = true) async throws -> [String: Data] {
        var out: [String: Data] = [:]
        var remaining = wanted.sorted { $0.value < $1.value }.map(\.key)
        while !remaining.isEmpty {
            var batch: [String] = [], bytes = 0
            for sha in remaining {
                let s = wanted[sha] ?? 0
                if !batch.isEmpty && (bytes + s > 20_000_000 || batch.count >= 500) { break }
                batch.append(sha); bytes += s
            }
            var body = extra
            body["shas"] = batch
            body["first"] = out.isEmpty
            let obj = try await call(endpoint, method: "POST", body: body, timeout: 300, signedIn: signedIn)
            let got = obj["blobs"] as? [String: String] ?? [:]
            if got.isEmpty { throw CloudError.message("Some files are missing from the cloud. Try a backup instead.") }
            for (sha, b64) in got {
                guard let d = Data(base64Encoded: b64), Self.sha256(d) == sha else { throw CloudError.message("A file came down damaged. Sync again.") }
                out[sha] = d
            }
            remaining.removeAll { out[$0] != nil }
        }
        return out
    }

    /// Uploads whatever the cloud doesn't already have.
    private func upload(_ files: [String: Entry], urls: [String: URL]) async throws -> Int {
        var shaToURL: [String: URL] = [:]
        var sizes: [String: Int] = [:]
        for (p, e) in files { if let u = urls[p] { shaToURL[e.sha] = u; sizes[e.sha] = e.size } }
        let obj = try await call("cloud/missing", method: "POST", body: ["shas": Array(shaToURL.keys)])
        let missing = (obj["missing"] as? [String] ?? []).sorted { (sizes[$0] ?? 0) < (sizes[$1] ?? 0) }
        var i = 0
        while i < missing.count {
            var batch: [[String: String]] = [], bytes = 0
            while i < missing.count {
                let sha = missing[i], size = sizes[sha] ?? 0
                if !batch.isEmpty && (bytes + size > 16_000_000 || batch.count >= 300) { break }
                guard let url = shaToURL[sha], let d = try? Data(contentsOf: url), Self.sha256(d) == sha else {
                    throw CloudError.behind  // file changed while syncing — start over
                }
                batch.append(["sha": sha, "data": d.base64EncodedString()])
                bytes += size; i += 1
            }
            _ = try await call("cloud/upload", method: "POST", body: ["blobs": batch], timeout: 300)
        }
        return missing.count
    }

    // MARK: Files

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private func hash(_ url: URL, size: Int, date: Date?) -> String? {
        if let date, let c = hashCache[url.path], c.size == size, c.date == date { return c.sha }
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let sha = Self.sha256(d)
        if let date { hashCache[url.path] = (size, date, sha) }
        return sha
    }

    /// Every file to sync in a project: path → (entry, url). Big files are listed in `skipped`.
    private func scan(_ root: URL) -> (files: [String: Entry], urls: [String: URL], skipped: [String]) {
        var files: [String: Entry] = [:], urls: [String: URL] = [:], skipped: [String] = []
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return (files, urls, skipped) }
        for case let u as URL in e {
            if Self.skipNames.contains(u.lastPathComponent) { e.skipDescendants(); continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true || v?.isRegularFile != true { continue }
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path
            guard p.hasPrefix(rootPath + "/") else { continue }
            let rel = String(p.dropFirst(rootPath.count + 1))
            if rel == Self.stateFile || rel.hasPrefix(".mango/drafts") { continue }
            let size = v?.fileSize ?? 0
            if size > Self.maxFile { skipped.append(rel); continue }
            guard let sha = hash(u, size: size, date: v?.contentModificationDate) else { continue }
            files[rel] = Entry(sha: sha, size: size)
            urls[rel] = u
        }
        return (files, urls, skipped)
    }

    private func loadState(_ folder: URL) -> CloudState? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent(Self.stateFile)) else { return nil }
        return try? JSONDecoder().decode(CloudState.self, from: d)
    }

    private func saveState(_ s: CloudState, _ folder: URL) throws {
        let url = folder.appendingPathComponent(Self.stateFile)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(s).write(to: url, options: .atomic)
    }

    private func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// "src/main.swift" → "src/main (cloud).swift", numbered if that's taken.
    private func conflictCopy(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = (n == 1 ? "\(stem) (cloud)" : "\(stem) (cloud \(n))") + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: Sync one project

    /// Returns nil when the project was deleted from the cloud by another device (so it should stop syncing here).
    func sync(_ name: String, folder: URL, device: String) async throws -> CloudSummary? {
        var summary = CloudSummary()
        for _ in 0..<4 {
            do {
                let state = loadState(folder) ?? CloudState(snapshot: nil, files: [:])
                let remote = try await snapshot(name)
                if remote == nil && state.snapshot != nil { return nil }
                var local = scan(folder)

                // 1. Bring in what changed on other devices.
                if let remote, remote.id != state.snapshot {
                    var want: [String: Int] = [:]
                    var actions: [(path: String, theirs: Entry?, conflict: Bool)] = []
                    for path in Set(state.files.keys).union(remote.files.keys) {
                        let base = state.files[path], theirs = remote.files[path], mine = local.files[path]?.sha
                        if base == theirs?.sha || mine == theirs?.sha { continue }
                        if mine == base {
                            actions.append((path: path, theirs: theirs, conflict: false))
                        } else {
                            guard theirs != nil || mine == nil else { continue }   // deleted there, edited here: keep yours
                            actions.append((path: path, theirs: theirs, conflict: true))
                        }
                        if let t = theirs { want[t.sha] = t.size }
                    }
                    let blobs = try await fetch(want)
                    for a in actions {
                        let target = folder.appendingPathComponent(a.path)
                        if a.conflict {
                            guard let t = a.theirs, let d = blobs[t.sha] else { continue }
                            if local.files[a.path] == nil {
                                try write(d, to: target)            // deleted here, changed there: take theirs back
                                summary.downloaded += 1
                                summary.changedPaths.append(target)
                            } else {
                                try write(d, to: conflictCopy(for: target))
                                summary.conflicts.append(a.path)
                            }
                        } else if let t = a.theirs, let d = blobs[t.sha] {
                            try write(d, to: target)
                            summary.downloaded += 1
                            summary.changedPaths.append(target)
                        } else if a.theirs == nil {
                            try? fm.removeItem(at: target)
                            summary.removed += 1
                            summary.deletedPaths.append(target)
                        }
                    }
                    local = scan(folder)
                }

                // 2. Already identical to the cloud? Just remember that.
                let localFiles = local.files.mapValues(\.sha)
                summary.skipped = local.skipped
                if let remote, remote.files.mapValues(\.sha) == localFiles {
                    try saveState(CloudState(snapshot: remote.id, files: localFiles), folder)
                    return summary
                }

                // 3. Send ours up and save a new snapshot on top of the one we merged with.
                summary.uploaded = try await upload(local.files, urls: local.urls)
                let manifest = local.files.mapValues { [$0.sha, $0.size] as [Any] }
                let obj = try await call("cloud/snapshot", method: "POST",
                                         body: ["project": name, "manifest": manifest, "base": remote.map { $0.id as Any } ?? NSNull(), "device": device],
                                         timeout: 180)
                guard let id = (obj["id"] as? NSNumber)?.intValue else { throw CloudError.message("The cloud didn't confirm the sync.") }
                try saveState(CloudState(snapshot: id, files: localFiles), folder)
                return summary
            } catch CloudError.behind {
                continue   // another device got in first: merge its changes and try again
            }
        }
        throw CloudError.behind
    }

    // MARK: Backups

    /// Downloads a backup into a new folder next to your projects.
    func restore(_ name: String, backup: Int, into parent: URL, folderName: String) async throws -> URL {
        guard let snap = try await snapshot(name, id: backup) else { throw CloudError.notFound }
        var want: [String: Int] = [:]
        for e in snap.files.values { want[e.sha] = e.size }
        let blobs = try await fetch(want)
        let dest = Workspace.shared.uniqueURL(in: parent, name: folderName)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for (path, e) in snap.files {
            guard let d = blobs[e.sha] else { continue }
            try write(d, to: dest.appendingPathComponent(path))
        }
        try? fm.removeItem(at: dest.appendingPathComponent(Self.stateFile))
        return dest
    }
}

private final class BackgroundTask {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Runs syncs and shows their status. Syncs when the app opens, when it goes to the background,
/// every few minutes while open, and when you tap Sync Now.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    @Published private(set) var syncing = false
    @Published private(set) var progress = ""
    @Published private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "cloud.lastSync") as? Date
    @Published var lastError: String?
    @Published private(set) var lastConflicts: [String] = []
    @Published private(set) var excluded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "cloud.excluded") ?? [])
    @Published private(set) var known: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "cloud.known") ?? [])

    weak var editor: EditorState?
    private var again = false
    private var timer: Timer?

    var enabled: Bool { AppSettings.shared.cloudSync }
    var parent: URL { Workspace.shared.projectsRoot ?? Workspace.shared.projectsFolder }
    static var deviceName: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    func setExcluded(_ name: String, _ on: Bool) {
        if on { excluded.insert(name) } else { excluded.remove(name) }
        UserDefaults.standard.set(Array(excluded), forKey: "cloud.excluded")
    }

    private func markKnown(_ name: String) {
        guard !known.contains(name) else { return }
        known.insert(name)
        UserDefaults.standard.set(Array(known), forKey: "cloud.known")
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { _ in
            Task { @MainActor in CloudSync.shared.syncNow() }
        }
    }

    /// Local project folders (direct subfolders of your projects folder).
    nonisolated static func localProjects(in parent: URL) -> [String: URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var out: [String: URL] = [:]
        for u in items where (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { out[u.lastPathComponent] = u }
        return out
    }

    func syncNow(force: Bool = false) {
        guard enabled || force, AccountManager.shared.isSignedIn, AccountManager.shared.isPro else { return }
        if syncing { again = true; return }
        syncing = true
        lastError = nil
        // Keeps syncing for a little while after you leave the app.
        let bg = BackgroundTask()
        bg.id = UIApplication.shared.beginBackgroundTask(withName: "MangoIDE cloud sync") { bg.end() }
        Task {
            await runAll()
            bg.end()
            syncing = false
            progress = ""
            if again { again = false; syncNow(force: force) }
        }
    }

    private func runAll() async {
        let parent = self.parent
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        let engine = CloudEngine.shared
        var errors: [String] = []
        var conflicts: [String] = []
        do {
            let cloud = try await engine.list()
            let local = await Task.detached { CloudSync.localProjects(in: parent) }.value
            var jobs: [(String, URL)] = local.filter { !excluded.contains($0.key) }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            // New projects made on another device come down automatically (but not ones you deleted here).
            for p in cloud.projects where local[p.name] == nil && !excluded.contains(p.name) && !known.contains(p.name) {
                jobs.append((p.name, parent.appendingPathComponent(p.name, isDirectory: true)))
            }
            for (name, folder) in jobs {
                progress = "Syncing \(name)…"
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    guard let s = try await engine.sync(name, folder: folder, device: Self.deviceName) else {
                        setExcluded(name, true)
                        errors.append("\(name) was removed from the cloud on another device, so it stopped syncing here.")
                        continue
                    }
                    markKnown(name)
                    conflicts += s.conflicts.map { "\(name)/\($0)" }
                    if !s.skipped.isEmpty { errors.append("\(name): skipped \(s.skipped.count) file(s) over 25 MB.") }
                    applyToEditor(s)
                } catch CloudError.needsPro(let m) {
                    errors.append(m); break
                } catch CloudError.full(let m) {
                    errors.append(m); break
                } catch {
                    errors.append("\(name): \(error.localizedDescription)")
                }
            }
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "cloud.lastSync")
        } catch {
            errors.append(error.localizedDescription)
        }
        lastConflicts = conflicts
        if !conflicts.isEmpty {
            errors.append("Changed on two devices (both kept, the other device's copy is named \"… (cloud)\"): " + conflicts.prefix(6).joined(separator: ", "))
        }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        Workspace.shared.refresh()
    }

    /// Open tabs follow files that changed on another device (unless you have unsaved edits in them).
    private func applyToEditor(_ s: CloudSummary) {
        guard let editor, !(s.changedPaths.isEmpty && s.deletedPaths.isEmpty) else { return }
        let changed = Set(s.changedPaths.map { $0.standardizedFileURL.path })
        let deleted = Set(s.deletedPaths.map { $0.standardizedFileURL.path })
        for doc in editor.documents.values where !doc.isDirty {
            let p = doc.url.standardizedFileURL.path
            if deleted.contains(p) { editor.fileDeleted(doc.url) } else if changed.contains(p) { doc.load() }
        }
    }

    // MARK: Manage

    func download(_ name: String) {
        setExcluded(name, false)
        known.remove(name)
        UserDefaults.standard.set(Array(known), forKey: "cloud.known")
        syncNow(force: true)
    }

    func delete(_ name: String) async throws {
        let folder = Self.localProjects(in: parent)[name]
        try await CloudEngine.shared.deleteFromCloud(name, folder: folder)
        setExcluded(name, true)
    }

    func restore(_ name: String, backup: CloudBackup) async throws -> URL {
        let stamp = CloudSync.shortDate(backup.createdAt).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let parent = self.parent
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        let url = try await CloudEngine.shared.restore(name, backup: backup.id, into: parent, folderName: "\(name) (backup \(stamp))")
        // A restored copy is its own project; don't let it sync until you choose to.
        setExcluded(url.lastPathComponent, true)
        Workspace.shared.refresh()
        return url
    }

    nonisolated static func shortDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let d else { return iso }
        let out = DateFormatter()
        out.dateStyle = .short
        out.timeStyle = .short
        return out.string(from: d)
    }
}


// MARK: - Share a copy (link)

struct SharedLink: Decodable, Identifiable, Hashable {
    let code: String
    let name: String
    let files: Int
    let size: Double
    let downloads: Int
    let createdAt: String
    let expiresAt: String
    let link: String
    var id: String { code }
}

struct ShareInfo {
    let code: String
    let name: String
    let owner: String
    let files: Int
    let size: Double
    let expiresAt: String
    fileprivate let manifest: [String: CloudEngine.Entry]
}

extension CloudEngine {
    /// Uploads a project (Pro) and makes a link anyone can open. Private notes in .mango aren't included.
    func share(name: String, folder: URL, days: Int) async throws -> (code: String, link: String) {
        let local = scan(folder)
        let files = local.files.filter { !$0.key.hasPrefix(".mango/") }
        guard !files.isEmpty else { throw CloudError.message("That project has no files to share.") }
        _ = try await upload(files, urls: local.urls)
        let manifest = files.mapValues { [$0.sha, $0.size] as [Any] }
        let obj = try await call("share/create", method: "POST", body: ["name": name, "manifest": manifest, "days": days], timeout: 180)
        guard let code = obj["code"] as? String, let link = obj["link"] as? String else { throw CloudError.message("The server didn't make the link.") }
        return (code, link)
    }

    func shareInfo(_ code: String) async throws -> ShareInfo {
        let obj = try await call("share/info", query: ["code": code.uppercased()], signedIn: false)
        var files: [String: Entry] = [:]
        for (p, v) in obj["manifest"] as? [String: [Any]] ?? [:] {
            if SafePath.ok(p), v.count >= 2, let sha = v[0] as? String, let size = (v[1] as? NSNumber)?.intValue { files[p] = Entry(sha: sha, size: size) }
        }
        return ShareInfo(code: obj["code"] as? String ?? code, name: obj["name"] as? String ?? "Project", owner: obj["owner"] as? String ?? "",
                         files: (obj["files"] as? NSNumber)?.intValue ?? files.count, size: (obj["size"] as? NSNumber)?.doubleValue ?? 0,
                         expiresAt: obj["expiresAt"] as? String ?? "", manifest: files)
    }

    /// Downloads a shared project into a new folder.
    func importShare(_ info: ShareInfo, into parent: URL) async throws -> URL {
        var want: [String: Int] = [:]
        for e in info.manifest.values { want[e.sha] = e.size }
        let blobs = try await fetch(want, endpoint: "share/download", extra: ["code": info.code], signedIn: false)
        let dest = Workspace.shared.uniqueURL(in: parent, name: info.name)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for (path, e) in info.manifest {
            guard let d = blobs[e.sha] else { continue }
            let url = dest.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: url, options: .atomic)
        }
        return dest
    }

    func myShares() async throws -> [SharedLink] {
        let obj = try await call("share/mine")
        let data = try JSONSerialization.data(withJSONObject: obj["shares"] ?? [])
        return try JSONDecoder().decode([SharedLink].self, from: data)
    }

    func revokeShare(_ code: String) async throws {
        _ = try await call("share/revoke", method: "POST", body: ["code": code])
    }
}

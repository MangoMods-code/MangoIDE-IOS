import Foundation
import CryptoKit
import ZIPFoundation

// GitHub without a git binary: the accounts server talks to GitHub with your (encrypted) token,
// and the app keeps a small record in <project>/.mango/github.json of which commit the project came
// from and the git hash of every file at that commit. Comparing hashes gives changes, pull and push.

struct GitHubRepo: Decodable, Identifiable, Hashable {
    let owner: String
    let name: String
    let fullName: String
    let isPrivate: Bool
    let own: Bool
    let defaultBranch: String?
    let description: String?
    let pushedAt: String?
    var id: String { fullName }

    enum CodingKeys: String, CodingKey {
        case owner, name, fullName, isPrivate = "private", own, defaultBranch, description, pushedAt
    }
}

struct GitHubRepoList: Decodable {
    let pro: Bool
    let login: String
    let repos: [GitHubRepo]
    let more: Bool
}

/// Saved in the project as .mango/github.json.
struct GitLink: Codable, Equatable {
    var owner: String
    var name: String
    var branch: String
    /// The GitHub commit this project matches.
    var commit: String
    /// path → git blob hash at that commit.
    var files: [String: String]

    var fullName: String { "\(owner)/\(name)" }
    var webURL: URL? { URL(string: "https://github.com/\(owner)/\(name)/tree/\(branch)") }
}

struct GitChange: Identifiable, Hashable {
    enum Kind: String { case added = "A", modified = "M", deleted = "D" }
    let path: String
    let kind: Kind
    var id: String { path }
}

struct PullResult {
    var commit = ""
    var updated: [String] = []
    var deleted: [String] = []
    var conflicts: [String] = []
    var upToDate = false
}

enum GitHubError: LocalizedError {
    case message(String), needsPro(String), behind(String)
    var errorDescription: String? {
        switch self { case .message(let m), .needsPro(let m), .behind(let m): return m }
    }
}

enum GitHub {
    static let work = DispatchQueue(label: "mango.github", qos: .userInitiated)
    private static let fm = FileManager.default
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()
    /// Never compared, sent or stored: the .mango folder holds the agent's notes and this link.
    static let ignored: Set<String> = [".git", ".mango", ".DS_Store", "__MACOSX"]

    private static func onMain(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    // MARK: Server requests

    static func request(_ path: String, query: [String: String] = [:], method: String = "GET", body: Any? = nil) -> URLRequest? {
        guard let token = AccountManager.shared.token,
              var comps = URLComponents(url: AccountManager.server.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    static func failure(from data: Data?, status: Int) -> GitHubError {
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let msg = json?["message"] as? String ?? (status == 0 ? "Couldn't reach the server." : "GitHub request failed (\(status)).")
        switch status {
        case 402: return .needsPro(msg)
        case 409: return .behind(msg)
        default: return .message(msg)
        }
    }

    private static let notSignedIn = GitHubError.message("Sign in with GitHub first (Settings › Account).")

    static func fetchJSON<T: Decodable>(_ type: T.Type, _ req: URLRequest?, completion: @escaping (Result<T, Error>) -> Void) {
        guard let req else { completion(.failure(notSignedIn)); return }
        session.dataTask(with: req) { data, resp, err in
            let result: Result<T, Error>
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let err { result = .failure(err) }
            else if (200..<300).contains(status), let data {
                if let v = try? JSONDecoder().decode(T.self, from: data) { result = .success(v) }
                else { result = .failure(GitHubError.message("The server sent something unexpected.")) }
            } else { result = .failure(failure(from: data, status: status)) }
            onMain { completion(result) }
        }.resume()
    }

    private static func fetchObject(_ req: URLRequest?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let req else { completion(.failure(notSignedIn)); return }
        session.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<[String: Any], Error>
            if let err { result = .failure(err) }
            else if (200..<300).contains(status), let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { result = .success(obj) }
            else { result = .failure(failure(from: data, status: status)) }
            onMain { completion(result) }
        }.resume()
    }

    /// Downloads the repo as a zip. Returns (zip file, exact commit, branch).
    static func download(owner: String, name: String, ref: String?, purpose: String,
                         completion: @escaping (Result<(URL, String, String), Error>) -> Void) {
        var q = ["owner": owner, "name": name, "purpose": purpose]
        if let ref, !ref.isEmpty { q["ref"] = ref }
        guard let req = request("github/archive", query: q) else { completion(.failure(notSignedIn)); return }
        session.downloadTask(with: req) { tmp, resp, err in
            if let err { onMain { completion(.failure(err)) }; return }
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            guard let tmp, (200..<300).contains(status) else {
                let data = tmp.flatMap { try? Data(contentsOf: $0) }
                onMain { completion(.failure(failure(from: data, status: status))) }
                return
            }
            let keep = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            do { try fm.moveItem(at: tmp, to: keep) } catch { onMain { completion(.failure(error)) }; return }
            let sha = http?.value(forHTTPHeaderField: "X-Commit-Sha") ?? ""
            let branch = http?.value(forHTTPHeaderField: "X-Branch") ?? ref ?? "main"
            onMain { completion(.success((keep, sha, branch))) }
        }.resume()
    }

    // MARK: Files and hashes

    /// Git's own id for a file's contents, so it matches what GitHub has.
    static func blobSHA(_ data: Data) -> String {
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\0".utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Only touched on `work`.
    private static var hashCache: [String: (size: Int, date: Date, sha: String)] = [:]

    /// Hash of a file, skipping the read when its size and date haven't changed since last time.
    static func hash(_ url: URL) -> String? {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let size = v?.fileSize, let date = v?.contentModificationDate, let c = hashCache[url.path], c.size == size, c.date == date {
            return c.sha
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let sha = blobSHA(data)
        if let size = v?.fileSize, let date = v?.contentModificationDate { hashCache[url.path] = (size, date, sha) }
        return sha
    }

    /// Every regular file under `root`, keyed by its path relative to `root` ("src/main.swift").
    static func scan(_ root: URL) -> [String: URL] {
        var out: [String: URL] = [:]
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return out }
        for case let u as URL in e {
            if ignored.contains(u.lastPathComponent) { e.skipDescendants(); continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }
            guard v?.isRegularFile == true else { continue }
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path
            guard p.hasPrefix(rootPath + "/") else { continue }
            out[String(p.dropFirst(rootPath.count + 1))] = u
        }
        return out
    }

    /// Unzips a GitHub download. Returns (temporary folder to delete later, the repo's files inside it).
    private static func unpack(_ zip: URL) throws -> (URL, URL) {
        let tmp = fm.temporaryDirectory.appendingPathComponent("gh-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try fm.unzipItem(at: zip, to: tmp)
        SafePath.removeEscapingLinks(in: tmp)
        let items = try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.isDirectoryKey]).filter { $0.lastPathComponent != "__MACOSX" }
        // GitHub wraps everything in one owner-repo-sha folder.
        if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return (tmp, items[0]) }
        return (tmp, tmp)
    }

    private static func place(_ src: URL, at dest: URL) throws {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        do { try fm.moveItem(at: src, to: dest) } catch { try fm.copyItem(at: src, to: dest) }
    }

    // MARK: Project link

    static func linkURL(_ project: URL) -> URL { project.appendingPathComponent(".mango/github.json") }

    static func loadLink(_ project: URL) -> GitLink? {
        guard let data = try? Data(contentsOf: linkURL(project)) else { return nil }
        return try? JSONDecoder().decode(GitLink.self, from: data)
    }

    static func saveLink(_ link: GitLink, for project: URL) throws {
        let url = linkURL(project)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(link).write(to: url, options: .atomic)
    }

    // MARK: Clone

    static func clone(owner: String, name: String, branch: String?, into parent: URL,
                      completion: @escaping (Result<URL, Error>) -> Void) {
        download(owner: owner, name: name, ref: branch, purpose: "clone") { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let (zip, commit, br)):
                work.async {
                    let result = Result<URL, Error> {
                        defer { try? fm.removeItem(at: zip) }
                        let scoped = parent.startAccessingSecurityScopedResource()
                        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
                        let (tmp, inner) = try unpack(zip)
                        defer { try? fm.removeItem(at: tmp) }
                        let dest = Workspace.shared.uniqueURL(in: parent, name: name)
                        try place(inner, at: dest)
                        var files: [String: String] = [:]
                        for (path, url) in scan(dest) { files[path] = hash(url) }
                        try saveLink(GitLink(owner: owner, name: name, branch: br, commit: commit, files: files), for: dest)
                        return dest
                    }
                    onMain { completion(result) }
                }
            }
        }
    }

    // MARK: Changes

    static func changes(in project: URL, link: GitLink) -> [GitChange] {
        let local = scan(project)
        var out: [GitChange] = []
        for (path, url) in local {
            guard let sha = hash(url) else { continue }
            if let base = link.files[path] {
                if base != sha { out.append(GitChange(path: path, kind: .modified)) }
            } else {
                out.append(GitChange(path: path, kind: .added))
            }
        }
        for path in link.files.keys where local[path] == nil { out.append(GitChange(path: path, kind: .deleted)) }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// nil link = the project isn't on GitHub yet.
    static func status(_ project: URL, completion: @escaping (GitLink?, [GitChange]) -> Void) {
        work.async {
            guard let link = loadLink(project) else { onMain { completion(nil, []) }; return }
            let c = changes(in: project, link: link)
            onMain { completion(link, c) }
        }
    }

    // MARK: Push

    static func push(_ project: URL, changes chosen: [GitChange], message: String,
                     completion: @escaping (Result<String, Error>) -> Void) {
        work.async {
            func fail(_ m: String) { onMain { completion(.failure(GitHubError.message(m))) } }
            guard let link = loadLink(project) else { fail("This project isn't linked to GitHub."); return }
            var files: [[String: Any]] = []
            var deletes: [String] = []
            var newShas: [String: String] = [:]
            var total = 0
            for c in chosen {
                if c.kind == .deleted { deletes.append(c.path); continue }
                let url = project.appendingPathComponent(c.path)
                guard let data = try? Data(contentsOf: url) else { fail("Couldn't read \(c.path)."); return }
                if data.count > 50_000_000 { fail("\(c.path) is over GitHub's 50 MB limit for one file."); return }
                total += data.count
                let perms = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
                files.append(["path": c.path, "content": data.base64EncodedString(), "executable": perms & 0o111 != 0])
                newShas[c.path] = blobSHA(data)
            }
            if total > 55_000_000 { fail("That's more than 55 MB in one push. Pick fewer files and push in parts."); return }
            let body: [String: Any] = ["owner": link.owner, "name": link.name, "branch": link.branch, "base": link.commit,
                                       "message": message, "files": files, "deletes": deletes]
            guard var req = request("github/push", method: "POST", body: body) else { onMain { completion(.failure(notSignedIn)) }; return }
            req.timeoutInterval = 600
            fetchObject(req) { r in
                switch r {
                case .failure(let e): completion(.failure(e))
                case .success(let json):
                    guard let sha = json["commit"] as? String else { completion(.failure(GitHubError.message("GitHub didn't confirm the commit."))); return }
                    work.async {
                        var updated = loadLink(project) ?? link
                        updated.commit = sha
                        for (p, s) in newShas { updated.files[p] = s }
                        for d in deletes { updated.files[d] = nil }
                        let saved = Result { try saveLink(updated, for: project) }
                        onMain {
                            if case .failure(let e) = saved { completion(.failure(e)) } else { completion(.success(sha)) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Pull

    /// Brings in GitHub's newer commits. Files only GitHub changed are updated; files only you changed are kept.
    /// If both changed a file, yours stays and GitHub's version is saved next to it as "<name>.remote".
    static func pull(_ project: URL, completion: @escaping (Result<PullResult, Error>) -> Void) {
        guard let start = loadLink(project) else { completion(.failure(GitHubError.message("This project isn't linked to GitHub."))); return }
        download(owner: start.owner, name: start.name, ref: start.branch, purpose: "pull") { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let (zip, commit, _)):
                work.async {
                    let result = Result<PullResult, Error> {
                        defer { try? fm.removeItem(at: zip) }
                        guard var link = loadLink(project) else { throw GitHubError.message("This project isn't linked to GitHub.") }
                        var out = PullResult(commit: commit)
                        if commit == link.commit { out.upToDate = true; return out }
                        let (tmp, inner) = try unpack(zip)
                        defer { try? fm.removeItem(at: tmp) }
                        let remote = scan(inner)
                        var theirsAll: [String: String] = [:]
                        for (p, u) in remote { if let d = try? Data(contentsOf: u, options: .mappedIfSafe) { theirsAll[p] = blobSHA(d) } }
                        let local = scan(project)
                        for path in Set(link.files.keys).union(theirsAll.keys) {
                            let base = link.files[path], theirs = theirsAll[path]
                            if base == theirs { continue }                          // GitHub didn't touch it
                            let mine = local[path].flatMap { hash($0) }
                            if mine == theirs { continue }                          // already the same
                            let target = project.appendingPathComponent(path)
                            if mine == base {                                       // only GitHub changed it
                                if let src = remote[path] { try place(src, at: target); out.updated.append(path) }
                                else { try? fm.removeItem(at: target); out.deleted.append(path) }
                            } else {                                                // both changed it
                                out.conflicts.append(path)
                                if let src = remote[path] {
                                    let copy = Workspace.shared.uniqueURL(in: target.deletingLastPathComponent(), name: target.lastPathComponent + ".remote")
                                    try place(src, at: copy)
                                }
                            }
                        }
                        link.commit = commit
                        link.files = theirsAll
                        try saveLink(link, for: project)
                        return out
                    }
                    onMain { completion(result) }
                }
            }
        }
    }

    // MARK: Publish (new repo from a project)

    static func publish(_ project: URL, name: String, isPrivate: Bool, description: String,
                        completion: @escaping (Result<GitLink, Error>) -> Void) {
        let req = request("github/create", method: "POST", body: ["name": name, "private": isPrivate, "description": description])
        fetchObject(req) { r in
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let json):
                guard let owner = json["owner"] as? String, let repo = json["name"] as? String,
                      let branch = json["defaultBranch"] as? String, let commit = json["commit"] as? String else {
                    completion(.failure(GitHubError.message("GitHub made the repo but sent an unexpected reply."))); return
                }
                let link = GitLink(owner: owner, name: repo, branch: branch, commit: commit, files: [:])
                work.async {
                    do { try saveLink(link, for: project) } catch { onMain { completion(.failure(error)) }; return }
                    let all = changes(in: project, link: link)
                    onMain {
                        guard !all.isEmpty else { completion(.success(link)); return }
                        push(project, changes: all, message: "First commit from MangoIDE") { p in
                            switch p {
                            case .success: completion(.success(loadLink(project) ?? link))
                            case .failure(let e):
                                completion(.failure(GitHubError.message("Made \(owner)/\(repo), but the first push failed: \(e.localizedDescription) Try Commit & Push.")))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Parsing "owner/name" or a GitHub link

    static func parseRepo(_ input: String) -> (owner: String, name: String, branch: String?)? {
        var t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("git@github.com:") { t = String(t.dropFirst("git@github.com:".count)) }
        for p in ["https://", "http://", "www.", "github.com/"] where t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        let parts = t.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        let okChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !parts[0].isEmpty, !name.isEmpty,
              parts[0].unicodeScalars.allSatisfy(okChars.contains), name.unicodeScalars.allSatisfy(okChars.contains) else { return nil }
        let branch = parts.count >= 4 && parts[2] == "tree" ? parts[3...].joined(separator: "/") : nil
        return (parts[0], name, branch)
    }
}

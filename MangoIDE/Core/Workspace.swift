import Foundation
import SwiftUI

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let modified: Date?
    let size: Int
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct LinkedFolder: Identifiable, Hashable {
    let id: String
    var name: String
    var url: URL
}

/// A file or folder the user opened from outside the app, remembered with a bookmark.
struct RecentItem: Identifiable, Hashable {
    let id: String
    var url: URL
}

enum WorkspaceError: LocalizedError {
    case exists(String), badName
    var errorDescription: String? {
        switch self {
        case .exists(let n): return "\"\(n)\" already exists here."
        case .badName: return "That name can't be used."
        }
    }
}

final class Workspace: ObservableObject {
    static let shared = Workspace()

    /// The app's Documents folder. It shows up in the Files app under On My iPhone › MangoIDE.
    let root: URL
    static let builtInFolders = ["Projects", "Scratchpad", "Snippets", "Imported", "Extensions"]

    @Published var revision = 0
    @Published private(set) var linkedFolders: [LinkedFolder] = []
    @Published private(set) var recents: [RecentItem] = []
    /// A folder the user picked that holds their project folders (e.g. iCloud Drive/Projects).
    @Published private(set) var projectsRoot: URL?
    /// The project from that folder that's open in the sidebar.
    @Published private(set) var activeProject: URL?

    var projectsFolder: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    var scratchFolder: URL { root.appendingPathComponent("Scratchpad", isDirectory: true) }
    var snippetsFolder: URL { root.appendingPathComponent("Snippets", isDirectory: true) }
    var importedFolder: URL { root.appendingPathComponent("Imported", isDirectory: true) }
    var extensionsFolder: URL { root.appendingPathComponent("Extensions", isDirectory: true) }

    private let fm = FileManager.default

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func setUp() {
        for name in Workspace.builtInFolders {
            try? fm.createDirectory(at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        let flag = "ws.didSeed"
        if !UserDefaults.standard.bool(forKey: flag) {
            UserDefaults.standard.set(true, forKey: flag)
            let welcome = scratchFolder.appendingPathComponent("Welcome.md")
            try? Workspace.welcomeText.write(to: welcome, atomically: true, encoding: .utf8)
            if let js = LanguageLibrary.builtIn.first(where: { $0.id == "javascript" }) {
                _ = try? createProject(named: "Hello Mango", language: js)
            }
        }
        loadLinked()
        loadRecents()
        loadProjectsRoot()
    }

    func refresh() { revision += 1 }

    // MARK: Listing

    func children(of dir: URL) -> [FileItem] {
        let s = AppSettings.shared
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        let opts: FileManager.DirectoryEnumerationOptions = s.showHiddenFiles ? [] : [.skipsHiddenFiles]
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: opts) else { return [] }
        var items = urls.map { u -> FileItem in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return FileItem(url: u, isDirectory: v?.isDirectory ?? false, modified: v?.contentModificationDate, size: v?.fileSize ?? 0)
        }
        items.sort { a, b in
            if s.foldersFirst && a.isDirectory != b.isDirectory { return a.isDirectory }
            switch s.sortMode {
            case "date": return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            case "kind":
                let ea = a.url.pathExtension.lowercased(), eb = b.url.pathExtension.lowercased()
                if ea != eb { return ea < eb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case "size": return a.size > b.size
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        if dir.standardizedFileURL == root.standardizedFileURL {
            // Keep the built-in folders on top, in a fixed order.
            let order = Workspace.builtInFolders
            items.sort { a, b in
                let ia = order.firstIndex(of: a.name) ?? Int.max, ib = order.firstIndex(of: b.name) ?? Int.max
                if ia != ib { return ia < ib }
                return false
            }
        }
        return items
    }

    func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    // MARK: Creating

    func uniqueURL(in dir: URL, name: String) -> URL {
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private func validate(_ name: String) throws -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "." || t == ".." || t.contains("/") || t.contains(":") { throw WorkspaceError.badName }
        return t
    }

    @discardableResult
    func createFile(named name: String, in dir: URL, contents: String = "") throws -> URL {
        let n = try validate(name)
        let url = dir.appendingPathComponent(n)
        if fm.fileExists(atPath: url.path) { throw WorkspaceError.exists(n) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        refresh()
        return url
    }

    @discardableResult
    func createFolder(named name: String, in dir: URL) throws -> URL {
        let n = try validate(name)
        let url = dir.appendingPathComponent(n, isDirectory: true)
        if fm.fileExists(atPath: url.path) { throw WorkspaceError.exists(n) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        refresh()
        return url
    }

    /// Makes Projects/<name> with a starter file for the language. Returns the main file.
    @discardableResult
    func createProject(named name: String, language: LanguageDef, in parent: URL? = nil) throws -> URL {
        let n = try validate(name)
        let dir = (parent ?? newProjectParent).appendingPathComponent(n, isDirectory: true)
        if fm.fileExists(atPath: dir.path) { throw WorkspaceError.exists(n) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let main = dir.appendingPathComponent(language.mainFileName)
        try (language.template ?? "").write(to: main, atomically: true, encoding: .utf8)
        let s = AppSettings.shared
        if s.projectReadme {
            let readme = "# \(n)\n\nA \(language.name) project made with MangoIDE.\n\nOpen `\(language.mainFileName)` and tap Run.\n"
            try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        }
        if s.projectGitignore {
            try? ".DS_Store\nbuild/\nnode_modules/\n__pycache__/\n*.o\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        }
        refresh()
        return main
    }

    // MARK: Changing

    func rename(_ url: URL, to name: String) throws -> URL {
        let n = try validate(name)
        let dest = url.deletingLastPathComponent().appendingPathComponent(n)
        if dest.path == url.path { return url }
        if fm.fileExists(atPath: dest.path) && dest.path.lowercased() != url.path.lowercased() { throw WorkspaceError.exists(n) }
        try fm.moveItem(at: url, to: dest)
        refresh()
        return dest
    }

    func duplicate(_ url: URL) throws -> URL {
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = url.pathExtension
        let name = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
        let dest = uniqueURL(in: url.deletingLastPathComponent(), name: name)
        try fm.copyItem(at: url, to: dest)
        refresh()
        return dest
    }

    func move(_ url: URL, into dir: URL) throws -> URL {
        let dest = uniqueURL(in: dir, name: url.lastPathComponent)
        try fm.moveItem(at: url, to: dest)
        refresh()
        return dest
    }

    func delete(_ url: URL) throws {
        try fm.removeItem(at: url)
        refresh()
    }

    /// Copies picked files into Imported (or a chosen folder).
    func importFiles(_ urls: [URL], into dir: URL? = nil) -> [URL] {
        let target = dir ?? importedFolder
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        var out: [URL] = []
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            let dest = uniqueURL(in: target, name: u.lastPathComponent)
            if (try? fm.copyItem(at: u, to: dest)) != nil { out.append(dest) }
        }
        refresh()
        return out
    }

    private static let ioQueue = DispatchQueue(label: "mango.import", qos: .userInitiated)

    /// Same as importFiles but off the main thread. `move` is for temporary copies the picker made.
    func importFilesInBackground(_ urls: [URL], into dir: URL? = nil, move: Bool, completion: @escaping ([URL]) -> Void) {
        let target = dir ?? importedFolder
        Workspace.ioQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            var out: [URL] = []
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                let dest = self.uniqueURL(in: target, name: u.lastPathComponent)
                var done = false
                if move { done = (try? fm.moveItem(at: u, to: dest)) != nil }
                if !done {
                    // Use a file coordinator so iCloud files are downloaded before copying.
                    var coordError: NSError?
                    NSFileCoordinator().coordinate(readingItemAt: u, options: [.withoutChanges], error: &coordError) { readURL in
                        done = (try? fm.copyItem(at: readURL, to: dest)) != nil
                    }
                }
                if done { out.append(dest) }
            }
            DispatchQueue.main.async {
                self.refresh()
                completion(out)
            }
        }
    }

    func isInside(_ url: URL, _ dir: URL) -> Bool {
        let a = url.standardizedFileURL.resolvingSymlinksInPath().path
        let b = dir.standardizedFileURL.resolvingSymlinksInPath().path
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    /// Inside MangoIDE's own folders, a linked folder or the projects folder.
    func isKnownLocation(_ url: URL) -> Bool {
        if isInside(url, root) { return true }
        if let pr = projectsRoot, isInside(url, pr) { return true }
        return linkedFolders.contains { isInside(url, $0.url) }
    }

    func isBuiltInFolder(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
            && Workspace.builtInFolders.contains(url.lastPathComponent)
    }

    func displayPath(_ url: URL) -> String {
        if isInside(url, root) {
            let r = root.standardizedFileURL.resolvingSymlinksInPath().path
            let p = url.standardizedFileURL.resolvingSymlinksInPath().path
            let rel = String(p.dropFirst(r.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel.isEmpty ? "MangoIDE" : "MangoIDE/" + rel
        }
        if let pr = projectsRoot, isInside(url, pr) {
            let rel = String(url.standardizedFileURL.path.dropFirst(pr.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel.isEmpty ? pr.lastPathComponent : pr.lastPathComponent + "/" + rel
        }
        for l in linkedFolders where isInside(url, l.url) {
            let rel = String(url.path.dropFirst(l.url.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel.isEmpty ? l.name : l.name + "/" + rel
        }
        return url.path
    }

    // MARK: Projects folder

    private func loadProjectsRoot() {
        projectsRoot = loadBookmarks("ws.projectsRoot").first?.1
        if let root = projectsRoot, let name = UserDefaults.standard.string(forKey: "ws.activeProject") {
            let u = root.appendingPathComponent(name, isDirectory: true)
            activeProject = isDirectory(u) ? u : nil
        }
    }

    func setProjectsRoot(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        projectsRoot = url
        activeProject = nil
        UserDefaults.standard.removeObject(forKey: "ws.activeProject")
        saveBookmarks("ws.projectsRoot", [("root", url)])
        refresh()
    }

    func clearProjectsRoot() {
        projectsRoot = nil
        activeProject = nil
        UserDefaults.standard.removeObject(forKey: "ws.projectsRoot")
        UserDefaults.standard.removeObject(forKey: "ws.activeProject")
        refresh()
    }

    /// Every folder directly inside the projects folder, newest first.
    func projects() -> [FileItem] {
        guard let root = projectsRoot else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { u -> FileItem? in
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.isDirectory == true else { return nil }
            return FileItem(url: u, isDirectory: true, modified: v?.contentModificationDate, size: 0)
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    func openProject(_ url: URL?) {
        activeProject = url
        if let url { UserDefaults.standard.set(url.lastPathComponent, forKey: "ws.activeProject") }
        else { UserDefaults.standard.removeObject(forKey: "ws.activeProject") }
        refresh()
    }

    /// Where New Project puts things: your projects folder if you picked one, otherwise MangoIDE/Projects.
    var newProjectParent: URL { projectsRoot ?? projectsFolder }

    // MARK: Linked folders (outside the app, e.g. iCloud Drive or another app's folder)

    private struct StoredBookmark: Codable { var id: String; var data: Data }

    private func loadBookmarks(_ key: String) -> [(String, URL)] {
        guard let raw = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([StoredBookmark].self, from: raw) else { return [] }
        var out: [(String, URL)] = []
        for b in list {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: b.data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource() // held for the app's lifetime
                out.append((b.id, url))
            }
        }
        return out
    }

    private func saveBookmarks(_ key: String, _ urls: [(String, URL)]) {
        let list = urls.compactMap { pair -> StoredBookmark? in
            guard let d = try? pair.1.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
            return StoredBookmark(id: pair.0, data: d)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }

    private func loadLinked() {
        linkedFolders = loadBookmarks("ws.linked").map { LinkedFolder(id: $0.0, name: $0.1.lastPathComponent, url: $0.1) }
    }

    func linkFolder(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        if linkedFolders.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { return }
        linkedFolders.append(LinkedFolder(id: UUID().uuidString, name: url.lastPathComponent, url: url))
        saveBookmarks("ws.linked", linkedFolders.map { ($0.id, $0.url) })
        refresh()
    }

    func unlink(_ folder: LinkedFolder) {
        linkedFolders.removeAll { $0.id == folder.id }
        saveBookmarks("ws.linked", linkedFolders.map { ($0.id, $0.url) })
        refresh()
    }

    private func loadRecents() {
        recents = loadBookmarks("ws.recents").map { RecentItem(id: $0.0, url: $0.1) }
    }

    func noteRecent(_ url: URL) {
        recents.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        recents.insert(RecentItem(id: UUID().uuidString, url: url), at: 0)
        if recents.count > 15 { recents = Array(recents.prefix(15)) }
        saveBookmarks("ws.recents", recents.map { ($0.id, $0.url) })
    }

    func clearRecents() {
        recents = []
        saveBookmarks("ws.recents", [])
    }

    static let welcomeText = """
    # Welcome to MangoIDE 🥭

    Your files live in these folders (also visible in the Files app under **On My iPhone › MangoIDE**):

    - **Projects** – one folder per project. Use *New Project* to start one from a template.
    - **Scratchpad** – quick notes and throwaway code.
    - **Snippets** – code you want to keep around.
    - **Imported** – files you bring in with *Import Files*.
    - **Extensions** – themes, languages and snippets you install.

    ## Tips
    - Long-press a tab and pick *Open to the Side*, or tap the split button, to edit two files side by side.
    - Long-press a file in the sidebar for rename, duplicate, delete and more.
    - The key row above the keyboard has Tab, arrows, undo and symbols. Change it in Settings › Keyboard.
    - JavaScript runs right on your phone. HTML opens a live preview. Every other language runs on a runner server you set in Settings › Run.
    """
}

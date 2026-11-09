import SwiftUI
import UniformTypeIdentifiers

@main
struct MangoIDEApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var workspace = Workspace.shared
    @StateObject private var editor = EditorState()
    @StateObject private var extensions = ExtensionManager.shared
    @StateObject private var console = ConsoleModel()
    @StateObject private var router = Router()
    @StateObject private var agent = AgentSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(workspace)
                .environmentObject(editor)
                .environmentObject(extensions)
                .environmentObject(console)
                .environmentObject(router)
                .environmentObject(agent)
                .onAppear {
                    router.editor = editor
                    agent.editor = editor
                    AccountManager.shared.refresh()
                    FilePicker.onAccessRefused = { [weak router] why in router?.errorMessage = why }
                    workspace.setUp()
                    extensions.reload()
                    editor.restoreSession()
                    settings.applyIdleTimer()
                    if editor.panes.allSatisfy({ $0.tabs.isEmpty }) && editor.lastProject == nil && settings.showWelcome {
                        editor.open(workspace.scratchFolder.appendingPathComponent("Welcome.md"))
                    }
                }
                .onOpenURL { url in
                    if url.scheme == "mangoide" {
                        // Back from Stripe checkout or the billing portal.
                        AccountManager.shared.refresh()
                        return
                    }
                    if ArchiveService.isArchive(url) { router.importAndExtract([url]) } else { editor.openExternal(url) }
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { editor.saveAllNow(); editor.saveSession() }
            else { AccountManager.shared.refresh() }
        }
    }
}

enum AppSheet: Identifiable {
    case newFile(URL), newFolder(URL), newProject, settings, extensions, snippets
    case importFiles(URL?), openFile, linkFolder, installExtensionFile, importArchive
    case projects, pickProjectsFolder, agent

    var id: String {
        switch self {
        case .newFile(let u): return "newFile" + u.path
        case .newFolder(let u): return "newFolder" + u.path
        case .newProject: return "newProject"
        case .settings: return "settings"
        case .extensions: return "extensions"
        case .snippets: return "snippets"
        case .importFiles(let u): return "import" + (u?.path ?? "")
        case .openFile: return "openFile"
        case .linkFolder: return "linkFolder"
        case .installExtensionFile: return "installExt"
        case .importArchive: return "importArchive"
        case .projects: return "projects"
        case .pickProjectsFolder: return "pickProjectsFolder"
        case .agent: return "agent"
        }
    }
}

/// UI state shared across views: which sheet is up, the sidebar, and pending dialogs.
final class Router: ObservableObject {
    @Published var sheet: AppSheet?
    @Published var sidebarOpen = UIDevice.current.userInterfaceIdiom == .pad
    @Published var renameTarget: URL?
    @Published var renameText = ""
    @Published var deleteTarget: URL?
    @Published var showGoToLine = false
    @Published var goToLineText = ""
    @Published var errorMessage: String?
    @Published var toast: String?

    // Archives
    @Published var busy: String?
    @Published var extractConfirm: URL?
    @Published var passwordTarget: URL?
    @Published var archivePassword = ""
    @Published var passwordMessage = ""
    @Published var revealRequest: URL?
    private var pendingExtract: (url: URL, dir: URL?, deleteAfter: Bool)?

    weak var editor: EditorState?

    /// File pickers are presented straight from UIKit (see FilePicker); everything else is a sheet.
    func show(_ s: AppSheet) {
        switch s {
        case .importFiles(let dir):
            FilePicker.present(types: [.item], multiple: true, asCopy: true) { [weak self] urls in
                self?.importInBackground(urls, into: dir, move: true) { copied in
                    if copied.count == 1, let u = copied.first, !ArchiveService.isArchive(u) { self?.editor?.open(u) }
                }
            }
        case .openFile:
            FilePicker.present(types: [.item], multiple: true, asCopy: false) { [weak self] urls in
                let archives = urls.filter { ArchiveService.isArchive($0) }
                if !archives.isEmpty { self?.importAndExtract(archives, move: false) }
                for u in urls where !ArchiveService.isArchive(u) { self?.editor?.openExternal(u) }
            }
        case .linkFolder:
            FilePicker.present(types: [.folder], multiple: false, asCopy: false) { [weak self] urls in
                guard let u = urls.first else { return }
                Workspace.shared.linkFolder(u)
                self?.revealRequest = u
                self?.sidebarOpen = true
                self?.flash("Opened \(u.lastPathComponent)")
            }
        case .pickProjectsFolder:
            FilePicker.present(types: [.folder], multiple: false, asCopy: false) { [weak self] urls in
                guard let u = urls.first else { return }
                Workspace.shared.setProjectsRoot(u)
                self?.sidebarOpen = true
                self?.flash("Projects folder set to \(u.lastPathComponent)")
            }
        case .importArchive:
            let types: [UTType] = [.zip, UTType("com.rarlab.rar-archive"), UTType(filenameExtension: "rar"), .archive].compactMap { $0 }
            FilePicker.present(types: types, multiple: true, asCopy: true) { [weak self] urls in
                self?.importAndExtract(urls, move: true)
            }
        case .installExtensionFile:
            FilePicker.present(types: [.json, .item], multiple: false, asCopy: true) { [weak self] urls in
                guard let u = urls.first else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = try? Data(contentsOf: u)
                    DispatchQueue.main.async {
                        guard let data else { self?.errorMessage = "Couldn't read that file."; return }
                        do { let m = try ExtensionManager.shared.install(data: data); self?.flash("Installed \(m.name)") }
                        catch { self?.fail(error) }
                    }
                }
            }
        default:
            sheet = s
        }
    }

    /// Copies (or moves, for the picker's own temporary copies) files in the background so big
    /// imports never freeze the app.
    func importInBackground(_ urls: [URL], into dir: URL? = nil, move: Bool, then: (([URL]) -> Void)? = nil) {
        busy = urls.count == 1 ? "Importing \(urls[0].lastPathComponent)…" : "Importing \(urls.count) items…"
        Workspace.shared.importFilesInBackground(urls, into: dir, move: move) { [weak self] copied in
            self?.busy = nil
            if copied.count < urls.count {
                self?.errorMessage = "Imported \(copied.count) of \(urls.count). Some items couldn't be copied."
            } else {
                self?.flash("Imported \(copied.count) item\(copied.count == 1 ? "" : "s")")
            }
            if let first = copied.first { self?.revealRequest = first }
            then?(copied)
        }
    }

    func extract(_ url: URL, into dir: URL? = nil, password: String? = nil, deleteAfter: Bool = false) {
        busy = "Extracting \(url.lastPathComponent)…"
        ArchiveService.extract(url, into: dir, password: password) { [weak self] result in
            guard let self else { return }
            self.busy = nil
            switch result {
            case .success(let folder):
                if deleteAfter { try? FileManager.default.removeItem(at: url) }
                Workspace.shared.refresh()
                self.revealRequest = folder
                self.flash("Extracted to \(folder.lastPathComponent)")
            case .failure(let error):
                if let a = error as? ArchiveError, case .needsPassword = a {
                    self.pendingExtract = (url, dir, deleteAfter)
                    self.archivePassword = ""
                    self.passwordMessage = "This archive is locked."
                    self.passwordTarget = url
                } else if let a = error as? ArchiveError, case .wrongPassword = a {
                    self.pendingExtract = (url, dir, deleteAfter)
                    self.archivePassword = ""
                    self.passwordMessage = "That password didn't work. Try again."
                    self.passwordTarget = url
                } else {
                    if deleteAfter { try? FileManager.default.removeItem(at: url) }
                    self.fail(error)
                }
            }
        }
    }

    func retryExtractWithPassword() {
        guard let p = pendingExtract else { return }
        pendingExtract = nil
        passwordTarget = nil
        extract(p.url, into: p.dir, password: archivePassword, deleteAfter: p.deleteAfter)
    }

    func cancelPassword() {
        if let p = pendingExtract, p.deleteAfter { try? FileManager.default.removeItem(at: p.url) }
        pendingExtract = nil
        passwordTarget = nil
        Workspace.shared.refresh()
    }

    /// Archives picked or shared from outside: copy into Imported, extract there, drop the copy.
    func importAndExtract(_ urls: [URL], move: Bool = false) {
        busy = "Importing…"
        Workspace.shared.importFilesInBackground(urls, into: nil, move: move) { [weak self] copies in
            self?.busy = nil
            for c in copies { self?.extract(c, deleteAfter: true) }
        }
    }

    /// Folder → .mcpack (single pack) or .mcaddon (folder of packs), then optionally straight to Minecraft.
    func exportMinecraft(_ folder: URL, open: Bool) {
        busy = "Building add-on…"
        Minecraft.export(folder) { [weak self] result in
            guard let self else { return }
            self.busy = nil
            switch result {
            case .success(let file):
                Workspace.shared.refresh()
                self.revealRequest = file
                if open { Minecraft.share(file) } else { self.flash("Saved \(file.lastPathComponent)") }
            case .failure(let e): self.fail(e)
            }
        }
    }

    func compress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        busy = "Making zip…"
        ArchiveService.compress(urls) { [weak self] result in
            guard let self else { return }
            self.busy = nil
            switch result {
            case .success(let zip):
                Workspace.shared.refresh()
                self.revealRequest = zip
                self.flash("Saved \(zip.lastPathComponent)")
            case .failure(let e): self.fail(e)
            }
        }
    }

    func fail(_ error: Error) { errorMessage = error.localizedDescription }

    func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    func beginRename(_ url: URL) {
        renameText = url.lastPathComponent
        renameTarget = url
    }
}

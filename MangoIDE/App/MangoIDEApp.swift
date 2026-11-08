import SwiftUI

@main
struct MangoIDEApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var workspace = Workspace.shared
    @StateObject private var editor = EditorState()
    @StateObject private var extensions = ExtensionManager.shared
    @StateObject private var console = ConsoleModel()
    @StateObject private var router = Router()
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
                .preferredColorScheme(settings.colorSchemeOverride)
                .tint(settings.accentColor)
                .onAppear {
                    workspace.setUp()
                    extensions.reload()
                    editor.restoreSession()
                    settings.applyIdleTimer()
                    if editor.panes.allSatisfy({ $0.tabs.isEmpty }) && settings.showWelcome {
                        editor.open(workspace.scratchFolder.appendingPathComponent("Welcome.md"))
                    }
                }
                .onOpenURL { url in
                    if ArchiveService.isArchive(url) { router.importAndExtract([url]) } else { editor.openExternal(url) }
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { editor.saveAll(); editor.saveSession() }
        }
    }
}

enum AppSheet: Identifiable {
    case newFile(URL), newFolder(URL), newProject, settings, extensions, snippets
    case importFiles(URL?), openFile, linkFolder, installExtensionFile, importArchive

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

    func show(_ s: AppSheet) { sheet = s }

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
    func importAndExtract(_ urls: [URL]) {
        let copies = Workspace.shared.importFiles(urls)
        for c in copies { extract(c, deleteAfter: true) }
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

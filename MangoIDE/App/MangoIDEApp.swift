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
                .onOpenURL { url in editor.openExternal(url) }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { editor.saveAll(); editor.saveSession() }
        }
    }
}

enum AppSheet: Identifiable {
    case newFile(URL), newFolder(URL), newProject, settings, extensions, snippets
    case importFiles(URL?), openFile, linkFolder, installExtensionFile

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

    func show(_ s: AppSheet) { sheet = s }

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

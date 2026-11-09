import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var extensions: ExtensionManager
    @EnvironmentObject var console: ConsoleModel
    @EnvironmentObject var router: Router
    @EnvironmentObject var agent: AgentSession
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var live = LiveSession.shared

    var theme: EditorTheme { extensions.theme(id: settings.effectiveThemeID) }

    /// Light/dark follows the theme when "Theme Styles Whole App" is on.
    var appScheme: ColorScheme? {
        settings.themeControlsApp && settings.appearance == "system" ? (theme.isDark ? .dark : .light) : settings.colorSchemeOverride
    }
    var appTint: Color { settings.themeControlsApp ? theme.accentColor : settings.accentColor }
    var chrome: ChromeStyle {
        ChromeStyle(background: settings.themeControlsApp ? theme.chromeColor : nil,
                    text: settings.themeControlsApp ? theme.chromeTextColor : nil,
                    translucent: settings.backgroundActive)
    }

    var body: some View {
        ZStack {
            if let bgURL = settings.backgroundURL {
                AppBackground(url: bgURL, kind: settings.backgroundKind, fit: settings.backgroundFit,
                              dim: settings.backgroundDim, frost: settings.backgroundBlur,
                              animate: settings.animateBackground && scenePhase == .active)
            }
            mainContent
            if settings.showEffects, let effect = theme.effect {
                EffectOverlay(effect: effect, intensity: settings.effectIntensity, running: scenePhase == .active)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .opacity(0.85)
            }
        }
        .environment(\.chrome, chrome)
        .preferredColorScheme(appScheme)
        .tint(appTint)
        .themedFontDesign(settings.themeControlsApp ? theme.design : .default)
        .sheet(item: $router.sheet) { sheet in sheetView(sheet) }
        .sheet(item: $console.preview) { item in PreviewSheet(item: item) }
        .modifier(RootDialogs(theme: theme))
        .alert("Live Session", isPresented: Binding(get: { live.message != nil && router.sheet == nil }, set: { if !$0 { live.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(live.message ?? "") }
        .onChange(of: editor.explorerRequest) { _ in
            guard let project = editor.lastProject else { return }
            withAnimation(.easeOut(duration: 0.2)) { router.sidebarOpen = true }
            router.revealRequest = project.appendingPathComponent(".mango-reveal")
        }
    }

    private var mainContent: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 700
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if wide && router.sidebarOpen {
                        SidebarView()
                            .frame(width: min(CGFloat(settings.sidebarWidth), geo.size.width * 0.45))
                        Divider()
                    }
                    VStack(spacing: 0) {
                        TopBar(wide: wide)
                        Divider()
                        EditorArea(size: geo.size)
                        if console.isVisible {
                            ConsoleView()
                                .frame(height: max(140, geo.size.height * CGFloat(settings.consoleHeight)))
                                .transition(.move(edge: .bottom))
                        }
                        if settings.showStatusBar { StatusBar() }
                    }
                    .background(settings.backgroundActive ? Color.clear : Color(uiColor: theme.bg))
                }
                if !wide && router.sidebarOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { router.sidebarOpen = false } }
                    SidebarView()
                        .frame(width: min(330, geo.size.width * 0.86))
                        .background(settings.themeControlsApp ? theme.chromeColor : Color(uiColor: .systemBackground))
                        .transition(.move(edge: .leading))
                        .shadow(radius: 12)
                }
                if let b = router.busy {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) { ProgressView(); Text(b).font(.subheadline.weight(.medium)) }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 60)
                    }
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }
                if let t = router.toast {
                    VStack {
                        Spacer()
                        Text(t)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 60)
                    }
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: router.sidebarOpen)
            .animation(.easeOut(duration: 0.2), value: console.isVisible)
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: AppSheet) -> some View {
        Group {
            switch sheet {
            case .newFile(let dir): NewFileSheet(directory: dir)
            case .newFolder(let dir): NewFolderSheet(directory: dir)
            case .newProject: NewProjectSheet()
            case .settings: SettingsView()
            case .extensions: NavigationStack { ExtensionsView() }
            case .snippets: SnippetsSheet()
            case .projects: ProjectsSheet()
            case .welcome: WelcomeSignInView()
            case .github: GitHubView()
            case .collab: CollabView()
            case .openShare(let code): OpenShareSheet(code: code)
            case .joinLive(let code): JoinLiveSheet(code: code)
            case .problems: ProblemsSheet()
            case .findInFiles: FindInFilesView()
            case .outline: OutlineSheet()
            case .definitions(let name, let results): DefinitionsSheet(name: name, results: results)
            case .runConfig: RunConfigSheet()
            case .agent:
                if #available(iOS 16.4, *) {
                    AgentView()
                        .presentationDetents([.medium, .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                } else {
                    AgentView().presentationDetents([.medium, .large])
                }
            default:
                EmptyView()
            }
        }
        .environmentObject(settings)
        .environmentObject(workspace)
        .environmentObject(editor)
        .environmentObject(extensions)
        .environmentObject(console)
        .environmentObject(router)
        .environmentObject(agent)
        .environment(\.chrome, chrome)
        .preferredColorScheme(appScheme)
        .tint(appTint)
    }

}

// MARK: - Top bar

/// Shows who's in the live session; tap to manage it.
struct LiveIndicator: View {
    @ObservedObject var live = LiveSession.shared
    @EnvironmentObject var router: Router
    var body: some View {
        if live.isActive {
            Button { router.show(.collab) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "person.2.fill")
                    Text("\(live.people.count)").font(.caption.bold()).monospacedDigit()
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .foregroundStyle(.white)
                .background(live.status == .live ? Color.green : Color.orange, in: Capsule())
            }
            .accessibilityLabel("Live session, \(live.people.count) people")
        }
    }
}

struct TopBar: View {
    let wide: Bool
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var extensions: ExtensionManager
    @EnvironmentObject var console: ConsoleModel
    @EnvironmentObject var router: Router
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 4) {
            barButton("sidebar.left") { withAnimation { router.sidebarOpen.toggle() } }
            if let doc = editor.activeDocument {
                ActiveTitle(doc: doc)
            } else {
                Text("MangoIDE").font(.headline)
            }
            Spacer(minLength: 4)
            if console.isRunning {
                ProgressView().padding(.horizontal, 6)
            }
            barButton("play.fill", tint: .green) { runActive() }
                .disabled(editor.activeDocument == nil)
            barButton(editor.isSplit ? "rectangle" : "rectangle.split.2x1") { editor.toggleSplit() }
            if wide {
                barButton("magnifyingglass") { editor.showFind(replace: true) }
                    .disabled(editor.activeDocument == nil)
            }
            LiveIndicator()
            barButton("sparkles") { router.show(.agent) }
            barButton("terminal") { console.isVisible.toggle() }
            moreMenu
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .chromeBackground()
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button { router.show(.newFile(defaultFolder)) } label: { Label("New File", systemImage: "doc.badge.plus") }
                Button { router.show(.newFolder(defaultFolder)) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Button { router.show(.newProject) } label: { Label("New Project", systemImage: "shippingbox") }
            }
            Section {
                Button { router.show(.openFile) } label: { Label("Open File…", systemImage: "doc") }
                Button { router.show(.importFiles(nil)) } label: { Label("Import Files…", systemImage: "square.and.arrow.down") }
                Button { router.show(.linkFolder) } label: { Label("Open Folder…", systemImage: "folder") }
                Button { router.show(.importArchive) } label: { Label("Import ZIP / RAR…", systemImage: "doc.zipper") }
                Button { router.show(.github) } label: { Label("GitHub…", systemImage: "arrow.triangle.branch") }
                Button { router.show(.collab) } label: { Label("Share & Collaborate…", systemImage: "person.2") }
            }
            Section {
                Button { router.show(workspace.projectsRoot == nil ? .pickProjectsFolder : .projects) } label: {
                    Label(workspace.projectsRoot == nil ? "Choose Projects Folder…" : "Switch Project…", systemImage: "square.grid.2x2")
                }
            }
            Section {
                Button { if editor.saveActive() { settings.haptic(); router.flash("Saved") } } label: { Label("Save", systemImage: "square.and.arrow.down.on.square") }
                    .disabled(editor.activeDocument == nil)
                Button { editor.saveAll(); router.flash("Saved all") } label: { Label("Save All", systemImage: "square.stack.3d.down.forward") }
            }
            Section {
                Button { router.show(.findInFiles) } label: { Label("Find in Files…", systemImage: "doc.text.magnifyingglass") }
                Button { router.show(.problems) } label: { Label("Problems", systemImage: "exclamationmark.triangle") }
                Button { router.show(.runConfig) } label: { Label("Run Settings…", systemImage: "slider.horizontal.3") }
            }
            if editor.activeDocument != nil {
                Section {
                    Button { editor.showFind(replace: false) } label: { Label("Find", systemImage: "magnifyingglass") }
                    Button { editor.showFind(replace: true) } label: { Label("Find & Replace", systemImage: "arrow.left.arrow.right") }
                    Button { router.goToLineText = ""; router.showGoToLine = true } label: { Label("Go to Line…", systemImage: "arrow.down.to.line") }
                    Button { router.show(.snippets) } label: { Label("Insert Snippet…", systemImage: "text.badge.plus") }
                    Button { router.show(.outline) } label: { Label("Go to Symbol…", systemImage: "list.bullet.indent") }
                    Button { CodeActions.goToDefinition(editor: editor, workspace: workspace, router: router) } label: { Label("Go to Definition", systemImage: "arrow.right.circle") }
                    Button { CodeActions.format(editor: editor, router: router) } label: { Label("Format Document", systemImage: "text.alignleft") }
                    Menu {
                        Button { editor.activeTextView?.toggleComment(lineComment: extensions.language(for: editor.activeDocument?.url).lineComment) } label: { Label("Toggle Comment", systemImage: "number") }
                        Button { editor.activeTextView?.indentSelection(outdent: false) } label: { Label("Indent", systemImage: "increase.indent") }
                        Button { editor.activeTextView?.indentSelection(outdent: true) } label: { Label("Outdent", systemImage: "decrease.indent") }
                        Button { editor.activeTextView?.duplicateLine() } label: { Label("Duplicate Line", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) { editor.activeTextView?.deleteLine() } label: { Label("Delete Line", systemImage: "minus.square") }
                        Button { editor.activeTextView?.selectLine() } label: { Label("Select Line", systemImage: "selection.pin.in.out") }
                    } label: { Label("Edit Line", systemImage: "text.cursor") }
                }
            }
            Section {
                Button { editor.toggleSplit() } label: { Label(editor.isSplit ? "Close Split" : "Split Editor", systemImage: "rectangle.split.2x1") }
                if editor.isSplit {
                    Button {
                        settings.splitOrientation = settings.splitOrientation == "vertical" ? "horizontal" : "vertical"
                    } label: { Label("Flip Split Direction", systemImage: "rotate.right") }
                }
                Button { editor.closeAll(pane: editor.focusedPane) } label: { Label("Close All Tabs", systemImage: "xmark.square") }
            }
            Section {
                Button { router.show(.extensions) } label: { Label("Extensions", systemImage: "puzzlepiece.extension") }
                Button { router.show(.settings) } label: { Label("Settings", systemImage: "gearshape") }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 19)).frame(width: 38, height: 38)
        }
    }

    private var defaultFolder: URL {
        if let d = editor.activeDocument, workspace.isKnownLocation(d.url) {
            return d.url.deletingLastPathComponent()
        }
        return workspace.activeProject ?? workspace.scratchFolder
    }

    private func runActive() {
        guard let doc = editor.activeDocument else { return }
        editor.activeTextView?.resignFirstResponder()
        RunService.run(doc, language: extensions.language(for: doc.url), console: console)
    }

    private func barButton(_ symbol: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint ?? Color.accentColor)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
    }
}

struct ActiveTitle: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        HStack(spacing: 5) {
            Text(doc.name).font(.headline).lineLimit(1).truncationMode(.middle)
            if doc.isDirty { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var extensions: ExtensionManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 12) {
            if let doc = editor.activeDocument {
                Text(workspace.displayPath(doc.url.deletingLastPathComponent())).lineLimit(1).truncationMode(.head)
                Spacer()
                ProblemsBadge(doc: doc)
                CursorLabel(cursor: editor.cursor)
                Text(settings.insertSpaces ? "Spaces: \(settings.tabWidth)" : "Tabs")
                Menu(extensions.language(for: doc.url).name) {
                    Text("Language is picked from the file extension")
                }
            } else {
                Text("No file open")
                Spacer()
            }
            if settings.themeControlsApp, let e = extensions.theme(id: settings.effectiveThemeID).emoji { Text(e) }
            Text("v\(Bundle.main.appVersion)")
                .foregroundStyle(.tertiary)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .chromeBackground()
    }
}

extension Bundle {
    var appVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    var appBuild: String { infoDictionary?["CFBundleVersion"] as? String ?? "?" }
}

struct CursorLabel: View {
    @ObservedObject var cursor: CursorModel
    var body: some View { Text("Ln \(cursor.line), Col \(cursor.column)") }
}


/// Alerts and confirmation dialogs for the main screen.
struct RootDialogs: ViewModifier {
    let theme: EditorTheme
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var router: Router

    func body(content: Content) -> some View {
        content
        .alert("Rename", isPresented: Binding(get: { router.renameTarget != nil }, set: { if !$0 { router.renameTarget = nil } })) {
                TextField("Name", text: $router.renameText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) { router.renameTarget = nil }
                Button("Rename") { doRename() }
            }
                .alert("Delete \"\(router.deleteTarget?.lastPathComponent ?? "")\"?",
                   isPresented: Binding(get: { router.deleteTarget != nil }, set: { if !$0 { router.deleteTarget = nil } })) {
                Button("Cancel", role: .cancel) { router.deleteTarget = nil }
                Button("Delete", role: .destructive) { if let u = router.deleteTarget { performDelete(u) } }
            } message: {
                Text("This can't be undone.")
            }
                .alert("Go to Line", isPresented: $router.showGoToLine) {
                TextField("Line number", text: $router.goToLineText).keyboardType(.numberPad)
                Button("Cancel", role: .cancel) {}
                Button("Go") { if let n = Int(router.goToLineText) { editor.goToLine(n) } }
            }
                .alert("Something went wrong", isPresented: Binding(get: { router.errorMessage != nil }, set: { if !$0 { router.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(router.errorMessage ?? "") }
                .alert("Save changes to \"\(editor.doc(editor.closeRequest?.doc)?.name ?? "this file")\"?",
                   isPresented: Binding(get: { editor.closeRequest != nil }, set: { if !$0 && editor.closeRequest != nil { editor.cancelClose() } })) {
                Button("Save") { if let r = editor.closeRequest { editor.finishClose(r, save: true) } }
                Button("Discard", role: .destructive) { if let r = editor.closeRequest { editor.finishClose(r, save: false) } }
                Button("Cancel", role: .cancel) { editor.cancelClose() }
            } message: {
                Text("This file has changes that aren't saved. Discard throws them away and keeps the file as it was last saved.")
            }
                .alert("Password for \"\(router.passwordTarget?.lastPathComponent ?? "archive")\"",
                   isPresented: Binding(get: { router.passwordTarget != nil }, set: { if !$0 && router.passwordTarget != nil { router.passwordTarget = nil } })) {
                SecureField("Password", text: $router.archivePassword)
                Button("Cancel", role: .cancel) { router.cancelPassword() }
                Button("Extract") { router.retryExtractWithPassword() }
            } message: { Text(router.passwordMessage) }
                .confirmationDialog(router.extractConfirm?.lastPathComponent ?? "",
                                isPresented: Binding(get: { router.extractConfirm != nil }, set: { if !$0 { router.extractConfirm = nil } }),
                                titleVisibility: .visible) {
                Button("Extract Here") { if let u = router.extractConfirm { router.extract(u) } }
                Button("Extract to Imported") { if let u = router.extractConfirm { router.extract(u, into: workspace.importedFolder) } }
                Button("Cancel", role: .cancel) {}
            }
                .onReceive(NotificationCenter.default.publisher(for: .showSnippets)) { _ in router.show(.snippets) }
    }

    private func doRename() {
        guard let url = router.renameTarget else { return }
        router.renameTarget = nil
        do {
            let new = try workspace.rename(url, to: router.renameText)
            editor.fileRenamed(from: url, to: new)
        } catch { router.fail(error) }
    }

    private func performDelete(_ url: URL) {
        router.deleteTarget = nil
        do {
            editor.fileDeleted(url)
            try workspace.delete(url)
        } catch { router.fail(error) }
    }
}

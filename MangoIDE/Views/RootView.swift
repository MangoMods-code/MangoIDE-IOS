import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var extensions: ExtensionManager
    @EnvironmentObject var console: ConsoleModel
    @EnvironmentObject var router: Router

    var theme: EditorTheme { extensions.theme(id: settings.themeID) }

    var body: some View {
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
                    .background(Color(uiColor: theme.bg))
                }
                if !wide && router.sidebarOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { router.sidebarOpen = false } }
                    SidebarView()
                        .frame(width: min(330, geo.size.width * 0.86))
                        .background(Color(uiColor: .systemBackground))
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
        .sheet(item: $router.sheet) { sheet in sheetView(sheet) }
        .sheet(item: $console.preview) { item in PreviewSheet(item: item) }
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
        .confirmationDialog("Save changes to \(editor.doc(editor.closeRequest?.doc)?.name ?? "this file")?",
                            isPresented: Binding(get: { editor.closeRequest != nil }, set: { if !$0 { editor.closeRequest = nil } }),
                            titleVisibility: .visible) {
            Button("Save") { if let r = editor.closeRequest { editor.finishClose(r, save: true) } }
            Button("Don't Save", role: .destructive) { if let r = editor.closeRequest { editor.finishClose(r, save: false) } }
            Button("Cancel", role: .cancel) { editor.closeRequest = nil }
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
            case .importFiles(let dir):
                DocumentPicker(types: [.item], allowsMultiple: true, asCopy: true) { urls in
                    let copied = workspace.importFiles(urls, into: dir)
                    if copied.count == 1, let u = copied.first { editor.open(u) }
                    router.flash("Imported \(copied.count) file\(copied.count == 1 ? "" : "s")")
                }.ignoresSafeArea()
            case .openFile:
                DocumentPicker(types: [.item], allowsMultiple: true, asCopy: false) { urls in
                    let archives = urls.filter { ArchiveService.isArchive($0) }
                    if !archives.isEmpty { router.importAndExtract(archives) }
                    for u in urls where !ArchiveService.isArchive(u) { editor.openExternal(u) }
                }.ignoresSafeArea()
            case .linkFolder:
                DocumentPicker(types: [.folder], allowsMultiple: false, asCopy: false) { urls in
                    if let u = urls.first { workspace.linkFolder(u); router.flash("Linked \(u.lastPathComponent)") }
                }.ignoresSafeArea()
            case .importArchive:
                DocumentPicker(types: [.zip, UTType("com.rarlab.rar-archive") ?? .data, .archive], allowsMultiple: true, asCopy: true) { urls in
                    router.importAndExtract(urls)
                }.ignoresSafeArea()
            case .installExtensionFile:
                DocumentPicker(types: [.json, .item], allowsMultiple: false, asCopy: true) { urls in
                    guard let u = urls.first, let data = try? Data(contentsOf: u) else { return }
                    do { let m = try extensions.install(data: data); router.flash("Installed \(m.name)") }
                    catch { router.fail(error) }
                }.ignoresSafeArea()
            }
        }
        .environmentObject(settings)
        .environmentObject(workspace)
        .environmentObject(editor)
        .environmentObject(extensions)
        .environmentObject(console)
        .environmentObject(router)
        .preferredColorScheme(settings.colorSchemeOverride)
        .tint(settings.accentColor)
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

// MARK: - Top bar

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
            barButton("terminal") { console.isVisible.toggle() }
            moreMenu
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(.bar)
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
            }
            Section {
                Button { if editor.saveActive() { settings.haptic(); router.flash("Saved") } } label: { Label("Save", systemImage: "square.and.arrow.down.on.square") }
                    .disabled(editor.activeDocument == nil)
                Button { editor.saveAll(); router.flash("Saved all") } label: { Label("Save All", systemImage: "square.stack.3d.down.forward") }
            }
            if editor.activeDocument != nil {
                Section {
                    Button { editor.showFind(replace: false) } label: { Label("Find", systemImage: "magnifyingglass") }
                    Button { editor.showFind(replace: true) } label: { Label("Find & Replace", systemImage: "arrow.left.arrow.right") }
                    Button { router.goToLineText = ""; router.showGoToLine = true } label: { Label("Go to Line…", systemImage: "arrow.down.to.line") }
                    Button { router.show(.snippets) } label: { Label("Insert Snippet…", systemImage: "text.badge.plus") }
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
        if let d = editor.activeDocument, workspace.isInside(d.url, workspace.root) || workspace.linkedFolders.contains(where: { workspace.isInside(d.url, $0.url) }) {
            return d.url.deletingLastPathComponent()
        }
        return workspace.scratchFolder
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
                Text("Ln \(editor.cursorLine), Col \(editor.cursorColumn)")
                Text(settings.insertSpaces ? "Spaces: \(settings.tabWidth)" : "Tabs")
                Menu(extensions.language(for: doc.url).name) {
                    Text("Language is picked from the file extension")
                }
            } else {
                Text("No file open")
                Spacer()
            }
            Text("v\(Bundle.main.appVersion)")
                .foregroundStyle(.tertiary)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
    }
}

extension Bundle {
    var appVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    var appBuild: String { infoDictionary?["CFBundleVersion"] as? String ?? "?" }
}

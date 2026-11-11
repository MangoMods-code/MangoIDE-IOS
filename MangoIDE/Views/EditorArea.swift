import SwiftUI

struct EditorArea: View {
    let size: CGSize
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var settings: AppSettings

    private var sideBySide: Bool {
        switch settings.splitOrientation {
        case "horizontal": return true
        case "vertical": return false
        default: return size.width >= 600 || size.width > size.height
        }
    }

    var body: some View {
        Group {
            if editor.panes.count > 1 {
                if sideBySide {
                    HStack(spacing: 0) {
                        PaneView(index: 0)
                        Rectangle().fill(Color(uiColor: .separator)).frame(width: 1)
                        PaneView(index: 1)
                    }
                } else {
                    VStack(spacing: 0) {
                        PaneView(index: 0)
                        Rectangle().fill(Color(uiColor: .separator)).frame(height: 1)
                        PaneView(index: 1)
                    }
                }
            } else {
                PaneView(index: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PaneView: View {
    let index: Int
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var extensions: ExtensionManager

    var body: some View {
        if editor.panes.indices.contains(index) {
            let pane = editor.panes[index]
            VStack(spacing: 0) {
                if !pane.tabs.isEmpty { TabBar(index: index) }
                if let doc = editor.doc(pane.active) {
                    DocumentContent(doc: doc, paneID: pane.id, index: index)
                } else if editor.isSplit {
                    EmptyPane(index: index)
                } else if let project = editor.lastProject, FileManager.default.fileExists(atPath: project.path) {
                    ProjectHomeView(project: project)
                } else {
                    WelcomeView()
                }
            }
            .overlay(alignment: .top) {
                if editor.isSplit && editor.focusedPane == index {
                    Rectangle().fill(Color.accentColor).frame(height: 2).transition(.opacity)
                }
            }
            .animation(Anim.quick, value: editor.focusedPane)
        } else {
            Color.clear
        }
    }
}

struct DocumentContent: View {
    @ObservedObject var doc: EditorDocument
    let paneID: UUID
    let index: Int
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var extensions: ExtensionManager

    var body: some View {
        if let err = doc.loadError {
            message("exclamationmark.triangle", "Couldn't open \(doc.name)", err)
        } else if doc.isBinary {
            FileViewer(url: doc.url, kind: doc.viewer ?? .hex)
                .id(doc.url)
        } else {
            VStack(spacing: 0) {
                if let e = doc.saveError {
                    Text(e).font(.caption).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(6).background(Color.red)
                }
                CodeEditorView(document: doc, contentVersion: doc.contentVersion, paneID: paneID,
                               theme: extensions.theme(id: settings.effectiveThemeID),
                               language: extensions.language(for: doc.url),
                               config: settings.editorConfig,
                               transparency: settings.backgroundActive ? CGFloat(settings.backgroundStrength) : 0,
                               editor: editor,
                               onFocus: { [weak ed = editor, index] in
                                   guard let ed, ed.focusedPane != index else { return }
                                   DispatchQueue.main.async { ed.focusedPane = index }
                               })
                .id(doc.id)
            }
        }
    }

    private func message(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyPane: View {
    let index: Int
    @EnvironmentObject var editor: EditorState
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Open a file from the sidebar to show it here.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Close This Side") { editor.closePane(index) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { editor.focusedPane = index }
    }
}

// MARK: - Tabs

struct TabBar: View {
    let index: Int
    @Namespace private var pill
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: Router
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        if editor.panes.indices.contains(index) { bar(editor.panes[index]) }
    }

    private func bar(_ pane: PaneState) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(pane.tabs, id: \.self) { id in
                        if let doc = editor.doc(id) {
                            TabItem(doc: doc, active: id == pane.active, focused: editor.focusedPane == index,
                                    compact: settings.compactTabs, showClose: settings.showTabCloseButtons, pill: pill,
                                    onSelect: { withAnimation(Anim.snappy) { editor.activate(id, pane: index) } },
                                    onClose: { editor.requestClose(id, pane: index) })
                                .id(id)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                                .contextMenu { menu(id, doc) }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .animation(Anim.snappy, value: pane.tabs)
            }
            .onChange(of: pane.active) { a in
                if let a { withAnimation(Anim.snappy) { proxy.scrollTo(a, anchor: .center) } }
            }
        }
        .frame(height: settings.compactTabs ? 32 : 38)
        .chromeBackground()
        .overlay(alignment: .bottom) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5) }
    }

    @ViewBuilder
    private func menu(_ id: UUID, _ doc: EditorDocument) -> some View {
        Button { editor.requestClose(id, pane: index) } label: { Label("Close", systemImage: "xmark") }
        Button { editor.closeOthers(keep: id, pane: index) } label: { Label("Close Others", systemImage: "xmark.square") }
        Button { editor.closeAll(pane: index) } label: { Label("Close All", systemImage: "xmark.rectangle") }
        Divider()
        if editor.isSplit {
            Button { editor.moveTab(id, from: index) } label: { Label("Move to Other Side", systemImage: "arrow.left.arrow.right") }
        }
        Button { editor.activate(id, pane: index); editor.openToSide(id) } label: { Label("Open to the Side", systemImage: "rectangle.split.2x1") }
        Divider()
        Button { doc.save(); router.flash("Saved") } label: { Label("Save", systemImage: "square.and.arrow.down") }
        Button { doc.load() } label: { Label("Reload from Disk", systemImage: "arrow.clockwise") }
        Button { router.beginRename(doc.url) } label: { Label("Rename", systemImage: "pencil") }
        ShareLink(item: doc.url) { Label("Share", systemImage: "square.and.arrow.up") }
        Button {
            UIPasteboard.general.string = workspace.displayPath(doc.url)
            router.flash("Path copied")
        } label: { Label("Copy Path", systemImage: "doc.on.clipboard") }
    }
}

struct TabItem: View {
    @ObservedObject var doc: EditorDocument
    let active: Bool
    let focused: Bool
    let compact: Bool
    let showClose: Bool
    let pill: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            let icon = FileIcons.icon(for: doc.url, isDirectory: false, open: false)
            Image(systemName: icon.0).font(.system(size: 11)).foregroundStyle(icon.1)
            Text(doc.name)
                .font(.system(size: compact ? 12 : 13, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(active ? Color.primary : Color.secondary)
            ZStack {
                if doc.isDirty {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                        .opacity(showClose && active ? 0 : 1)
                }
                if showClose && (active || !doc.isDirty) {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(active ? 0.08 : 0), in: Circle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.8))
                }
            }
            .frame(width: 18)
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .background {
            if active {
                // The highlight slides from tab to tab.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(focused ? 0.1 : 0.06))
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Color.accentColor.opacity(focused ? 1 : 0.5)).frame(height: 2).padding(.horizontal, 12)
                    }
                    .padding(.horizontal, 2).padding(.vertical, 4)
                    .matchedGeometryEffect(id: "active", in: pill)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var router: Router

    @State private var projects: [FileItem] = []

    private func loadProjects() {
        let ws = workspace
        DispatchQueue.global(qos: .userInitiated).async {
            let list: [FileItem] = ws.projectsRoot != nil
                ? Array(ws.projects().prefix(8))
                : Array(ws.children(of: ws.projectsFolder).filter { $0.isDirectory }.prefix(8))
            DispatchQueue.main.async { projects = list }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 16) {
                    GlowTile(symbol: "chevron.left.forwardslash.chevron.right")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MangoIDE").font(.largeTitle.bold())
                        Text("Version \(Bundle.main.appVersion) (\(Bundle.main.appBuild))").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .appearRise(0)

                group("Start", 1) {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ActionTile(symbol: "doc.badge.plus", title: "New File", color: .blue) { router.show(.newFile(workspace.scratchFolder)) }
                        ActionTile(symbol: "shippingbox.fill", title: "New Project", color: .orange) { router.show(.newProject) }
                        ActionTile(symbol: "square.grid.2x2.fill", title: "Templates", color: .pink) { router.show(.templates) }
                        ActionTile(symbol: "doc.fill", title: "Open File…", color: .teal) { router.show(.openFile) }
                        ActionTile(symbol: "folder.fill", title: "Open Folder…", color: .indigo) { router.show(.linkFolder) }
                        ActionTile(symbol: "arrow.triangle.branch", title: "Clone from GitHub…", color: .black) { router.show(.github) }
                        ActionTile(symbol: "person.2.fill", title: "Join a Live Session…", color: .mint) { router.show(.collab) }
                        ActionTile(symbol: "square.and.arrow.down.fill", title: "Import Files…", color: .green) { router.show(.importFiles(nil)) }
                        ActionTile(symbol: "doc.zipper", title: "Import ZIP / RAR…", color: .brown) { router.show(.importArchive) }
                        ActionTile(symbol: "folder.badge.gearshape", title: workspace.projectsRoot == nil ? "Choose Projects Folder…" : "Switch Project…", color: .purple) {
                            router.show(workspace.projectsRoot == nil ? .pickProjectsFolder : .projects)
                        }
                    }
                }

                if !projects.isEmpty {
                    group("Projects", 2) {
                        VStack(spacing: 0) {
                            ForEach(Array(projects.prefix(8).enumerated()), id: \.element.id) { i, p in
                                Button { openProject(p.url) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
                                        Text(p.name).foregroundStyle(.primary).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PressableStyle(scale: 0.98))
                                if i < min(projects.count, 8) - 1 { Divider().padding(.leading, 44) }
                            }
                        }
                        .surfaceCard()
                    }
                }

                group("Customize", 3) {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ActionTile(symbol: "gearshape.fill", title: "Settings", color: .gray) { router.show(.settings) }
                        ActionTile(symbol: "puzzlepiece.extension.fill", title: "Extensions", color: .pink) { router.show(.extensions) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: loadProjects)
        .onChange(of: workspace.revision) { _ in loadProjects() }
    }

    private func group<Content: View>(_ title: String, _ index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            content()
        }
        .appearRise(index)
    }

    private func openProject(_ dir: URL) {
        if workspace.projectsRoot != nil && workspace.isInside(dir, workspace.projectsRoot!) {
            workspace.openProject(dir)
        }
        let files = workspace.children(of: dir).filter { !$0.isDirectory }
        let main = files.first { $0.name.hasPrefix("main.") } ?? files.first { $0.name != "README.md" } ?? files.first
        if let main { editor.open(main.url) }
        router.sidebarOpen = true
    }
}


/// Shown when a project's last tab is closed: stay in the project instead of the start screen.
struct ProjectHomeView: View {
    let project: URL
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var router: Router
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 14) {
            GlowTile(symbol: "shippingbox.fill", size: 72, colors: [Color.accentColor, Color.accentColor.opacity(0.7)])
                .padding(.bottom, 6)
            Text(project.lastPathComponent).font(.title2.bold()).multilineTextAlignment(.center)
            Text("Pick a file in the explorer to keep working.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { router.sidebarOpen = true } label: { Label("Explorer", systemImage: "sidebar.left") }
                    .buttonStyle(.borderedProminent)
                Button { router.show(.newFile(project)) } label: { Label("New File", systemImage: "doc.badge.plus") }
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 12) {
                Button { router.show(.github) } label: { Label("GitHub", systemImage: "arrow.triangle.branch") }
                    .buttonStyle(.bordered)
                Button { router.show(.collab) } label: { Label("Collaborate", systemImage: "person.2") }
                    .buttonStyle(.bordered)
            }
            Button("Leave Project") {
                editor.lastProject = nil
                if workspace.activeProject == project { workspace.openProject(nil) }
            }
            .font(.footnote)
            .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

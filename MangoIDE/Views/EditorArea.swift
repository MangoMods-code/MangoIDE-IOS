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
                } else {
                    WelcomeView()
                }
            }
            .overlay(alignment: .top) {
                if editor.isSplit && editor.focusedPane == index {
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                }
            }
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
            message("doc.zipper", "\(doc.name) isn't a text file", "MangoIDE can only edit text. You can still share, rename or delete it from the sidebar.")
        } else {
            VStack(spacing: 0) {
                if let e = doc.saveError {
                    Text(e).font(.caption).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(6).background(Color.red)
                }
                CodeEditorView(document: doc, paneID: paneID,
                               theme: extensions.theme(id: settings.themeID),
                               language: extensions.language(for: doc.url),
                               config: settings.editorConfig,
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
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: Router
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        let pane = editor.panes[index]
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(pane.tabs, id: \.self) { id in
                        if let doc = editor.doc(id) {
                            TabItem(doc: doc, active: id == pane.active, focused: editor.focusedPane == index,
                                    compact: settings.compactTabs, showClose: settings.showTabCloseButtons,
                                    onSelect: { editor.activate(id, pane: index) },
                                    onClose: { editor.requestClose(id, pane: index) })
                                .id(id)
                                .contextMenu { menu(id, doc) }
                        }
                    }
                }
            }
            .onChange(of: pane.active) { a in
                if let a { withAnimation { proxy.scrollTo(a, anchor: .center) } }
            }
        }
        .frame(height: settings.compactTabs ? 32 : 38)
        .background(.bar)
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
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 18)
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .background(active ? Color(uiColor: .systemBackground).opacity(focused ? 1 : 0.6) : Color.clear)
        .overlay(alignment: .top) {
            if active { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var router: Router

    private var projects: [FileItem] {
        workspace.children(of: workspace.projectsFolder).filter { $0.isDirectory }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MangoIDE").font(.largeTitle.bold())
                    Text("Version \(Bundle.main.appVersion) (\(Bundle.main.appBuild))").font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Start").font(.headline)
                    action("doc.badge.plus", "New File") { router.show(.newFile(workspace.scratchFolder)) }
                    action("shippingbox", "New Project") { router.show(.newProject) }
                    action("doc", "Open File…") { router.show(.openFile) }
                    action("folder", "Open Folder…") { router.show(.linkFolder) }
                    action("square.and.arrow.down", "Import Files…") { router.show(.importFiles(nil)) }
                }
                if !projects.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Projects").font(.headline)
                        ForEach(projects.prefix(8)) { p in
                            action("shippingbox.fill", p.name) { openProject(p.url) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Customize").font(.headline)
                    action("gearshape", "Settings") { router.show(.settings) }
                    action("puzzlepiece.extension", "Extensions") { router.show(.extensions) }
                }
            }
            .padding(28)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .id(workspace.revision)
    }

    private func openProject(_ dir: URL) {
        let files = workspace.children(of: dir).filter { !$0.isDirectory }
        let main = files.first { $0.name.hasPrefix("main.") } ?? files.first { $0.name != "README.md" } ?? files.first
        if let main { editor.open(main.url) }
        router.sidebarOpen = true
    }

    private func action(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).font(.body)
        }
    }
}

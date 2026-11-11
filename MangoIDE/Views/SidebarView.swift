import SwiftUI

struct TreeRow: Identifiable, Hashable {
    let item: FileItem
    let depth: Int
    var id: URL { item.url }
}

final class SidebarModel: ObservableObject {
    @Published var expanded: Set<String> {
        didSet { UserDefaults.standard.set(Array(expanded), forKey: "ws.expanded") }
    }
    @Published private(set) var rows: [String: [TreeRow]] = [:]
    @Published var query = ""
    @Published private(set) var results: [FileItem] = []
    @Published private(set) var projects: [FileItem] = []

    init() {
        expanded = Set(UserDefaults.standard.stringArray(forKey: "ws.expanded") ?? ["Projects", "Scratchpad"].map {
            Workspace.shared.root.appendingPathComponent($0).path
        })
    }

    private var rebuildGeneration = 0
    private static let listQueue = DispatchQueue(label: "mango.sidebar", qos: .userInitiated)

    /// Lists folders in the background and swaps the result in, so big or slow (iCloud) folders never freeze the UI.
    func rebuild(_ workspace: Workspace) {
        rebuildGeneration += 1
        let gen = rebuildGeneration
        var roots = [workspace.root]
        roots += workspace.linkedFolders.map { $0.url }
        if let ap = workspace.activeProject { roots.append(ap) }
        let open = expanded
        SidebarModel.listQueue.async { [weak self] in
            var out: [String: [TreeRow]] = [:]
            for root in roots {
                var list: [TreeRow] = []
                SidebarModel.flatten(root, depth: 0, expanded: open, into: &list, workspace)
                out[root.path] = list
            }
            let projects = workspace.projects()
            DispatchQueue.main.async {
                guard let self, self.rebuildGeneration == gen else { return }
                self.rows = out
                self.projects = projects
            }
        }
        if !query.isEmpty { search(workspace) }
    }

    private static func flatten(_ dir: URL, depth: Int, expanded: Set<String>, into list: inout [TreeRow], _ workspace: Workspace) {
        for child in workspace.children(of: dir) {
            list.append(TreeRow(item: child, depth: depth))
            if list.count > 5000 { return }
            if child.isDirectory && expanded.contains(child.url.path) && depth < 14 {
                flatten(child.url, depth: depth + 1, expanded: expanded, into: &list, workspace)
            }
        }
    }

    func toggle(_ url: URL, _ workspace: Workspace) {
        if expanded.contains(url.path) { expanded.remove(url.path) } else { expanded.insert(url.path) }
        rebuild(workspace)
    }

    func reveal(_ url: URL, _ workspace: Workspace) {
        let roots = ([workspace.root] + workspace.linkedFolders.map { $0.url } + [workspace.activeProject].compactMap { $0 })
            .map { $0.standardizedFileURL.path }
        guard let owner = roots.filter({ workspace.isInside(url, URL(fileURLWithPath: $0)) }).max(by: { $0.count < $1.count }) else {
            rebuild(workspace); return
        }
        var dir = url.deletingLastPathComponent().standardizedFileURL
        while dir.path.count > owner.count && dir.path.hasPrefix(owner) {
            expanded.insert(dir.path)
            dir = dir.deletingLastPathComponent()
        }
        rebuild(workspace)
    }

    func collapseAll(_ workspace: Workspace) {
        expanded = []
        rebuild(workspace)
    }

    private var searchGeneration = 0
    static let heavyFolders: Set<String> = ["node_modules", ".git", "build", "DerivedData", "Pods", ".build", "dist", "target", "__pycache__", ".gradle", "vendor", ".venv", "venv"]

    /// Searches file names in the background so huge folders never freeze typing.
    func search(_ workspace: Workspace) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        searchGeneration += 1
        let gen = searchGeneration
        guard !q.isEmpty else { results = []; return }
        let roots = [workspace.root] + workspace.linkedFolders.map { $0.url } + [workspace.projectsRoot].compactMap { $0 }
        let hidden = AppSettings.shared.showHiddenFiles
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [FileItem] = []
            outer: for root in roots {
                guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: hidden ? [] : [.skipsHiddenFiles]) else { continue }
                for case let u as URL in en {
                    if self?.searchGeneration != gen { return }
                    let name = u.lastPathComponent
                    let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir && SidebarModel.heavyFolders.contains(name) { en.skipDescendants() }
                    if name.lowercased().contains(q) {
                        found.append(FileItem(url: u, isDirectory: isDir, modified: nil, size: 0))
                        if found.count >= 300 { break outer }
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.searchGeneration == gen else { return }
                self.results = found
            }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: Router
    @StateObject private var model = SidebarModel()
    @Environment(\.chrome) private var chrome

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            List {
                if !model.query.isEmpty {
                    Section("Results") {
                        if model.results.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                        ForEach(model.results) { item in
                            fileRow(TreeRow(item: item, depth: 0), showPath: true)
                        }
                    }
                } else {
                    Section {
                        quickFolders
                    }
                    projectsSection
                    Section {
                        ForEach(model.rows[workspace.root.path] ?? []) { row in fileRow(row) }
                    } header: {
                        rootHeader(title: "MangoIDE", url: workspace.root, linked: nil)
                    }
                    ForEach(workspace.linkedFolders) { folder in
                        Section {
                            ForEach(model.rows[folder.url.path] ?? []) { row in fileRow(row) }
                        } header: {
                            rootHeader(title: folder.name, url: folder.url, linked: folder)
                        }
                    }
                    if !workspace.recents.isEmpty {
                        Section {
                            ForEach(workspace.recents) { r in
                                Button { open(r.url) } label: {
                                    Label(r.url.lastPathComponent, systemImage: "clock")
                                        .lineLimit(1)
                                }
                                .foregroundStyle(.primary)
                            }
                        } header: {
                            HStack {
                                Text("Recent Outside Files")
                                Spacer()
                                Button("Clear") { workspace.clearRecents() }.font(.caption)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(chrome.background == nil && !chrome.translucent ? .automatic : .hidden)
            .environment(\.defaultMinListRowHeight, 30)
        }
        .chromeBackground()
        .onAppear { model.rebuild(workspace) }
        .onChange(of: workspace.revision) { _ in model.rebuild(workspace) }
        .onChange(of: workspace.linkedFolders) { _ in model.rebuild(workspace) }
        .onChange(of: workspace.activeProject) { _ in model.rebuild(workspace) }
        .onChange(of: workspace.projectsRoot) { _ in model.rebuild(workspace) }
        .onChange(of: settings.sortMode) { _ in model.rebuild(workspace) }
        .onChange(of: settings.foldersFirst) { _ in model.rebuild(workspace) }
        .onChange(of: settings.showHiddenFiles) { _ in model.rebuild(workspace) }
        .onChange(of: model.query) { _ in model.search(workspace) }
        .onChange(of: router.revealRequest) { u in
            if let u { model.reveal(u, workspace); router.revealRequest = nil }
        }
    }

    @ViewBuilder
    private var projectsSection: some View {
        if let root = workspace.projectsRoot {
            Section {
                if let ap = workspace.activeProject {
                    ForEach(model.rows[ap.path] ?? []) { row in fileRow(row) }
                    if (model.rows[ap.path] ?? []).isEmpty {
                        Text("This project is empty.").foregroundStyle(.secondary).font(.subheadline)
                    }
                } else {
                    if model.projects.isEmpty {
                        Text("No project folders in \(root.lastPathComponent) yet.").foregroundStyle(.secondary).font(.subheadline)
                    }
                    ForEach(model.projects.prefix(30)) { p in
                        Button { workspace.openProject(p.url) } label: {
                            Label(p.name, systemImage: "shippingbox.fill").lineLimit(1)
                        }
                        .foregroundStyle(.primary)
                        .listRowSeparator(.hidden)
                    }
                    if model.projects.count > 30 {
                        Button("Show all \(model.projects.count) projects…") { router.show(.projects) }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    if workspace.activeProject != nil {
                        Button { workspace.openProject(nil) } label: { Image(systemName: "chevron.left") }
                    }
                    Image(systemName: workspace.activeProject == nil ? "square.grid.2x2" : "shippingbox.fill")
                    Text(workspace.activeProject?.lastPathComponent ?? root.lastPathComponent).lineLimit(1)
                    Spacer()
                    Menu {
                        Button { router.show(.projects) } label: { Label("Switch Project…", systemImage: "square.grid.2x2") }
                        if let ap = workspace.activeProject {
                            Button { router.show(.newFile(ap)) } label: { Label("New File", systemImage: "doc.badge.plus") }
                            Button { router.show(.newFolder(ap)) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                            Button { workspace.openProject(nil) } label: { Label("Close Project", systemImage: "xmark") }
                        }
                        Button { router.show(.newProject) } label: { Label("New Project", systemImage: "plus") }
                        Divider()
                        Button { router.show(.pickProjectsFolder) } label: { Label("Change Projects Folder…", systemImage: "folder") }
                        Button { workspace.useBuiltInProjectsFolder() } label: { Label("Use MangoIDE › Projects", systemImage: "iphone") }
                        Button(role: .destructive) { workspace.clearProjectsRoot() } label: { Label("Remove Projects Folder", systemImage: "minus.circle") }
                    } label: { Image(systemName: "ellipsis.circle").padding(.horizontal, 4) }
                }
                .font(.caption.weight(.semibold))
            }
        } else {
            Section {
                Menu {
                    Button { router.show(.pickProjectsFolder) } label: { Label("Pick a Folder from Files…", systemImage: "folder") }
                    Button { workspace.useBuiltInProjectsFolder() } label: { Label("Use MangoIDE › Projects", systemImage: "iphone") }
                } label: {
                    Label("Choose Your Projects Folder…", systemImage: "square.grid.2x2")
                        .font(.subheadline)
                }
                .listRowSeparator(.hidden)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text("Explorer").font(.headline)
            Spacer()
            iconButton("doc.badge.plus") { router.show(.newFile(workspace.scratchFolder)) }
            iconButton("folder.badge.plus") { router.show(.newFolder(workspace.root)) }
            iconButton("shippingbox") { router.show(.newProject) }
            Menu {
                Button { router.show(.openFile) } label: { Label("Open File…", systemImage: "doc") }
                Button { router.show(.linkFolder) } label: { Label("Open Folder…", systemImage: "folder") }
                Button { router.show(.importFiles(nil)) } label: { Label("Import Files…", systemImage: "square.and.arrow.down") }
                Button { router.show(.importArchive) } label: { Label("Import ZIP / RAR…", systemImage: "doc.zipper") }
                Divider()
                Picker("Sort by", selection: $settings.sortMode) {
                    Text("Name").tag("name"); Text("Date").tag("date"); Text("Kind").tag("kind"); Text("Size").tag("size")
                }
                Toggle("Folders First", isOn: $settings.foldersFirst)
                Toggle("Show Hidden Files", isOn: $settings.showHiddenFiles)
                Divider()
                Button { model.collapseAll(workspace) } label: { Label("Collapse All", systemImage: "rectangle.compress.vertical") }
                Button { workspace.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 34, height: 34)
            }
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search files", text: $model.query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var quickFolders: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Workspace.builtInFolders, id: \.self) { name in
                    let url = workspace.root.appendingPathComponent(name)
                    Button {
                        model.reveal(url.appendingPathComponent("x"), workspace)
                    } label: {
                        Label(name, systemImage: FileIcons.folderSymbol(name))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.94))
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
        .listRowSeparator(.hidden)
    }

    private func rootHeader(title: String, url: URL, linked: LinkedFolder?) -> some View {
        HStack {
            Image(systemName: linked == nil ? "iphone" : "link")
            Text(title).lineLimit(1)
            Spacer()
            Menu {
                Button { router.show(.newFile(url)) } label: { Label("New File", systemImage: "doc.badge.plus") }
                Button { router.show(.newFolder(url)) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Button { router.show(.importFiles(url)) } label: { Label("Import Files Here…", systemImage: "square.and.arrow.down") }
                if let linked {
                    Divider()
                    Button(role: .destructive) { workspace.unlink(linked) } label: { Label("Remove from Sidebar", systemImage: "link.badge.plus") }
                }
            } label: { Image(systemName: "plus.circle").padding(.horizontal, 4) }
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private func fileRow(_ row: TreeRow, showPath: Bool = false) -> some View {
        let item = row.item
        let isOpen = editor.activeDocument?.url.standardizedFileURL == item.url.standardizedFileURL
        let isExpanded = model.expanded.contains(item.url.path)
        Button {
            if item.isDirectory { model.toggle(item.url, workspace) }
            else if ArchiveService.isArchive(item.url) { router.extractConfirm = item.url }
            else { open(item.url) }
        } label: {
            HStack(spacing: 6) {
                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(Anim.quick, value: isExpanded)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }
                if settings.showFileIcons {
                    let icon = FileIcons.icon(for: item.url, isDirectory: item.isDirectory, open: isExpanded)
                    Image(systemName: icon.0).foregroundStyle(icon.1).frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if showPath {
                        Text(workspace.displayPath(item.url.deletingLastPathComponent()))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(row.depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 15))
        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 8))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isOpen ? 0.18 : 0))
                .padding(.horizontal, 6)
        )
        .listRowSeparator(.hidden)
        .contextMenu { contextMenu(for: item) }
    }

    @ViewBuilder
    private func contextMenu(for item: FileItem) -> some View {
        let builtIn = workspace.isBuiltInFolder(item.url)
        if item.isDirectory {
            Button { router.show(.newFile(item.url)) } label: { Label("New File Here", systemImage: "doc.badge.plus") }
            Button { router.show(.newFolder(item.url)) } label: { Label("New Folder Here", systemImage: "folder.badge.plus") }
            Button { router.show(.importFiles(item.url)) } label: { Label("Import Files Here…", systemImage: "square.and.arrow.down") }
        } else if ArchiveService.isArchive(item.url) {
            Button { router.extract(item.url) } label: { Label("Extract Here", systemImage: "arrow.up.bin") }
            Button { router.extract(item.url, into: workspace.importedFolder) } label: { Label("Extract to Imported", systemImage: "tray.and.arrow.down") }
        } else {
            Button { open(item.url) } label: { Label("Open", systemImage: "doc.text") }
            Button { editor.open(item.url); editor.openToSide(editor.activeDocument?.id); closeIfNarrow() } label: {
                Label("Open to the Side", systemImage: "rectangle.split.2x1")
            }
        }
        Divider()
        if !builtIn {
            Button { router.beginRename(item.url) } label: { Label("Rename", systemImage: "pencil") }
        }
        Button {
            do { _ = try workspace.duplicate(item.url) } catch { router.fail(error) }
        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button { router.compress([item.url]) } label: { Label("Compress to ZIP", systemImage: "archivebox") }
        if item.isDirectory {
            Button { router.packAssets(item.url) } label: { Label("Pack as .nullsbrawlassets", systemImage: "shippingbox.and.arrow.backward") }
            Menu {
                Button { router.exportMinecraft(item.url, open: true) } label: { Label("Export & Open in Minecraft", systemImage: "play.circle") }
                Button { router.exportMinecraft(item.url, open: false) } label: { Label("Export .mcpack / .mcaddon", systemImage: "shippingbox") }
            } label: { Label("Minecraft", systemImage: "cube") }
        } else if Minecraft.fileTypes.contains(item.url.pathExtension.lowercased()) {
            Button { Minecraft.share(item.url) } label: { Label("Open in Minecraft", systemImage: "play.circle") }
        }
        if !builtIn {
            Menu {
                ForEach(Workspace.builtInFolders, id: \.self) { name in
                    Button(name) { move(item.url, to: workspace.root.appendingPathComponent(name)) }
                }
                Button("MangoIDE (top level)") { move(item.url, to: workspace.root) }
            } label: { Label("Move To", systemImage: "folder") }
        }
        ShareLink(item: item.url) { Label("Share", systemImage: "square.and.arrow.up") }
        Button {
            UIPasteboard.general.string = workspace.displayPath(item.url)
            router.flash("Path copied")
        } label: { Label("Copy Path", systemImage: "doc.on.clipboard") }
        if !builtIn {
            Divider()
            Button(role: .destructive) {
                if settings.confirmDelete { router.deleteTarget = item.url }
                else {
                    editor.fileDeleted(item.url)
                    do { try workspace.delete(item.url) } catch { router.fail(error) }
                }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func move(_ url: URL, to dir: URL) {
        do {
            let new = try workspace.move(url, into: dir)
            editor.fileRenamed(from: url, to: new)
        } catch { router.fail(error) }
    }

    private func open(_ url: URL) {
        editor.open(url)
        closeIfNarrow()
    }

    private func closeIfNarrow() {
        if settings.closeSidebarOnOpen && UIScreen.main.bounds.width < 700 {
            withAnimation { router.sidebarOpen = false }
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 34, height: 34) }
    }
}

enum FileIcons {
    static func folderSymbol(_ name: String) -> String {
        switch name {
        case "Projects": return "shippingbox.fill"
        case "Scratchpad": return "note.text"
        case "Snippets": return "text.badge.star"
        case "Imported": return "tray.and.arrow.down.fill"
        case "Extensions": return "puzzlepiece.extension.fill"
        default: return "folder.fill"
        }
    }

    static func icon(for url: URL, isDirectory: Bool, open: Bool) -> (String, Color) {
        if isDirectory {
            let builtIn = Workspace.shared.isBuiltInFolder(url)
            return (builtIn ? folderSymbol(url.lastPathComponent) : (open ? "folder" : "folder.fill"), .accentColor)
        }
        switch url.pathExtension.lowercased() {
        case "swift": return ("swift", .orange)
        case "py", "pyw": return ("chevron.left.forwardslash.chevron.right", .blue)
        case "js", "mjs", "cjs", "jsx": return ("curlybraces", .yellow)
        case "ts", "tsx": return ("curlybraces", .blue)
        case "json": return ("curlybraces.square", .green)
        case "html", "htm": return ("globe", .orange)
        case "css", "scss", "less": return ("paintbrush", .purple)
        case "md", "markdown": return ("doc.richtext", .gray)
        case "txt": return ("doc.text", .gray)
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return ("photo", .pink)
        case "zip", "tar", "gz", "rar", "nullsbrawlassets": return ("doc.zipper", .brown)
        case "dylib", "o": return ("gearshape.2", .gray)
        case "plist", "entitlements", "mobileconfig": return ("list.bullet.rectangle", .teal)
        case "x", "xm", "xi", "xmi": return ("wrench.and.screwdriver", .orange)
        case "mcaddon", "mcpack", "mcworld", "mctemplate": return ("cube.fill", .green)
        case "mcfunction": return ("terminal", .green)
        case "sh", "bash", "zsh": return ("terminal", .green)
        case "c", "h", "cpp", "hpp", "cc", "cs", "java", "kt", "go", "rs", "rb", "php", "lua", "dart":
            return ("chevron.left.forwardslash.chevron.right", .teal)
        case "yml", "yaml", "toml", "ini", "plist", "xml": return ("gearshape", .gray)
        default: return ("doc", .secondary)
        }
    }
}

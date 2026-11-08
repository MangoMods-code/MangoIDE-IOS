import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - New file

struct NewFileSheet: View {
    @State var directory: URL
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var extensions: ExtensionManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var languageID = "auto"
    @State private var useTemplate = true
    @State private var error: String?
    @FocusState private var focused: Bool

    private var resolvedName: String {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = "untitled" }
        if (n as NSString).pathExtension.isEmpty {
            if languageID != "auto", let ext = extensions.language(id: languageID).extensions.first { n += "." + ext }
            else { n += "." + settings.defaultExtension }
        }
        return n
    }

    private var language: LanguageDef {
        languageID == "auto" ? extensions.language(for: URL(fileURLWithPath: resolvedName)) : extensions.language(id: languageID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("File name (e.g. main.py)", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit(create)
                    Picker("Language", selection: $languageID) {
                        Text("From extension").tag("auto")
                        ForEach(extensions.allLanguages.filter { $0.id != "plaintext" }) { l in Text(l.name).tag(l.id) }
                    }
                    if language.template != nil {
                        Toggle("Start with example code", isOn: $useTemplate)
                    }
                } footer: {
                    Text("Will be created as \(resolvedName) · \(language.name)")
                }
                Section("Location") {
                    FolderPicker(selection: $directory)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("New File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create", action: create).bold() }
            }
            .onAppear { focused = true }
        }
    }

    private func create() {
        do {
            let contents = useTemplate ? (language.template ?? "") : ""
            let url = try workspace.createFile(named: resolvedName, in: directory, contents: contents)
            editor.open(url)
            settings.haptic()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - New folder

struct NewFolderSheet: View {
    @State var directory: URL
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(create)
                Section("Inside") { FolderPicker(selection: $directory) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create", action: create).bold().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear { focused = true }
        }
    }

    private func create() {
        do { _ = try workspace.createFolder(named: name, in: directory); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - New project

struct NewProjectSheet: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var extensions: ExtensionManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var languageID = "python"
    @State private var error: String?
    @State private var inMyFolder = true

    private var languages: [LanguageDef] { extensions.allLanguages.filter { $0.template != nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name).autocorrectionDisabled()
                } footer: {
                    Text("Creates a \(name.isEmpty ? "new" : "\"\(name)\"") folder with a starter file\(settings.projectReadme ? ", README" : "")\(settings.projectGitignore ? " and .gitignore" : "").")
                }
                if let pr = workspace.projectsRoot {
                    Section("Location") {
                        Picker("Create In", selection: $inMyFolder) {
                            Text(pr.lastPathComponent).tag(true)
                            Text("MangoIDE › Projects").tag(false)
                        }
                    }
                }
                Section("Templates") {
                    Button { createMinecraft() } label: {
                        HStack {
                            Image(systemName: "cube.fill").foregroundStyle(.green).font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Minecraft Bedrock Add-on").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text("Behavior + resource pack with a custom item, texture and function").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("Language") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(languages) { l in
                            Button { languageID = l.id } label: {
                                VStack(spacing: 4) {
                                    Text(l.name).font(.subheadline.weight(.semibold))
                                    Text(runLabel(l)).font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(languageID == l.id ? Color.accentColor.opacity(0.2) : Color(uiColor: .tertiarySystemFill),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(languageID == l.id ? Color.accentColor : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create).bold().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func createMinecraft() {
        do {
            let useMine = inMyFolder && workspace.projectsRoot != nil
            let parent = useMine ? workspace.projectsRoot! : workspace.projectsFolder
            let n = name.trimmingCharacters(in: .whitespaces)
            let file = try Minecraft.createAddon(named: n, in: parent)
            if useMine { workspace.openProject(parent.appendingPathComponent(n)) }
            editor.open(file)
            settings.haptic()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func runLabel(_ l: LanguageDef) -> String {
        switch l.runner {
        case "js": return "Runs on device"
        case "html", "markdown": return "Live preview"
        case nil: return "Edit only"
        default: return "Runs via server"
        }
    }

    private func create() {
        do {
            let useMine = inMyFolder && workspace.projectsRoot != nil
            let main = try workspace.createProject(named: name, language: extensions.language(id: languageID),
                                                   in: useMine ? workspace.projectsRoot : workspace.projectsFolder)
            if useMine { workspace.openProject(main.deletingLastPathComponent()) }
            editor.open(main)
            settings.haptic()
            router.sidebarOpen = UIDevice.current.userInterfaceIdiom == .pad
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Folder chooser used by the sheets

struct FolderPicker: View {
    @Binding var selection: URL
    @EnvironmentObject var workspace: Workspace
    @State private var options: [URL] = []

    /// Built once in the background, skipping huge dependency folders, so big linked projects can't freeze the sheet.
    private func load() {
        let ws = workspace
        let current = selection
        let linked = workspace.linkedFolders.map { $0.url }
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [URL] = [ws.root]
            func walk(_ dir: URL, depth: Int, maxDepth: Int) {
                guard depth < maxDepth, out.count < 400 else { return }
                for c in ws.children(of: dir) where c.isDirectory && !SidebarModel.heavyFolders.contains(c.name) {
                    out.append(c.url)
                    walk(c.url, depth: depth + 1, maxDepth: maxDepth)
                }
            }
            walk(ws.root, depth: 0, maxDepth: 4)
            for l in linked {
                out.append(l)
                walk(l, depth: 0, maxDepth: 3)
            }
            if !out.contains(where: { $0.standardizedFileURL == current.standardizedFileURL }) { out.append(current) }
            DispatchQueue.main.async { options = out }
        }
    }

    var body: some View {
        Picker("Folder", selection: $selection) {
            ForEach(options.isEmpty ? [selection] : options, id: \.self) { u in
                Text(workspace.displayPath(u)).tag(u)
            }
        }
        .pickerStyle(.navigationLink)
        .onAppear { if options.isEmpty { load() } }
    }
}

// MARK: - Snippets

struct SnippetsSheet: View {
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var extensions: ExtensionManager
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) var dismiss
    @State private var savedFiles: [FileItem] = []

    var body: some View {
        NavigationStack {
            List {
                let lang = extensions.language(for: editor.activeDocument?.url)
                Section("\(lang.name) snippets") {
                    let list = extensions.snippets(for: lang)
                    if list.isEmpty { Text("No snippets for this language yet.").foregroundStyle(.secondary) }
                    ForEach(list) { s in
                        Button { insert(s.body) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.name).font(.headline)
                                Text(s.body == "DATE" ? "Current date and time" : s.body)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section {
                    if savedFiles.isEmpty { Text("Save files in the Snippets folder and they show up here.").foregroundStyle(.secondary) }
                    ForEach(savedFiles) { f in
                        Button(f.name) {
                            if let text = try? String(contentsOf: f.url, encoding: .utf8) { insert(text) }
                        }
                    }
                } header: { Text("From your Snippets folder") }
            }
            .navigationTitle("Insert Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { savedFiles = workspace.children(of: workspace.snippetsFolder).filter { !$0.isDirectory } }
        }
        .presentationDetents([.medium, .large])
    }

    private func insert(_ body: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editor.insertIntoActive(body) }
    }
}

// MARK: - Document picker (files and folders from the Files app)

struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let allowsMultiple: Bool
    let asCopy: Bool
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        vc.allowsMultipleSelection = allowsMultiple
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

// MARK: - HTML / Markdown preview

struct PreviewSheet: View {
    let item: PreviewItem
    @Environment(\.dismiss) var dismiss
    @State private var reloadToken = UUID()

    var body: some View {
        NavigationStack {
            WebView(item: item, reloadToken: reloadToken)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button { reloadToken = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
        }
    }
}

struct WebView: UIViewRepresentable {
    let item: PreviewItem
    let reloadToken: UUID

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: config)
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        load(wv)
        context.coordinator.token = reloadToken
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.token != reloadToken {
            context.coordinator.token = reloadToken
            load(wv)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var token: UUID? }

    private func load(_ wv: WKWebView) {
        if let url = item.fileURL {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if let html = item.html {
            wv.loadHTMLString(html, baseURL: nil)
        }
    }
}


// MARK: - Projects folder browser

struct ProjectsSheet: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var projects: [FileItem] = []
    @State private var sortByName = false

    private var shown: [FileItem] {
        let list = sortByName ? projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : projects
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if workspace.projectsRoot == nil {
                    Button("Choose Projects Folder…") { dismiss(); router.show(.pickProjectsFolder) }
                }
                ForEach(shown) { p in
                    Button { open(p.url) } label: {
                        HStack {
                            Image(systemName: "shippingbox.fill").foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(.primary)
                                if let d = p.modified {
                                    Text(d, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if workspace.activeProject?.standardizedFileURL == p.url.standardizedFileURL {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search projects")
            .navigationTitle(workspace.projectsRoot?.lastPathComponent ?? "Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: $sortByName) {
                            Text("Recently Changed").tag(false)
                            Text("Name").tag(true)
                        }
                        Button { dismiss(); router.show(.newProject) } label: { Label("New Project", systemImage: "plus") }
                        Button { dismiss(); router.show(.pickProjectsFolder) } label: { Label("Change Projects Folder…", systemImage: "folder") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .overlay {
                if projects.isEmpty && workspace.projectsRoot != nil {
                    Text("No project folders found.").foregroundStyle(.secondary)
                }
            }
            .onAppear {
                let ws = workspace
                DispatchQueue.global(qos: .userInitiated).async {
                    let list = ws.projects()
                    DispatchQueue.main.async { projects = list }
                }
            }
        }
    }

    private func open(_ url: URL) {
        workspace.openProject(url)
        // Open a likely entry file so there's something on screen.
        let files = workspace.children(of: url).filter { !$0.isDirectory }
        let preferred = ["README.md", "readme.md", "main.py", "main.js", "index.html", "main.swift", "index.js", "app.py"]
        if let f = preferred.compactMap({ name in files.first { $0.name == name } }).first {
            editor.open(f.url)
        }
        router.sidebarOpen = true
        dismiss()
    }
}

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

    private var languages: [LanguageDef] { extensions.allLanguages.filter { $0.template != nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name).autocorrectionDisabled()
                } footer: {
                    Text("Creates Projects/\(name.isEmpty ? "…" : name) with a starter file\(settings.projectReadme ? ", README" : "")\(settings.projectGitignore ? " and .gitignore" : "").")
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
            let main = try workspace.createProject(named: name, language: extensions.language(id: languageID))
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

    private var options: [URL] {
        var out: [URL] = [workspace.root]
        func walk(_ dir: URL, depth: Int) {
            guard depth < 4 else { return }
            for c in workspace.children(of: dir) where c.isDirectory {
                out.append(c.url)
                walk(c.url, depth: depth + 1)
            }
        }
        walk(workspace.root, depth: 0)
        for l in workspace.linkedFolders {
            out.append(l.url)
            walk(l.url, depth: 1)
        }
        if !out.contains(where: { $0.standardizedFileURL == selection.standardizedFileURL }) { out.append(selection) }
        return out
    }

    var body: some View {
        Picker("Folder", selection: $selection) {
            ForEach(options, id: \.self) { u in
                Text(workspace.displayPath(u)).tag(u)
            }
        }
        .pickerStyle(.navigationLink)
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

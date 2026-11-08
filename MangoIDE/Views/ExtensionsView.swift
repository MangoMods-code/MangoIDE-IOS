import SwiftUI

struct ExtensionsView: View {
    @EnvironmentObject var extensions: ExtensionManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss
    @State private var urlText = ""
    @State private var installing = false
    @State private var message: String?

    var body: some View {
        List {
            if !settings.extensionsEnabled {
                Section { Label("Extensions are turned off in Settings › General.", systemImage: "exclamationmark.triangle") }
            }
            Section {
                if extensions.installed.isEmpty {
                    Text("Nothing installed yet.").foregroundStyle(.secondary)
                }
                ForEach(extensions.installed) { ext in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(ext.manifest.name).font(.headline)
                            Text(ext.manifest.version).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("", isOn: Binding(get: { ext.enabled }, set: { extensions.setEnabled(ext, $0) }))
                                .labelsHidden()
                        }
                        if let d = ext.manifest.description { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                        Text(ext.manifest.summary + (ext.manifest.author.map { " · by \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { extensions.remove(ext) } label: { Label("Remove", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button { openManifest(ext) } label: { Label("Edit extension.json", systemImage: "pencil") }
                        Button(role: .destructive) { extensions.remove(ext) } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            } header: { Text("Installed") }

            Section {
                TextField("https://…/extension.json", text: $urlText)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    guard let u = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else { return }
                    installing = true
                    extensions.install(from: u) { result in
                        installing = false
                        switch result {
                        case .success(let m): message = "Installed \(m.name)"; urlText = ""
                        case .failure(let e): message = e.localizedDescription
                        }
                    }
                } label: {
                    HStack { Label("Install from Link", systemImage: "link"); if installing { Spacer(); ProgressView() } }
                }
                .disabled(urlText.isEmpty || installing)
                Button { router.show(.installExtensionFile) } label: { Label("Install from File…", systemImage: "doc") }
                Button { extensions.createSample(); message = "Added Sample Pack" } label: {
                    Label("Add Sample Extension", systemImage: "wand.and.stars")
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Get Extensions") } footer: {
                Text("An extension is one extension.json file that can add editor themes, language highlighting and snippets. It lives in the Extensions folder, so you can make your own right here in MangoIDE: add the sample, then long-press it and edit its file.")
            }

            Section("Make Your Own") {
                Text(ExtensionsView.formatHelp)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Extensions")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear { extensions.reload() }
    }

    private func openManifest(_ ext: InstalledExtension) {
        let file = ext.folder.pathExtension == "json" ? ext.folder : ext.folder.appendingPathComponent("extension.json")
        editor.open(file)
        router.sheet = nil
    }

    static let formatHelp = """
    {
      "id": "you.my-pack",
      "name": "My Pack",
      "version": "1.0.0",
      "themes": [ { "id": "...", "name": "...",
        "isDark": true, "background": "#1E1E1E",
        "foreground": "#DDDDDD", ... } ],
      "languages": [ { "id": "...", "name": "...",
        "extensions": ["ext"], "keywords": [...],
        "lineComment": "//", "runner": "python" } ],
      "snippets": [ { "name": "...",
        "language": "python", "body": "..." } ]
    }
    """
}

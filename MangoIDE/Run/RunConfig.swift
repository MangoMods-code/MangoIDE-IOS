import SwiftUI

/// How a project runs. Saved in the project as .mango/run.json, so it travels with the project.
struct RunConfig: Codable, Equatable {
    /// File to run, relative to the project ("src/main.py"). Empty = whatever file is open.
    var entry = ""
    /// Command-line arguments, separated by spaces ("quoted words" stay together).
    var args = ""
    /// Typed into the program when it starts.
    var input = ""
    /// Send the project's other files too, so imports between files work.
    var includeProjectFiles = true

    static func url(_ project: URL) -> URL { project.appendingPathComponent(".mango/run.json") }

    static func load(_ project: URL) -> RunConfig {
        guard let data = try? Data(contentsOf: url(project)), let c = try? JSONDecoder().decode(RunConfig.self, from: data) else { return RunConfig() }
        return c
    }

    func save(_ project: URL) {
        let u = RunConfig.url(project)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: u, options: .atomic)
    }

    var argList: [String] {
        var out: [String] = [], cur = "", quote: Character?
        var hasToken = false
        for ch in args {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; hasToken = true
            } else if ch == " " || ch == "\t" || ch == "\n" {
                if hasToken { out.append(cur); cur = ""; hasToken = false }
            } else {
                cur.append(ch); hasToken = true
            }
        }
        if hasToken { out.append(cur) }
        return out
    }
}

struct RunConfigSheet: View {
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var extensions: ExtensionManager
    @Environment(\.dismiss) private var dismiss
    @State private var config = RunConfig()
    @State private var runnable: [String] = []
    @State private var loaded = false

    private var project: URL? { currentProjectFolder(editor, workspace) }

    var body: some View {
        NavigationStack {
            Form {
                if let project {
                    Section {
                        Picker("Run", selection: $config.entry) {
                            Text("The open file").tag("")
                            ForEach(runnable, id: \.self) { Text($0).tag($0) }
                        }
                        Toggle("Include Other Project Files", isOn: $config.includeProjectFiles)
                    } header: { Text(project.lastPathComponent) } footer: {
                        Text("Pick the file ▶ runs in this project. Including the other files lets imports between files work (up to 300 text files).")
                    }
                    Section {
                        TextField("e.g. --verbose \"two words\"", text: $config.args)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.body.monospaced())
                    } header: { Text("Arguments") }
                    Section {
                        TextEditor(text: $config.input)
                            .font(.body.monospaced())
                            .frame(minHeight: 90)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Input When It Starts") } footer: {
                        Text("Typed into the program as soon as it starts, one value per line. You can also type into a running program in the console.")
                    }
                } else {
                    Section {
                        Text("Open a project to give it run settings. Single files run as they are.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Type Into Running Programs", isOn: $settings.interactiveRuns)
                    Toggle("Live HTML Preview", isOn: $settings.livePreview)
                } header: { Text("All Projects") } footer: {
                    Text("Typing into running programs needs an up-to-date runner server. Live preview reloads HTML pages as you type and when linked CSS or JavaScript files are saved.")
                }
            }
            .navigationTitle("Run Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { if let project { config.save(project) }; dismiss() }
                }
            }
            .task {
                guard !loaded, let project else { return }
                loaded = true
                config = RunConfig.load(project)
                let ext = extensions
                runnable = await Task.detached {
                    ProjectFiles.textFiles(in: project, limit: 2000).map(\.0).filter { ext.language(for: URL(fileURLWithPath: $0)).runner != nil }
                }.value
                if !config.entry.isEmpty && !runnable.contains(config.entry) { runnable.insert(config.entry, at: 0) }
            }
        }
    }
}

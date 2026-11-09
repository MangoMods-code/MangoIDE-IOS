import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var extensions: ExtensionManager
    @Environment(\.dismiss) var dismiss
    @State private var confirmReset = false
    @State private var search = ""

    /// Every settings page, so search can find them by name or by what's inside.
    private struct Page: Identifiable {
        let title: String
        let symbol: String
        let color: Color
        let keywords: String
        let destination: () -> AnyView
        var id: String { title }
    }

    private struct Group: Identifiable {
        let title: String
        let pages: [Page]
        var id: String { title }
    }

    private var groups: [Group] {
        [
            Group(title: "Pro & Purchases", pages: [
                Page(title: "MangoIDE Pro", symbol: "star.fill", color: .orange, keywords: "subscription upgrade billing stripe pay price plan manage cancel") { AnyView(ProView()) },
                Page(title: "AI Credit", symbol: "creditcard.fill", color: .green, keywords: "top up balance agent money stripe payment receipts refund") { AnyView(CreditView()) },
            ]),
            Group(title: "Cloud & Collaboration", pages: [
                Page(title: "Cloud Sync & Backup", symbol: "icloud.fill", color: .cyan, keywords: "sync backup restore devices storage") { AnyView(CloudView()) },
                Page(title: "GitHub", symbol: "arrow.triangle.branch", color: .black, keywords: "git clone push pull commit repo publish branch") { AnyView(GitHubSettings()) },
                Page(title: "Sharing & Live Sessions", symbol: "person.2.fill", color: .mint, keywords: "share link collaborate live session invite cursors together") { AnyView(SharingSettings()) },
            ]),
            Group(title: "Editing", pages: [
                Page(title: "Editor", symbol: "character.cursor.ibeam", color: .blue, keywords: "font size line numbers wrap indentation tabs spaces autosave save trim") { AnyView(EditorSettings()) },
                Page(title: "Keyboard", symbol: "keyboard", color: .gray, keywords: "brackets autocomplete key bar accessory smart") { AnyView(KeyboardSettings()) },
                Page(title: "Themes", symbol: "paintpalette.fill", color: .pink, keywords: "color dark light holiday accent appearance") { AnyView(AppearanceSettings()) },
                Page(title: "Backgrounds & Effects", symbol: "photo.fill", color: .purple, keywords: "wallpaper live photo gif video snow effects seasonal") { AnyView(BackgroundSettings()) },
                Page(title: "Layout", symbol: "rectangle.3.group", color: .indigo, keywords: "status bar tabs split sidebar console file icons") { AnyView(LayoutSettings()) },
            ]),
            Group(title: "Workspace", pages: [
                Page(title: "Files & Projects", symbol: "folder.fill", color: .orange, keywords: "projects folder new files templates") { AnyView(FileSettings()) },
                Page(title: "Run & Console", symbol: "play.rectangle.fill", color: .green, keywords: "runner server key languages execute console") { AnyView(RunSettings()) },
                Page(title: "Agent", symbol: "sparkles", color: .indigo, keywords: "ai claude anthropic key model memory approvals cloud workspace") { AnyView(AgentSettings()) },
                Page(title: "Extensions", symbol: "puzzlepiece.extension.fill", color: .purple, keywords: "install themes languages snippets") { AnyView(ExtensionsView()) },
            ]),
            Group(title: "App", pages: [
                Page(title: "General", symbol: "gearshape.fill", color: .gray, keywords: "haptics screen awake welcome") { AnyView(GeneralSettings()) },
                Page(title: "Privacy & Security", symbol: "lock.shield.fill", color: .blue, keywords: "keychain keys sign out devices sessions password") { AnyView(PrivacySettings()) },
                Page(title: "Storage", symbol: "internaldrive.fill", color: .gray, keywords: "space clear cache drafts temporary size") { AnyView(StorageSettings()) },
            ]),
        ]
    }

    private var results: [Page] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return groups.flatMap(\.pages).filter { ($0.title + " " + $0.keywords).lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    Section {
                        NavigationLink { AccountView() } label: { AccountRow() }
                    }
                    ForEach(groups) { g in
                        Section(g.title) {
                            ForEach(g.pages) { page in
                                NavigationLink { page.destination() } label: { row(page.title, page.symbol, page.color) }
                            }
                        }
                    }
                    Section("About") {
                        LabeledContent("Version", value: Bundle.main.appVersion)
                        LabeledContent("Build", value: Bundle.main.appBuild)
                        LabeledContent("Languages", value: "\(extensions.allLanguages.count)")
                        LabeledContent("Themes", value: "\(extensions.allThemes.count)")
                        NavigationLink { DiagnosticsView() } label: { Label("File Access Diagnostics", systemImage: "stethoscope") }
                    }
                    Section {
                        Button("Reset All Settings", role: .destructive) { confirmReset = true }
                    } footer: {
                        Text("Your files, account, linked folders and extensions are kept.")
                    }
                } else {
                    if results.isEmpty { Text("No settings match “\(search)”.").foregroundStyle(.secondary) }
                    ForEach(results) { page in
                        NavigationLink { page.destination() } label: { row(page.title, page.symbol, page.color) }
                    }
                }
            }
            .navigationTitle("Settings")
            .searchable(text: $search, prompt: "Search settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Reset every setting to its default?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { settings.resetAll() }
            }
        }
    }

    private func row(_ title: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

struct Stepper2: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack { Text(title); Spacer(); Text(format(value)).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}

struct EditorSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Section("Text") {
                Picker("Font", selection: $s.fontName) {
                    ForEach(AppSettings.fontNames, id: \.self) { Text($0).tag($0) }
                }
                Stepper2(title: "Font Size", value: $s.fontSize, range: 8...32, step: 1)
                Stepper2(title: "Line Height", value: $s.lineHeight, range: 1.0...2.0, step: 0.05, format: { String(format: "%.2f×", $0) })
                Toggle("Word Wrap", isOn: $s.wordWrap)
                Toggle("Line Numbers", isOn: $s.showLineNumbers)
                Toggle("Highlight Current Line Number", isOn: $s.highlightCurrentLine)
                Toggle("Syntax Highlighting", isOn: $s.syntaxHighlighting)
                Toggle("Scroll Past End", isOn: $s.scrollPastEnd)
            }
            Section("Indentation") {
                Picker("Indent With", selection: $s.insertSpaces) {
                    Text("Spaces").tag(true); Text("Tabs").tag(false)
                }
                Stepper(value: $s.tabWidth, in: 1...8) {
                    HStack { Text("Tab Width"); Spacer(); Text("\(s.tabWidth)").foregroundStyle(.secondary) }
                }
                Toggle("Auto-Indent New Lines", isOn: $s.autoIndent)
                Toggle("Smart Backspace", isOn: $s.smartBackspace)
            }
            Section {
                Toggle("Suggestions While Typing", isOn: $s.autocomplete)
                Toggle("Underline Errors", isOn: $s.checkErrors)
                if s.checkErrors {
                    Toggle("Check with Runner Server", isOn: $s.checkWithRunner)
                }
            } header: { Text("Code Smarts") } footer: {
                Text("Suggestions show above the keyboard: words from your file, keywords and snippets. JSON and JavaScript are checked on the phone; Python, C, C++, Go, Rust, Swift, Java, Ruby, PHP, Lua, shell and Perl are checked by your runner server.")
            }
            Section("Typing") {
                Toggle("Auto-Close Brackets", isOn: $s.autoCloseBrackets)
                Toggle("Auto-Close Quotes", isOn: $s.autoCloseQuotes)
                Toggle("Autocorrect", isOn: $s.autocorrect)
                Toggle("Spell Check", isOn: $s.spellCheck)
            }
            Section {
                Toggle("Autosave", isOn: $s.autosave)
                if s.autosave {
                    Stepper2(title: "Autosave Delay", value: $s.autosaveDelay, range: 0.5...10, step: 0.5, format: { String(format: "%.1f s", $0) })
                }
                Toggle("Trim Trailing Spaces on Save", isOn: $s.trimTrailingWhitespace)
                Toggle("End Files with a Newline", isOn: $s.insertFinalNewline)
            } header: { Text("Saving") } footer: {
                Text("Trim and newline rules apply when you save by hand, so they never move your cursor mid-typing.")
            }
            Section {
                Picker("Highlight Files Up To", selection: $s.largeFileThreshold) {
                    Text("100 KB").tag(100_000); Text("300 KB").tag(300_000); Text("1 MB").tag(1_000_000); Text("3 MB").tag(3_000_000)
                }
            } footer: { Text("Bigger files open without colors so typing stays smooth.") }
        }
        .navigationTitle("Editor")
    }
}

struct KeyboardSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Show Key Row Above Keyboard", isOn: $s.showKeyboardAccessory)
                Toggle("Arrow Keys", isOn: $s.accessoryShowArrows)
                Toggle("Undo & Redo Keys", isOn: $s.accessoryShowUndo)
            }
            Section {
                TextField("Keys", text: $s.accessoryKeys, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Restore Default Keys") { s.accessoryKeys = AppSettings.defaultAccessoryKeys }
            } header: { Text("Symbol Keys") } footer: {
                Text("Separate keys with spaces. A key can be more than one character, like => or ::")
            }
        }
        .navigationTitle("Keyboard")
    }
}

struct AppearanceSettings: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var extensions: ExtensionManager
    @EnvironmentObject var router: Router

    private var holidayNow: String? {
        Holidays.current().map { extensions.theme(id: $0).name }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Theme Styles Whole App", isOn: $s.themeControlsApp)
                Toggle("Automatic Holiday Themes", isOn: $s.autoHolidayThemes)
            } footer: {
                Text("Whole-app themes also color the bars, sidebar, tabs, console and font style, and switch light/dark for you. Seasonal effects (snow and more) are in Backgrounds & Effects. Automatic holiday themes switch to a holiday look on those days\(holidayNow.map { " (today: \($0))" } ?? "") and back afterwards.")
            }

            Section("App") {
                Picker("Appearance", selection: $s.appearance) {
                    Text("Match Theme / System").tag("system"); Text("Always Light").tag("light"); Text("Always Dark").tag("dark")
                }
                if !s.themeControlsApp {
                    Picker("Accent Color", selection: $s.accentName) {
                        ForEach(AppSettings.accents, id: \.0) { a in Text(a.0).tag(a.0) }
                    }
                }
            }

            ForEach(ThemeLibrary.groups + extensionGroup, id: \.self) { group in
                let list = extensions.allThemes.filter { $0.group == group }
                if !list.isEmpty {
                    Section(group) {
                        ForEach(list) { t in
                            Button { s.themeID = t.id } label: { ThemeRow(theme: t, selected: s.themeID == t.id) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }

        }
        .navigationTitle("Themes")
    }

    private var extensionGroup: [String] {
        let known = Set(ThemeLibrary.groups)
        return Array(Set(extensions.allThemes.map { $0.group }).subtracting(known)).sorted()
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Toggle("Haptic Feedback", isOn: $s.hapticFeedback)
            Toggle("Keep Screen Awake", isOn: $s.keepScreenAwake)
            Toggle("Show Welcome File When Nothing Is Open", isOn: $s.showWelcome)
            Toggle("Enable Extensions", isOn: $s.extensionsEnabled)
        }
        .navigationTitle("General")
    }
}


struct AgentSettings: View {
    @EnvironmentObject var s: AppSettings
    @State private var keyDraft = ""
    @State private var editingKey = false

    private var maskedKey: String {
        let k = s.agentAPIKey
        guard k.count > 12 else { return k.isEmpty ? "Not set" : "Saved" }
        return String(k.prefix(7)) + "…" + String(k.suffix(4))
    }

    var body: some View {
        Form {
            Section {
                if editingKey || s.agentAPIKey.isEmpty {
                    SecureField("sk-ant-…", text: $keyDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("Save Key") {
                            s.agentAPIKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            keyDraft = ""; editingKey = false
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if editingKey { Spacer(); Button("Cancel") { keyDraft = ""; editingKey = false } }
                    }
                } else {
                    LabeledContent("API Key", value: maskedKey)
                    Button("Change Key") { editingKey = true }
                    Button("Remove Key", role: .destructive) { s.agentAPIKey = "" }
                }
            } header: { Text("Anthropic API Key") } footer: {
                Text("Stored only in this iPhone's Keychain. It's not in the app, its settings or the IPA, and it's never sent to your server: the agent talks to Anthropic directly. Get a key at console.anthropic.com.")
            }
            Section {
                Picker("Model", selection: $s.agentModel) {
                    ForEach(AgentSession.models, id: \.id) { m in Text(m.name).tag(m.id) }
                }
            } footer: { Text("Haiku is cheapest (about 2¢ for a small job), Sonnet is the best value (about 25¢), Opus is strongest (about 50¢).") }
            Section {
                Toggle("Cloud Workspace", isOn: $s.agentCloudWorkspace)
            } header: { Text("Beta") } footer: {
                Text("Gives the agent a Linux copy of your project on your runner server, so it can install packages, run whole projects and tests, build and use git. Files it changes there come back to your phone (with undo). Editing works the same with this on or off. Uses a bit more AI credit per job.")
            }
            Section {
                Picker("Ask Before", selection: $s.agentApproval) {
                    Text("Deletes & overwrites").tag("risky")
                    Text("Every change").tag("all")
                }
            } header: { Text("Approvals") } footer: { Text("Everything the agent changes can be undone from its ⋯ menu.") }
            Section {
                Stepper2(title: "Spending Limit per Chat", value: $s.agentSpendCap, range: 0.05...20, step: 0.05, format: { String(format: "$%.2f", $0) })
                Stepper(value: $s.agentMaxSteps, in: 5...200, step: 5) {
                    HStack { Text("Max Steps per Request"); Spacer(); Text("\(s.agentMaxSteps)").foregroundStyle(.secondary) }
                }
            } header: { Text("Limits") } footer: {
                Text("The agent talks to Claude through your runner server, where your Anthropic API key is kept. The key never goes in the app.")
            }
        }
        .navigationTitle("Agent")
    }
}


struct BackgroundSettings: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var router: Router

    var body: some View {
        Form {
            Section {
                if s.backgroundActive {
                    Picker("Fit", selection: $s.backgroundFit) {
                        Text("Fill Screen").tag("fill"); Text("Fit Whole Image").tag("fit")
                    }
                    Stepper2(title: "Show Through Editor", value: $s.backgroundStrength, range: 0...0.9, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
                    Stepper2(title: "Darken", value: $s.backgroundDim, range: 0...0.9, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
                    Stepper2(title: "Frosted Glass", value: $s.backgroundBlur, range: 0...1, step: 0.1, format: { String(format: "%.0f%%", $0 * 100) })
                    if s.backgroundKind != "image" {
                        Toggle("Animate", isOn: $s.animateBackground)
                    }
                }
                Button { pickPhotos() } label: { Label("Choose from Photos…", systemImage: "photo.on.rectangle") }
                Button { pickFiles() } label: { Label("Choose from Files…", systemImage: "folder") }
                if s.backgroundActive {
                    Button(role: .destructive) { BackgroundStore.remove() } label: { Label("Remove Background", systemImage: "xmark.circle") }
                }
            } header: { Text("Background") } footer: {
                Text("Use a photo, GIF, video or Live Photo (it plays as a loop, muted). It pauses whenever MangoIDE isn't on screen.")
            }

            Section {
                Toggle("Seasonal Effects", isOn: $s.showEffects)
                if s.showEffects {
                    Stepper2(title: "Effect Amount", value: $s.effectIntensity, range: 0.25...2.5, step: 0.25, format: { String(format: "%.0f%%", $0 * 100) })
                }
            } header: { Text("Effects") } footer: {
                Text("Themes with an effect (like snow on winter themes) show it over the editor. It never blocks taps.")
            }
        }
        .navigationTitle("Backgrounds & Effects")
    }

    private func pickPhotos() {
        BackgroundStore.pickFromPhotos { err in
            if let err { router.fail(err) } else { router.flash("Background set") }
        }
    }

    private func pickFiles() {
        BackgroundStore.pickFromFiles { err in
            if let err { router.fail(err) } else { router.flash("Background set") }
        }
    }
}

struct ThemeRow: View {
    let theme: EditorTheme
    let selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text("func ").foregroundStyle(Color(hex: theme.keyword))
                    Text("greet").foregroundStyle(Color(hex: theme.function))
                    Text("(").foregroundStyle(Color(hex: theme.foreground))
                    Text("\"hi\"").foregroundStyle(Color(hex: theme.string))
                    Text(", ").foregroundStyle(Color(hex: theme.foreground))
                    Text("42").foregroundStyle(Color(hex: theme.number))
                    Text(")").foregroundStyle(Color(hex: theme.foreground))
                }
                Text("// \(theme.emoji.map { $0 + " " } ?? "")\(theme.name)").foregroundStyle(Color(hex: theme.comment))
            }
            .font(.system(size: 13, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: theme.background), in: RoundedRectangle(cornerRadius: 8))
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .font(.title3)
        }
        .contentShape(Rectangle())
    }
}

struct FileSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Section("Sidebar") {
                Picker("Sort By", selection: $s.sortMode) {
                    Text("Name").tag("name"); Text("Date Modified").tag("date"); Text("Kind").tag("kind"); Text("Size").tag("size")
                }
                Toggle("Folders First", isOn: $s.foldersFirst)
                Toggle("Show Hidden Files", isOn: $s.showHiddenFiles)
                Toggle("Close Sidebar After Opening (iPhone)", isOn: $s.closeSidebarOnOpen)
                Toggle("Confirm Before Deleting", isOn: $s.confirmDelete)
            }
            Section("Tabs") {
                Toggle("Reopen Tabs on Launch", isOn: $s.restoreTabs)
                Stepper(value: $s.maxTabs, in: 2...60) {
                    HStack { Text("Max Tabs per Side"); Spacer(); Text("\(s.maxTabs)").foregroundStyle(.secondary) }
                }
            }
            Section("New Files") {
                TextField("Default Extension", text: $s.defaultExtension)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("New Projects") {
                Toggle("Add README.md", isOn: $s.projectReadme)
                Toggle("Add .gitignore", isOn: $s.projectGitignore)
            }
        }
        .navigationTitle("Files & Projects")
    }
}

struct RunSettings: View {
    @EnvironmentObject var s: AppSettings
    @State private var testing = false
    @State private var result: String?
    @State private var runtimes: [String] = []

    var body: some View {
        Form {
            Section {
                TextField("https://your-runner.example.com", text: $s.runnerURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Runner Key", text: $s.runnerKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    testing = true; result = nil
                    RunService.listRuntimes { r in
                        testing = false
                        switch r {
                        case .success(let list): runtimes = list; result = "Connected · \(list.count) languages available"
                        case .failure(let e): runtimes = []; result = e.localizedDescription
                        }
                    }
                } label: {
                    HStack { Text("Test Connection"); if testing { Spacer(); ProgressView() } }
                }
                if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
                Stepper2(title: "Timeout", value: $s.runnerTimeout, range: 5...120, step: 5, format: { "\(Int($0)) s" })
            } header: { Text("Runner Server") } footer: {
                Text("The address and key are saved to this iPhone's Keychain, so they stay even if you delete and reinstall MangoIDE. JavaScript runs right on your phone and HTML/Markdown open as previews. Every other language (Python, C, Java, Go, Rust, Swift…) is sent to a Piston-compatible runner server, which runs it and sends back the output.")
            }
            if !runtimes.isEmpty {
                Section("Available on this server") {
                    ForEach(runtimes, id: \.self) { Text($0).font(.system(.footnote, design: .monospaced)) }
                }
            }
            Section("When Running") {
                Toggle("Save File First", isOn: $s.saveBeforeRun)
                Toggle("Clear Console", isOn: $s.clearConsoleOnRun)
                Toggle("Open Console", isOn: $s.showConsoleOnRun)
                Toggle("Show Run Time", isOn: $s.showExecutionTime)
                Toggle("JavaScript Strict Mode", isOn: $s.jsStrictMode)
            }
        }
        .navigationTitle("Run & Console")
    }
}

struct LayoutSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Section("Layout") {
                Toggle("Status Bar", isOn: $s.showStatusBar)
                Toggle("File Icons", isOn: $s.showFileIcons)
                Toggle("Compact Tabs", isOn: $s.compactTabs)
                Toggle("Close Buttons on Tabs", isOn: $s.showTabCloseButtons)
                Picker("Split Direction", selection: $s.splitOrientation) {
                    Text("Automatic").tag("auto"); Text("Side by Side").tag("horizontal"); Text("Top and Bottom").tag("vertical")
                }
                Stepper2(title: "Sidebar Width (iPad)", value: $s.sidebarWidth, range: 200...420, step: 20)
                Stepper2(title: "Console Text Size", value: $s.consoleFontSize, range: 9...22, step: 1)
            }
        }
        .navigationTitle("Layout")
    }
}

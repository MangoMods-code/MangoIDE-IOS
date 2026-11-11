import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var extensions: ExtensionManager
    @Environment(\.dismiss) var dismiss
    @State private var confirmReset = false
    @State private var search = ""
    @State private var templateCount = 0

    /// Every settings page, so search can find them by name or by what's inside.
    private struct Page: Identifiable {
        let title: String
        let subtitle: String
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
                Page(title: "MangoIDE Pro", subtitle: "Cloud sync, full GitHub, sharing", symbol: "star.fill", color: .orange, keywords: "subscription upgrade billing stripe pay price plan manage cancel") { AnyView(ProView()) },
                Page(title: "AI Credit", subtitle: "Balance and top-ups for the agent", symbol: "creditcard.fill", color: .green, keywords: "top up balance agent money stripe payment receipts refund") { AnyView(CreditView()) },
            ]),
            Group(title: "Cloud & Collaboration", pages: [
                Page(title: "Cloud Sync & Backup", subtitle: "Projects on all your devices", symbol: "icloud.fill", color: .cyan, keywords: "sync backup restore devices storage") { AnyView(CloudView()) },
                Page(title: "GitHub", subtitle: "Clone, commit, push and publish", symbol: "arrow.triangle.branch", color: Color(white: 0.25), keywords: "git clone push pull commit repo publish branch") { AnyView(GitHubSettings()) },
                Page(title: "Sharing & Live Sessions", subtitle: "Share links and edit together", symbol: "person.2.fill", color: .mint, keywords: "share link collaborate live session invite cursors together") { AnyView(SharingSettings()) },
            ]),
            Group(title: "Editing", pages: [
                Page(title: "Editor", subtitle: "Font, indentation, suggestions, saving", symbol: "character.cursor.ibeam", color: .blue, keywords: "font size line numbers wrap indentation tabs spaces autosave save trim suggestions errors") { AnyView(EditorSettings()) },
                Page(title: "Keyboard", subtitle: "The key bar above the keyboard", symbol: "keyboard", color: .gray, keywords: "brackets autocomplete key bar accessory smart") { AnyView(KeyboardSettings()) },
                Page(title: "Themes", subtitle: "Colors for the editor and the app", symbol: "paintpalette.fill", color: .pink, keywords: "color dark light holiday accent appearance") { AnyView(AppearanceSettings()) },
                Page(title: "Backgrounds & Effects", subtitle: "Photos, videos and seasonal effects", symbol: "photo.fill", color: .purple, keywords: "wallpaper live photo gif video snow effects seasonal") { AnyView(BackgroundSettings()) },
                Page(title: "Layout", subtitle: "Bars, tabs, split view, sidebar", symbol: "rectangle.3.group", color: .indigo, keywords: "status bar tabs split sidebar console file icons") { AnyView(LayoutSettings()) },
            ]),
            Group(title: "Workspace", pages: [
                Page(title: "Files & Projects", subtitle: "Folders and new-project options", symbol: "folder.fill", color: .orange, keywords: "projects folder new files templates") { AnyView(FileSettings()) },
                Page(title: "Run & Console", subtitle: "Runner server and how code runs", symbol: "play.rectangle.fill", color: .green, keywords: "runner server key languages execute console") { AnyView(RunSettings()) },
                Page(title: "Agent", subtitle: "Model, key, approvals and limits", symbol: "sparkles", color: .indigo, keywords: "ai claude anthropic key model memory approvals cloud workspace") { AnyView(AgentSettings()) },
                Page(title: "Extensions", subtitle: "Extra themes, languages and snippets", symbol: "puzzlepiece.extension.fill", color: .purple, keywords: "install themes languages snippets") { AnyView(ExtensionsView()) },
            ]),
            Group(title: "App", pages: [
                Page(title: "General", subtitle: "Haptics, screen and start-up", symbol: "gearshape.fill", color: .gray, keywords: "haptics screen awake welcome") { AnyView(GeneralSettings()) },
                Page(title: "Privacy & Security", subtitle: "Saved keys and signing out", symbol: "lock.shield.fill", color: .blue, keywords: "keychain keys sign out devices sessions password") { AnyView(PrivacySettings()) },
                Page(title: "Storage", subtitle: "Space used and clean-up", symbol: "internaldrive.fill", color: .gray, keywords: "space clear cache drafts temporary size") { AnyView(StorageSettings()) },
            ]),
        ]
    }

    private var results: [Page] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return groups.flatMap(\.pages).filter { ($0.title + " " + $0.subtitle + " " + $0.keywords).lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if search.isEmpty {
                        NavigationLink { AccountView().settingsPage() } label: { AccountHero() }
                            .buttonStyle(PressableStyle(scale: 0.98))
                            .appearRise(0)
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title.uppercased())
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                                    .padding(.leading, 6)
                                card(group.pages)
                            }
                            .appearRise(index + 1)
                        }
                        about.appearRise(groups.count + 1)
                    } else if results.isEmpty {
                        Text("No settings match “\(search)”.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        card(results)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(SettingsBackdrop())
            .navigationTitle("Settings")
            .searchable(text: $search, prompt: "Search settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Reset every setting to its default?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { settings.resetAll() }
            }
            .task {
                templateCount = await Task.detached(priority: .utility) { TemplateLibrary.all.count }.value
            }
        }
    }

    /// A rounded panel of rows.
    private func card(_ pages: [Page]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { i, page in
                NavigationLink { page.destination().settingsPage() } label: { row(page) }
                    .buttonStyle(PressableStyle(scale: 0.985))
                if i < pages.count - 1 { Divider().padding(.leading, 62) }
            }
        }
        .settingsCard()
    }

    private func row(_ page: Page) -> some View {
        HStack(spacing: 14) {
            Image(systemName: page.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(page.color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: page.color.opacity(0.35), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(page.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ABOUT").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6).padding(.leading, 6)
            HStack(spacing: 10) {
                stat("\(extensions.allLanguages.count)", "Languages", "chevron.left.forwardslash.chevron.right")
                stat("\(extensions.allThemes.count)", "Themes", "paintpalette")
                stat(templateCount == 0 ? "…" : "\(templateCount)", "Templates", "square.grid.2x2")
            }
            VStack(spacing: 0) {
                HStack {
                    Text("Version").foregroundStyle(.primary)
                    Spacer()
                    Text("\(Bundle.main.appVersion) (\(Bundle.main.appBuild))").foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                Divider().padding(.leading, 14)
                NavigationLink { DiagnosticsView().settingsPage() } label: {
                    HStack {
                        Label("File Access Diagnostics", systemImage: "stethoscope").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.985))
            }
            .settingsCard()
            Button(role: .destructive) { confirmReset = true } label: {
                Text("Reset All Settings").foregroundStyle(.red).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .settingsCard()
            Text("Your files, account, linked folders and extensions are kept.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
        }
    }

    private func stat(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.footnote.weight(.semibold)).foregroundStyle(.tint)
            Text(value).font(.title3.weight(.bold)).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .settingsCard()
    }
}

// MARK: - Settings look

/// Soft wash of the app's tint behind every settings screen.
struct SettingsBackdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.05), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 380)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// The panel style used on the settings home screen.
    func settingsCard() -> some View {
        background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }

    /// Gives a settings sub-page the same backdrop as the home screen.
    func settingsPage() -> some View {
        scrollContentBackground(.hidden).background(SettingsBackdrop())
    }
}

/// The account banner at the top of Settings.
struct AccountHero: View {
    @ObservedObject var account = AccountManager.shared
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Avatar(url: account.profile?.avatarURL, size: 54)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 2))
            VStack(alignment: .leading, spacing: 5) {
                Text(account.profile.map { $0.name ?? $0.login } ?? "Sign in with GitHub")
                    .font(.title3.weight(.bold)).lineLimit(1)
                if let p = account.profile {
                    HStack(spacing: 6) {
                        chip(p.pro ? "PRO" : "Free", filled: p.pro)
                        chip(String(format: "$%.2f AI credit", p.credits), filled: false)
                    }
                } else {
                    Text("Clone your repos, sync and collaborate").font(.caption).opacity(0.9)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
                // Two soft lights that drift slowly, so the banner feels alive without being busy.
                Circle().fill(Color.white.opacity(0.22)).frame(width: 150, height: 150).blur(radius: 40)
                    .offset(x: drift ? 110 : 60, y: drift ? -40 : -10)
                Circle().fill(Color.black.opacity(0.18)).frame(width: 170, height: 170).blur(radius: 50)
                    .offset(x: drift ? -120 : -80, y: drift ? 50 : 30)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.accentColor.opacity(0.35), radius: 16, y: 8)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    private func chip(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.white.opacity(filled ? 0.95 : 0.22), in: Capsule())
            .foregroundStyle(filled ? Color.accentColor : Color.white)
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

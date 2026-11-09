import SwiftUI

// Settings pages for Pro, AI credit, GitHub, sharing, privacy and storage.

/// Shown when payments aren't switched on yet on the server.
private struct PaymentsOffNote: View {
    var body: some View {
        Label {
            Text("Payments aren't switched on yet. Once Stripe is connected to the MangoIDE server, buying works right here.")
        } icon: { Image(systemName: "exclamationmark.triangle") }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct SignInPrompt: View {
    let why: String
    @ObservedObject var account = AccountManager.shared
    var body: some View {
        Section {
            Text(why).foregroundStyle(.secondary)
            Button { account.signIn() } label: {
                HStack { if account.busy { ProgressView() }; Text("Sign in with GitHub").fontWeight(.semibold) }
            }
            .disabled(account.busy)
        }
    }
}

// MARK: - MangoIDE Pro

struct ProView: View {
    @ObservedObject var account = AccountManager.shared

    private let free: [(String, String)] = [
        ("chevron.left.forwardslash.chevron.right", "Editor, tabs, split view, 90+ languages"),
        ("play.fill", "Run code, previews, console"),
        ("paintpalette", "Every theme, background and extension"),
        ("sparkles", "Coding agent with your own Anthropic key"),
        ("arrow.down.circle", "Clone your own GitHub repos"),
        ("link", "Open shared projects"),
        ("person.2", "Join live sessions"),
    ]
    private let pro: [(String, String)] = [
        ("icloud", "Cloud Sync & Backup across your devices"),
        ("arrow.triangle.branch", "Clone any repo, commit, push, pull, publish"),
        ("link.badge.plus", "Share project links"),
        ("dot.radiowaves.left.and.right", "Host live sessions"),
    ]

    var body: some View {
        Form {
            if let p = account.profile {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "star.circle.fill").font(.system(size: 44)).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.pro ? "You have Pro" : "MangoIDE Pro").font(.title3.bold())
                            Text(p.pro ? (p.proStatus == "owner pass" ? "Owner Pass, free forever" : "Status: \(p.proStatus.capitalized)")
                                       : String(format: "$%.2f a month, cancel anytime", p.proPrice))
                                .foregroundStyle(.secondary)
                            if let until = p.proUntil, p.pro, p.proStatus != "owner pass" {
                                Text("Renews or ends \(CloudSync.shortDate(until))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if p.pro {
                        if p.proStatus != "owner pass" {
                            Button("Manage or Cancel Subscription") { account.manageBilling() }
                        }
                    } else {
                        Button { account.buyPro() } label: {
                            HStack {
                                if account.busy { ProgressView() }
                                Label(String(format: "Get Pro · $%.2f/month", p.proPrice), systemImage: "star.fill").fontWeight(.semibold)
                            }
                        }
                        .disabled(!p.payments || account.busy)
                        if !p.payments { PaymentsOffNote() }
                    }
                } footer: {
                    Text("Checkout opens Stripe's secure page in Safari. Card details never touch MangoIDE.")
                }
            } else {
                SignInPrompt(why: "Sign in with GitHub to get Pro.")
            }

            Section("Pro adds") {
                ForEach(pro, id: \.1) { item in Label(item.1, systemImage: item.0) }
            }
            Section {
                ForEach(free, id: \.1) { item in Label(item.1, systemImage: item.0).foregroundStyle(.primary) }
            } header: { Text("Always free") } footer: {
                Text("If Pro ends, nothing is deleted: you can still download your cloud backups and keep every file.")
            }
        }
        .navigationTitle("MangoIDE Pro")
        .onAppear { account.refresh() }
        .alert("Account", isPresented: Binding(get: { account.message != nil }, set: { if !$0 { account.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(account.message ?? "") }
    }
}

// MARK: - AI Credit

struct CreditView: View {
    @ObservedObject var account = AccountManager.shared
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            if let p = account.profile {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Balance").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "$%.2f", p.credits)).font(.system(size: 38, weight: .bold, design: .rounded))
                    }
                    .padding(.vertical, 4)
                    HStack {
                        ForEach(p.topups, id: \.self) { amount in
                            Button(String(format: "+$%.0f", amount)) { account.topUp(dollars: amount) }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!p.payments || account.busy)
                    if !p.payments { PaymentsOffNote() }
                    if p.payments { Button("Receipts & Refunds") { account.manageBilling() } }
                } header: { Text("AI Credit") } footer: {
                    Text("Prepaid, so you're never charged after the fact. When it runs out, the agent just stops.")
                }
                if !p.aiCredits {
                    Section { Label("AI credit isn't switched on on the server yet.", systemImage: "info.circle").foregroundStyle(.secondary) }
                }
            } else {
                SignInPrompt(why: "Sign in with GitHub to buy AI credit.")
            }
            Section {
                LabeledContent("Agent uses", value: settings.agentAPIKey.isEmpty ? "AI credit" : "Your own key")
                NavigationLink("Agent Settings") { AgentSettings() }
            } footer: {
                Text("If you add your own Anthropic key in Agent settings, the agent uses that instead and your credit isn't touched.")
            }
        }
        .navigationTitle("AI Credit")
        .onAppear { account.refresh() }
    }
}

// MARK: - GitHub

struct GitHubSettings: View {
    @ObservedObject var account = AccountManager.shared
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var router: Router

    var body: some View {
        Form {
            if let p = account.profile {
                Section {
                    HStack(spacing: 12) {
                        Avatar(url: p.avatarURL, size: 40)
                        VStack(alignment: .leading) {
                            Text("@\(p.login)").font(.headline)
                            Text("Connected").font(.caption).foregroundStyle(.green)
                        }
                    }
                    Button { router.show(.github) } label: { Label("Open GitHub…", systemImage: "arrow.triangle.branch") }
                } footer: {
                    Text("Your GitHub access stays encrypted on the MangoIDE server and is never stored on this device.")
                }
            } else {
                SignInPrompt(why: "Sign in with GitHub to clone your repositories.")
            }
            Section("Where clones go") {
                LabeledContent("Folder", value: workspace.projectsRoot?.lastPathComponent ?? "MangoIDE › Projects")
                Text("Change it in Files & Projects by choosing a projects folder.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Label("Clone your own repos", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                HStack { Label("Clone anyone's repo", systemImage: "arrow.down.circle"); Spacer(); if !account.isPro { ProBadge() } }
                HStack { Label("Commit & Push", systemImage: "arrow.up.circle"); Spacer(); if !account.isPro { ProBadge() } }
                HStack { Label("Pull", systemImage: "arrow.down.to.line"); Spacer(); if !account.isPro { ProBadge() } }
                HStack { Label("Publish a project", systemImage: "icloud.and.arrow.up"); Spacer(); if !account.isPro { ProBadge() } }
            } header: { Text("Features") } footer: {
                Text("Pull keeps your edits: if a file changed both here and on GitHub, GitHub's version is saved next to yours as .remote.")
            }
        }
        .navigationTitle("GitHub")
    }
}

// MARK: - Sharing & live sessions

struct SharingSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: Router
    @ObservedObject var account = AccountManager.shared
    @ObservedObject var live = LiveSession.shared

    var body: some View {
        Form {
            Section {
                Button { router.show(.collab) } label: { Label("Share & Collaborate…", systemImage: "person.2") }
                if live.isActive {
                    LabeledContent("Live now", value: "\(live.name) · \(live.people.count) here")
                }
            }
            Section {
                Toggle("Show Collaborators' Cursors", isOn: $settings.showPeerCursors)
            } header: { Text("Live Sessions") } footer: {
                Text("Everyone in a session edits at the same time. Files save as you go. Hosting needs Pro; joining is free.")
            }
            Section {
                Picker("Links Work For", selection: $settings.shareLinkDays) {
                    Text("1 Day").tag(1); Text("7 Days").tag(7); Text("30 Days").tag(30); Text("90 Days").tag(90); Text("1 Year").tag(365)
                }
                NavigationLink { SharedLinksView() } label: { Text("Your Shared Links") }
                    .disabled(!account.isSignedIn)
            } header: { Text("Share Links") } footer: {
                Text("A share link is a snapshot copy. People who open it get their own copy; the agent's private notes (.mango) are never included.")
            }
        }
        .navigationTitle("Sharing & Live Sessions")
    }
}

// MARK: - Privacy & security

struct PrivacySettings: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var account = AccountManager.shared
    @State private var confirmEverywhere = false
    @State private var confirmKey = false

    var body: some View {
        Form {
            Section {
                row("MangoIDE sign-in", account.isSignedIn)
                row("Anthropic API key", !settings.agentAPIKey.isEmpty)
                row("Runner server key", !settings.runnerKey.isEmpty)
            } header: { Text("Stored in this device's Keychain") } footer: {
                Text("These never leave this device except to the service they're for, and aren't in backups of your projects or shared links.")
            }
            Section {
                if !settings.agentAPIKey.isEmpty {
                    Button("Remove Anthropic Key", role: .destructive) { confirmKey = true }
                }
                if account.isSignedIn {
                    Button("Sign Out") { account.signOut(everywhere: false) }
                    Button("Sign Out on All Devices", role: .destructive) { confirmEverywhere = true }
                }
            }
            Section {
                Label("Payments happen on Stripe's page in Safari. MangoIDE never sees card details.", systemImage: "creditcard")
                Label("Your GitHub access is encrypted on the server, never stored on this device.", systemImage: "lock")
                Label("Cloud files are only readable with your account. Share links only expose the files in that link.", systemImage: "icloud")
            } header: { Text("How your data is handled") }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Privacy & Security")
        .confirmationDialog("Sign out on every device?", isPresented: $confirmEverywhere, titleVisibility: .visible) {
            Button("Sign Out Everywhere", role: .destructive) { account.signOut(everywhere: true) }
        }
        .confirmationDialog("Remove your Anthropic key from this device?", isPresented: $confirmKey, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) { settings.agentAPIKey = "" }
        }
    }

    private func row(_ title: String, _ on: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(on ? "Saved" : "Not set").foregroundStyle(on ? Color.green : Color.secondary)
        }
    }
}

// MARK: - Storage

struct StorageSettings: View {
    @EnvironmentObject var workspace: Workspace
    @State private var sizes: [String: Int64] = [:]
    @State private var loading = true
    @State private var confirmDrafts = false

    private var items: [(String, String, URL)] {
        [("Projects", "shippingbox", workspace.projectsFolder),
         ("Scratchpad", "note.text", workspace.scratchFolder),
         ("Imported", "square.and.arrow.down", workspace.importedFolder),
         ("Extensions", "puzzlepiece.extension", workspace.extensionsFolder),
         ("Unsaved drafts", "doc.badge.ellipsis", DraftStore.folderURL),
         ("Temporary files", "clock.arrow.circlepath", FileManager.default.temporaryDirectory)]
    }

    var body: some View {
        Form {
            Section {
                ForEach(items, id: \.0) { item in
                    HStack {
                        Label(item.0, systemImage: item.1)
                        Spacer()
                        if loading { ProgressView() } else {
                            Text(ByteCountFormatter.string(fromByteCount: sizes[item.0] ?? 0, countStyle: .file)).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("On this device") } footer: {
                Text(workspace.projectsRoot.map { "Your projects folder \($0.lastPathComponent) is outside MangoIDE and isn't counted here." } ?? "")
            }
            Section {
                Button("Clear Temporary Files") {
                    let tmp = FileManager.default.temporaryDirectory
                    DispatchQueue.global(qos: .utility).async {
                        for u in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: u) }
                        DispatchQueue.main.async { measure() }
                    }
                }
                Button("Delete Unsaved Drafts", role: .destructive) { confirmDrafts = true }
            } footer: {
                Text("Temporary files are leftovers from downloads, imports and zips. Drafts are unsaved edits kept for when you reopen the app.")
            }
        }
        .navigationTitle("Storage")
        .onAppear(perform: measure)
        .confirmationDialog("Delete all unsaved drafts?", isPresented: $confirmDrafts, titleVisibility: .visible) {
            Button("Delete Drafts", role: .destructive) { DraftStore.removeAll(); measure() }
        } message: {
            Text("Unsaved edits in files that aren't open right now will be lost.")
        }
    }

    private func measure() {
        loading = true
        let list = items
        DispatchQueue.global(qos: .utility).async {
            var out: [String: Int64] = [:]
            for (name, _, url) in list { out[name] = StorageSettings.size(of: url) }
            DispatchQueue.main.async { sizes = out; loading = false }
        }
    }

    nonisolated static func size(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

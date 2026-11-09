import SwiftUI

/// Share & Collaborate: live sessions (edit together) and share-a-copy links.
struct CollabView: View {
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var router: Router
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var account = AccountManager.shared
    @ObservedObject var live = LiveSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var joinCode = ""
    @State private var openCode = ""
    @State private var working: String?
    @State private var errorText: String?
    @State private var proPrompt: String?
    @State private var madeLink: String?
    @State private var confirmEnd = false

    private var project: URL? {
        let candidate = editor.lastProject ?? workspace.activeProject
            ?? editor.activeDocument.flatMap { workspace.projectFolder(containing: $0.url) }
        guard let c = candidate, workspace.isDirectory(c), !workspace.isBuiltInFolder(c),
              c.standardizedFileURL != workspace.root.standardizedFileURL else { return nil }
        return c
    }

    var body: some View {
        NavigationStack {
            List {
                if !account.isSignedIn {
                    Section {
                        Text("Sign in with GitHub to start or join live sessions and to share project links.")
                            .foregroundStyle(.secondary)
                        Button("Sign in with GitHub") { account.signIn() }
                    }
                }
                liveSection
                shareSection
            }
            .navigationTitle("Share & Collaborate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .disabled(working != nil)
            .overlay {
                if let working {
                    VStack(spacing: 12) { ProgressView(); Text(working).font(.subheadline.weight(.medium)).multilineTextAlignment(.center) }
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .alert("Share & Collaborate", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
            .alert("MangoIDE Pro", isPresented: Binding(get: { proPrompt != nil }, set: { if !$0 { proPrompt = nil } })) {
                if account.profile?.payments == true { Button("Get Pro") { account.buyPro() } }
                Button("Not Now", role: .cancel) {}
            } message: { Text(proPrompt ?? "") }
            .confirmationDialog(live.isHost ? "End the session for everyone?" : "Leave the session?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button(live.isHost ? "End Session" : "Leave", role: .destructive) { live.leave() }
            } message: {
                Text("Everyone keeps the files they have.")
            }
        }
    }

    // MARK: Live

    @ViewBuilder private var liveSection: some View {
        if live.isActive {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(live.status == .live ? Color.green : Color.orange).frame(width: 9, height: 9)
                        Text(live.status == .live ? "Live" : live.status == .connecting ? "Connecting…" : "Reconnecting…")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(live.name).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(live.code ?? "")
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .textSelection(.enabled)
                    Text(live.isHost ? "You're hosting. Send this code or the invite link." : "Hosted by @\(live.hostLogin).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if let link = live.link {
                    ShareLink(item: link, subject: Text("Edit \(live.name) with me in MangoIDE"),
                              message: Text("Join my live MangoIDE session: code \(live.code ?? "")")) {
                        Label("Invite People", systemImage: "person.badge.plus")
                    }
                }
                Button { UIPasteboard.general.string = live.code; router.flash("Code copied") } label: {
                    Label("Copy Code", systemImage: "doc.on.doc")
                }
                Button(live.isHost ? "End Session" : "Leave Session", role: .destructive) { confirmEnd = true }
            } header: { Text("Live Session") }

            Section("People Here (\(live.people.count))") {
                ForEach(live.people) { p in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color(hex: p.color)).frame(width: 30, height: 30)
                            Text(String(p.login.prefix(1)).uppercased()).font(.footnote.bold()).foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("@\(p.login)" + (p.id == live.me?.id ? " (you)" : "")).lineLimit(1)
                            Text(p.path.map { "In \(($0 as NSString).lastPathComponent)" } ?? (p.host ? "Host" : "Just joined"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p.host { Image(systemName: "crown.fill").foregroundStyle(.yellow).font(.caption) }
                    }
                }
            }
        } else {
            Section {
                if let project {
                    Button {
                        guard account.isPro else { proPrompt = "Hosting a live session is part of MangoIDE Pro. Joining one is free."; return }
                        startLive(project)
                    } label: {
                        HStack {
                            Label("Start Live Session", systemImage: "dot.radiowaves.left.and.right")
                            Spacer()
                            if !account.isPro { ProBadge() }
                        }
                    }
                    .disabled(!account.isSignedIn)
                } else {
                    Text("Open a project to start a live session on it.").foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Join with a code", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .onSubmit(joinLive)
                    Button("Join", action: joinLive)
                        .disabled(joinCode.trimmingCharacters(in: .whitespaces).count < 4 || !account.isSignedIn)
                }
            } header: {
                Text("Live Session")
            } footer: {
                Text(project.map { "Everyone edits \($0.lastPathComponent) at the same time and sees each other's cursors. Files save as you go. Joining is free." }
                     ?? "Everyone edits the same project at the same time and sees each other's cursors. Joining is free.")
            }
        }
    }

    private func startLive(_ project: URL) {
        working = "Starting live session…"
        Task {
            do { try await live.host(project) }
            catch CloudError.needsPro(let m) { proPrompt = m }
            catch { errorText = error.localizedDescription }
            working = nil
        }
    }

    private func joinLive() {
        let code = String(joinCode.uppercased().filter { $0.isLetter || $0.isNumber }.suffix(6))
        guard code.count >= 4 else { return }
        working = "Looking up \(code)…"
        Task {
            do {
                _ = try await live.info(code)
                live.join(code)
                joinCode = ""
                router.sidebarOpen = true
            } catch { errorText = error.localizedDescription }
            working = nil
        }
    }

    // MARK: Share a copy

    private var shareSection: some View {
        Section {
            if let project {
                Button {
                    guard account.isPro else { proPrompt = "Sharing a project link is part of MangoIDE Pro. Opening a shared link is free."; return }
                    makeLink(project)
                } label: {
                    HStack {
                        Label("Share a Copy of \(project.lastPathComponent)", systemImage: "link.badge.plus")
                        Spacer()
                        if !account.isPro { ProBadge() }
                    }
                }
                .disabled(!account.isSignedIn)
            }
            if let madeLink, let url = URL(string: madeLink) {
                ShareLink(item: url) { Label("Send Link", systemImage: "square.and.arrow.up") }
                Text(madeLink).font(.footnote.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Open a shared link or code", text: $openCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(openShared)
                Button("Open", action: openShared).disabled(openCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            NavigationLink { SharedLinksView() } label: { Label("Your Shared Links", systemImage: "list.bullet") }
                .disabled(!account.isSignedIn)
        } header: {
            Text("Share a Copy")
        } footer: {
            Text("Makes a link to a snapshot of the project. Anyone with MangoIDE can open it and get their own copy, no account needed. Links last \(settings.shareLinkDays) days and you can turn them off anytime.")
        }
    }

    private func makeLink(_ project: URL) {
        working = "Uploading \(project.lastPathComponent)…"
        Task {
            let scoped = project.startAccessingSecurityScopedResource()
            defer { if scoped { project.stopAccessingSecurityScopedResource() } }
            do {
                let r = try await CloudEngine.shared.share(name: project.lastPathComponent, folder: project, days: settings.shareLinkDays)
                madeLink = r.link
                UIPasteboard.general.string = r.link
                router.flash("Link copied")
            }
            catch CloudError.needsPro(let m) { proPrompt = m }
            catch { errorText = error.localizedDescription }
            working = nil
        }
    }

    private func openShared() {
        let t = openCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = String((t.split(separator: "/").last.map(String.init) ?? t).uppercased().filter { $0.isLetter || $0.isNumber })
        guard code.count >= 6 else { errorText = "That doesn't look like a share link or code."; return }
        openCode = ""
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { router.show(.openShare(code)) }
    }
}

struct ProBadge: View {
    var body: some View {
        Text("PRO").font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(.orange)
    }
}

/// Links you've shared: see downloads, copy, or turn them off.
struct SharedLinksView: View {
    @State private var shares: [SharedLink] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        List {
            if loading { HStack { Spacer(); ProgressView(); Spacer() } }
            else if shares.isEmpty { Text("You haven't shared any projects yet.").foregroundStyle(.secondary) }
            ForEach(shares) { s in
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.name).font(.body.weight(.medium))
                    Text("\(s.files) files · \(ByteCountFormatter.string(fromByteCount: Int64(s.size), countStyle: .file)) · opened \(s.downloads)×")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Works until \(CloudSync.shortDate(s.expiresAt))").font(.caption2).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Turn Off", role: .destructive) { revoke(s) }
                }
                .contextMenu {
                    if let u = URL(string: s.link) { ShareLink(item: u) { Label("Send Link", systemImage: "square.and.arrow.up") } }
                    Button { UIPasteboard.general.string = s.link } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { revoke(s) } label: { Label("Turn Off Link", systemImage: "link.badge.minus") }
                }
            }
        }
        .navigationTitle("Shared Links")
        .task { await load() }
        .refreshable { await load() }
        .alert("Shared Links", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func load() async {
        do { shares = try await CloudEngine.shared.myShares() } catch { errorText = error.localizedDescription }
        loading = false
    }

    private func revoke(_ s: SharedLink) {
        Task {
            do { try await CloudEngine.shared.revokeShare(s.code); shares.removeAll { $0.code == s.code } }
            catch { errorText = error.localizedDescription }
        }
    }
}

/// Opened from a share link: preview it, then copy it into your projects.
struct OpenShareSheet: View {
    let code: String
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var info: ShareInfo?
    @State private var errorText: String?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let info {
                    Image(systemName: "shippingbox.fill").font(.system(size: 48)).foregroundStyle(.tint).padding(.top, 30)
                    Text(info.name).font(.title2.bold()).multilineTextAlignment(.center)
                    Text("Shared by @\(info.owner)").foregroundStyle(.secondary)
                    Text("\(info.files) files · \(ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file))")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        importing = true
                        Task {
                            let parent = workspace.projectsRoot ?? workspace.projectsFolder
                            let scoped = parent.startAccessingSecurityScopedResource()
                            defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
                            do {
                                let url = try await CloudEngine.shared.importShare(info, into: parent)
                                workspace.refresh()
                                editor.lastProject = url
                                router.revealRequest = url
                                router.sidebarOpen = true
                                router.flash("Added \(url.lastPathComponent)")
                                dismiss()
                            } catch { errorText = error.localizedDescription }
                            importing = false
                        }
                    } label: {
                        HStack { if importing { ProgressView().tint(.white) }; Text("Add to My Projects").fontWeight(.semibold) }
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importing)
                    .padding(.horizontal, 30)
                    Text("You get your own copy. Changes you make don't affect theirs.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else if let errorText {
                    Image(systemName: "link.badge.minus").font(.system(size: 44)).foregroundStyle(.secondary).padding(.top, 40)
                    Text(errorText).multilineTextAlignment(.center).foregroundStyle(.secondary)
                } else {
                    ProgressView().padding(.top, 60)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Shared Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                do { info = try await CloudEngine.shared.shareInfo(code) } catch { errorText = error.localizedDescription }
            }
        }
    }
}

/// Opened from an invite link: confirm, then join.
struct JoinLiveSheet: View {
    let code: String
    @EnvironmentObject var router: Router
    @ObservedObject var account = AccountManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var info: (name: String, host: String, people: Int)?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 46)).foregroundStyle(.tint).padding(.top, 30)
                if !account.isSignedIn {
                    Text("Sign in with GitHub to join live sessions. It's free.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Sign in with GitHub") { account.signIn() }.buttonStyle(.borderedProminent)
                } else if let info {
                    Text(info.name).font(.title2.bold())
                    Text("@\(info.host) invited you to edit live · \(info.people) here now").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button {
                        LiveSession.shared.join(code)
                        router.sidebarOpen = true
                        dismiss()
                    } label: { Text("Join").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal, 30)
                    Text("The project's files are copied into a new folder in your projects while you edit together.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                } else if let errorText {
                    Text(errorText).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Live Session \(code)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: account.isSignedIn) {
                guard account.isSignedIn else { return }
                do { info = try await LiveSession.shared.info(code) } catch { errorText = error.localizedDescription }
            }
        }
    }
}

import SwiftUI

/// GitHub: clone (your own repos are free), and for Pro: clone anyone's, pull, commit & push, publish.
struct GitHubView: View {
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var router: Router
    @ObservedObject var account = AccountManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var repos: [GitHubRepo] = []
    @State private var page = 1
    @State private var more = false
    @State private var loadingRepos = false
    @State private var reposError: String?
    @State private var search = ""
    @State private var cloneText = ""
    @State private var working: String?
    @State private var errorText: String?
    @State private var proPrompt: String?
    @State private var link: GitLink?
    @State private var changes: [GitChange] = []
    @State private var checking = false
    @State private var showCommit = false
    @State private var showPublish = false

    /// The project GitHub actions apply to.
    private var project: URL? {
        let candidate = editor.lastProject ?? workspace.activeProject
            ?? editor.activeDocument.flatMap { workspace.projectFolder(containing: $0.url) }
        guard let c = candidate, workspace.isDirectory(c), !workspace.isBuiltInFolder(c),
              c.standardizedFileURL != workspace.root.standardizedFileURL else { return nil }
        return c
    }

    private var filtered: [GitHubRepo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? repos : repos.filter { $0.fullName.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !account.isSignedIn {
                    signInSection
                } else {
                    if let project { projectSection(project) }
                    cloneSection
                    reposSection
                }
            }
            .navigationTitle("GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search your repositories")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { reload() }
            .disabled(working != nil)
            .overlay {
                if let working {
                    VStack(spacing: 12) { ProgressView(); Text(working).font(.subheadline.weight(.medium)).multilineTextAlignment(.center) }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .alert("GitHub", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
            .alert("MangoIDE Pro", isPresented: Binding(get: { proPrompt != nil }, set: { if !$0 { proPrompt = nil } })) {
                if account.profile?.payments == true { Button("Get Pro") { account.buyPro() } }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text((proPrompt ?? "") + "\n\nCloning your own repos is always free.")
            }
            .sheet(isPresented: $showCommit) {
                if let project, let link {
                    GitCommitSheet(project: project, link: link, changes: changes, rescan: loadStatus) { sha in
                        showCommit = false
                        router.flash("Pushed \(sha.prefix(7))")
                        loadStatus()
                    }
                }
            }
            .sheet(isPresented: $showPublish) {
                if let project {
                    GitPublishSheet(project: project) { newLink in
                        showPublish = false
                        router.flash("Published \(newLink.fullName)")
                        loadStatus()
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: account.profile) { _ in if repos.isEmpty { reload() } }
    }

    // MARK: Sections

    private var signInSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Connect GitHub", systemImage: "arrow.triangle.branch").font(.headline)
                Text("Sign in with GitHub to clone your repositories into MangoIDE. Cloning your own repos is free.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button { account.signIn() } label: {
                HStack { if account.busy { ProgressView() }; Text("Sign in with GitHub").fontWeight(.semibold) }
            }
            .disabled(account.busy)
        }
    }

    private func projectSection(_ project: URL) -> some View {
        Section {
            if let link {
                LabeledContent("Repository", value: link.fullName)
                LabeledContent("Branch", value: link.branch)
                LabeledContent("Commit", value: String(link.commit.prefix(7)))
                Button {
                    guard account.isPro else { proPrompt = "Commit & Push is part of MangoIDE Pro."; return }
                    showCommit = true
                } label: {
                    HStack {
                        Label("Commit & Push", systemImage: "arrow.up.circle")
                        Spacer()
                        if checking { ProgressView() }
                        else if !changes.isEmpty {
                            Text("\(changes.count)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                        }
                        proLock
                    }
                }
                .disabled(account.isPro && changes.isEmpty)
                Button {
                    guard account.isPro else { proPrompt = "Pulling changes is part of MangoIDE Pro."; return }
                    pull(project)
                } label: {
                    HStack { Label("Pull from GitHub", systemImage: "arrow.down.circle"); Spacer(); proLock }
                }
                if let url = link.webURL { Link(destination: url) { Label("Open on GitHub", systemImage: "safari") } }
            } else {
                Button {
                    guard account.isPro else { proPrompt = "Publishing a project to GitHub is part of MangoIDE Pro."; return }
                    showPublish = true
                } label: {
                    HStack { Label("Publish to GitHub…", systemImage: "icloud.and.arrow.up"); Spacer(); proLock }
                }
            }
        } header: {
            Text("This project: \(project.lastPathComponent)")
        } footer: {
            if link != nil && changes.isEmpty && !checking { Text("No changes since the last commit.") }
            else if link == nil { Text("Make a new GitHub repository from this project.") }
        }
    }

    private var cloneSection: some View {
        Section {
            HStack {
                TextField("owner/name or GitHub link", text: $cloneText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(cloneFromText)
                Button("Clone", action: cloneFromText)
                    .disabled(cloneText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Clone")
        } footer: {
            Text("Your own repos clone free. Other people's repos need Pro. Clones go to \(workspace.projectsRoot?.lastPathComponent ?? "MangoIDE › Projects").")
        }
    }

    private var reposSection: some View {
        Section {
            if let reposError {
                Text(reposError).foregroundStyle(.secondary)
            } else if repos.isEmpty && !loadingRepos {
                Text("No repositories yet.").foregroundStyle(.secondary)
            }
            ForEach(filtered) { r in
                Button { clone(owner: r.owner, name: r.name, branch: nil, own: r.own) } label: { repoRow(r) }
                    .buttonStyle(.plain)
            }
            if loadingRepos {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if more && search.isEmpty {
                Button("Load More") { loadRepos(page: page + 1) }
            }
        } header: {
            Text("Your Repositories")
        }
    }

    private func repoRow(_ r: GitHubRepo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.isPrivate ? "lock.fill" : "book.closed")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.own ? r.name : r.fullName).font(.body.weight(.medium)).lineLimit(1)
                if let d = r.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if r.own {
                Text("Free").font(.caption2.bold()).foregroundStyle(.green)
            } else if !account.isPro {
                proBadge
            }
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var proLock: some View {
        if !account.isPro { proBadge }
    }

    private var proBadge: some View {
        Text("PRO").font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(.orange)
    }

    // MARK: Actions

    private func reload() {
        guard account.isSignedIn else { return }
        loadRepos(page: 1)
        loadStatus()
    }

    private func loadRepos(page p: Int) {
        loadingRepos = true
        reposError = nil
        GitHub.fetchJSON(GitHubRepoList.self, GitHub.request("github/repos", query: ["page": "\(p)"])) { r in
            loadingRepos = false
            switch r {
            case .success(let list):
                repos = p == 1 ? list.repos : repos + list.repos
                page = p
                more = list.more
            case .failure(let e):
                reposError = e.localizedDescription
            }
        }
    }

    private func loadStatus() {
        guard let project else { link = nil; changes = []; return }
        checking = true
        GitHub.status(project) { l, c in
            checking = false
            link = l
            changes = c
        }
    }

    private func handle(_ error: Error) {
        if case .needsPro(let m)? = error as? GitHubError { proPrompt = m } else { errorText = error.localizedDescription }
    }

    private func cloneFromText() {
        guard let parsed = GitHub.parseRepo(cloneText) else {
            errorText = "Type a repo as owner/name, like apple/swift, or paste its GitHub link."
            return
        }
        let own = parsed.owner.lowercased() == account.profile?.login.lowercased()
        clone(owner: parsed.owner, name: parsed.name, branch: parsed.branch, own: own)
    }

    private func clone(owner: String, name: String, branch: String?, own: Bool) {
        guard own || account.isPro else {
            proPrompt = "Cloning repositories you don't own is part of MangoIDE Pro."
            return
        }
        let parent = workspace.projectsRoot ?? workspace.projectsFolder
        working = "Cloning \(owner)/\(name)…"
        GitHub.clone(owner: owner, name: name, branch: branch, into: parent) { r in
            working = nil
            switch r {
            case .success(let dest):
                cloneText = ""
                workspace.refresh()
                openProject(dest)
                router.flash("Cloned \(name)")
                dismiss()
            case .failure(let e):
                handle(e)
            }
        }
    }

    private func openProject(_ dir: URL) {
        if let root = workspace.projectsRoot, workspace.isInside(dir, root) { workspace.openProject(dir) }
        editor.lastProject = dir
        let readme = ["README.md", "readme.md", "Readme.md", "README"].map { dir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        if let readme { editor.open(readme) }
        router.revealRequest = dir
        router.sidebarOpen = true
    }

    private func pull(_ project: URL) {
        working = "Pulling from GitHub…"
        GitHub.pull(project) { r in
            working = nil
            switch r {
            case .success(let result):
                if result.upToDate { router.flash("Already up to date"); loadStatus(); return }
                let touched = Set((result.updated + result.deleted).map { project.appendingPathComponent($0).standardizedFileURL.path })
                for doc in editor.documents.values where !doc.isDirty && touched.contains(doc.url.standardizedFileURL.path) {
                    if result.deleted.contains(where: { project.appendingPathComponent($0).standardizedFileURL.path == doc.url.standardizedFileURL.path }) {
                        editor.fileDeleted(doc.url)
                    } else {
                        doc.load()
                    }
                }
                workspace.refresh()
                loadStatus()
                if result.conflicts.isEmpty {
                    router.flash("Pulled \(result.commit.prefix(7)): \(result.updated.count) updated, \(result.deleted.count) removed")
                } else {
                    errorText = "Pulled, but you and GitHub both changed:\n\n" + result.conflicts.prefix(12).joined(separator: "\n")
                        + (result.conflicts.count > 12 ? "\n…and \(result.conflicts.count - 12) more" : "")
                        + "\n\nYour version was kept. GitHub's version is saved next to each one as \".remote\" so you can compare and delete it."
                }
            case .failure(let e):
                handle(e)
            }
        }
    }
}

// MARK: - Commit & Push

struct GitCommitSheet: View {
    let project: URL
    let link: GitLink
    let changes: [GitChange]
    let rescan: () -> Void
    let onPushed: (String) -> Void

    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var excluded: Set<String> = []
    @State private var pushing = false
    @State private var errorText: String?

    private var chosen: [GitChange] { changes.filter { !excluded.contains($0.path) } }
    private var unsaved: [EditorDocument] {
        editor.documents.values.filter { $0.isDirty && workspace.isInside($0.url, project) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !unsaved.isEmpty {
                    Section {
                        Text("\(unsaved.count) open file\(unsaved.count == 1 ? " has" : "s have") unsaved edits that won't be pushed.")
                        Button("Save Them First") {
                            unsaved.forEach { $0.saveNow() }
                            rescan()
                        }
                    }
                }
                Section("Message") {
                    TextField("What did you change?", text: $message, axis: .vertical)
                        .lineLimit(1...5)
                }
                Section {
                    if changes.isEmpty { Text("No changes.").foregroundStyle(.secondary) }
                    ForEach(changes) { c in
                        Button {
                            if excluded.contains(c.path) { excluded.remove(c.path) } else { excluded.insert(c.path) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: excluded.contains(c.path) ? "circle" : "checkmark.circle.fill")
                                    .foregroundStyle(excluded.contains(c.path) ? Color.secondary : Color.accentColor)
                                Text(c.kind.rawValue)
                                    .font(.caption.monospaced().bold())
                                    .foregroundStyle(c.kind == .added ? Color.green : c.kind == .deleted ? Color.red : Color.orange)
                                    .frame(width: 16)
                                Text(c.path).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                                    .strikethrough(c.kind == .deleted)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("\(chosen.count) of \(changes.count) changes")
                        Spacer()
                        Button(excluded.isEmpty ? "None" : "All") {
                            excluded = excluded.isEmpty ? Set(changes.map(\.path)) : []
                        }
                        .font(.caption)
                    }
                } footer: {
                    Text("Pushes to \(link.fullName) on \(link.branch).")
                }
            }
            .navigationTitle("Commit & Push")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if pushing { ProgressView() } else {
                        Button("Push", action: push)
                            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chosen.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(pushing)
            .alert("Couldn't push", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func push() {
        pushing = true
        GitHub.push(project, changes: chosen, message: message.trimmingCharacters(in: .whitespacesAndNewlines)) { r in
            pushing = false
            switch r {
            case .success(let sha): onPushed(sha)
            case .failure(let e): errorText = e.localizedDescription
            }
        }
    }
}

// MARK: - Publish

struct GitPublishSheet: View {
    let project: URL
    let onDone: (GitLink) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isPrivate = true
    @State private var about = ""
    @State private var working = false
    @State private var errorText: String?

    private static func clean(_ s: String) -> String {
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = String(s.unicodeScalars.map { ok.contains($0) && $0.isASCII ? Character($0) : "-" })
        return String(mapped.prefix(100))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Repository name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Description (optional)", text: $about)
                    Toggle("Private", isOn: $isPrivate)
                } footer: {
                    Text("Makes a new repository on your GitHub account and pushes every file in \(project.lastPathComponent).")
                }
            }
            .navigationTitle("Publish to GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Publish") {
                            working = true
                            GitHub.publish(project, name: Self.clean(name), isPrivate: isPrivate, description: about) { r in
                                working = false
                                switch r {
                                case .success(let link): onDone(link)
                                case .failure(let e): errorText = e.localizedDescription
                                }
                            }
                        }
                        .disabled(Self.clean(name).isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(working)
            .onAppear { if name.isEmpty { name = Self.clean(project.lastPathComponent) } }
            .alert("Couldn't publish", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }
}

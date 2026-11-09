import SwiftUI

/// Settings › Cloud Sync & Backup.
struct CloudView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var editor: EditorState
    @ObservedObject var account = AccountManager.shared
    @ObservedObject var cloud = CloudSync.shared

    @State private var list: CloudList?
    @State private var localNames: Set<String> = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var confirmDelete: String?
    @State private var errorText: String?

    var body: some View {
        List {
            if !account.isSignedIn {
                Section {
                    Text("Sign in with GitHub in Settings › Account to use Cloud Sync & Backup.").foregroundStyle(.secondary)
                    Button("Sign in with GitHub") { account.signIn() }
                }
            } else {
                syncSection
                if let list { usageSection(list) }
                projectsSection
            }
        }
        .navigationTitle("Cloud Sync & Backup")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: cloud.syncing) { busy in if !busy { Task { await load() } } }
        .confirmationDialog("Delete \(confirmDelete ?? "") from the cloud?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete from Cloud", role: .destructive) {
                guard let name = confirmDelete else { return }
                Task {
                    do { try await cloud.delete(name); await load() } catch { errorText = error.localizedDescription }
                }
            }
        } message: {
            Text("This removes it and all its backups from the cloud and stops syncing it. Files on this device are not touched.")
        }
        .alert("Cloud", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: Sections

    private var syncSection: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.cloudSync }, set: { on in
                if on && !account.isPro { errorText = "Cloud Sync & Backup is part of MangoIDE Pro."; return }
                settings.cloudSync = on
                if on { cloud.syncNow() }
            })) {
                HStack {
                    Label("Sync Projects", systemImage: "icloud")
                    if !account.isPro {
                        Text("PRO").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
                    }
                }
            }
            if settings.cloudSync {
                HStack {
                    if cloud.syncing {
                        ProgressView()
                        Text(cloud.progress.isEmpty ? "Syncing…" : cloud.progress).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: cloud.lastError == nil ? "checkmark.icloud" : "exclamationmark.icloud")
                            .foregroundStyle(cloud.lastError == nil ? Color.green : Color.orange)
                        Text(cloud.lastSync.map { "Last synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sync Now") { cloud.syncNow() }.disabled(cloud.syncing)
                }
                if let e = cloud.lastError {
                    Text(e).font(.footnote).foregroundStyle(.orange)
                }
            }
        } footer: {
            Text("Keeps every project in \(workspace.projectsRoot?.lastPathComponent ?? "MangoIDE › Projects") the same on all your devices. Syncs when you open or leave the app and every 5 minutes. If a file changed on two devices, both versions are kept. Unsaved edits sync after you save.")
        }
    }

    private func usageSection(_ list: CloudList) -> some View {
        Section("Storage") {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(list.used, list.quota), total: max(list.quota, 1))
                Text("\(bytes(list.used)) of \(bytes(list.quota)) used").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var projectsSection: some View {
        Section {
            if loading && list == nil { HStack { Spacer(); ProgressView(); Spacer() } }
            if let loadError { Text(loadError).foregroundStyle(.secondary) }
            ForEach(rows, id: \.self) { name in
                let p = list?.projects.first { $0.name == name }
                NavigationLink {
                    CloudProjectView(name: name, project: p, isLocal: localNames.contains(name)) { confirmDelete = name }
                } label: {
                    projectRow(name, p)
                }
            }
        } header: {
            Text("Projects")
        } footer: {
            Text("Tap a project to see its backups, restore an older version, or stop syncing it.")
        }
    }

    private var rows: [String] {
        Array(localNames.union(list?.projects.map(\.name) ?? [])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func projectRow(_ name: String, _ p: CloudProject?) -> some View {
        let local = localNames.contains(name)
        let off = cloud.excluded.contains(name)
        return HStack(spacing: 10) {
            Image(systemName: !local ? "icloud.and.arrow.down" : off ? "icloud.slash" : p == nil ? "icloud.and.arrow.up" : "checkmark.icloud")
                .foregroundStyle(off ? Color.secondary : Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(!local ? "Only in the cloud" : off ? "Not syncing" : p.map { "\($0.files) files · \(bytes($0.size)) · \($0.device ?? "")" } ?? "Not uploaded yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bytes(_ n: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    private func load() async {
        guard account.isSignedIn else { return }
        loading = true
        let parent = cloud.parent
        localNames = Set(await Task.detached { CloudSync.localProjects(in: parent).keys }.value)
        do { list = try await CloudEngine.shared.list(); loadError = nil }
        catch { loadError = error.localizedDescription }
        loading = false
    }
}

/// One project: sync on/off, backups, restore, delete from cloud.
struct CloudProjectView: View {
    let name: String
    let project: CloudProject?
    let isLocal: Bool
    let onDelete: () -> Void

    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var router: Router
    @ObservedObject var cloud = CloudSync.shared
    @ObservedObject var account = AccountManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var backups: [CloudBackup] = []
    @State private var loading = false
    @State private var working: String?
    @State private var errorText: String?
    @State private var confirmRestore: CloudBackup?

    var body: some View {
        List {
            Section {
                if isLocal {
                    Toggle("Sync This Project", isOn: Binding(get: { !cloud.excluded.contains(name) }, set: { on in
                        cloud.setExcluded(name, !on)
                        if on { cloud.syncNow() }
                    }))
                    .disabled(!account.isPro)
                } else {
                    Button { cloud.download(name); dismiss() } label: { Label("Download to This Device", systemImage: "icloud.and.arrow.down") }
                        .disabled(!account.isPro || cloud.syncing)
                }
                if let project {
                    LabeledContent("Files", value: "\(project.files)")
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(project.size), countStyle: .file))
                    LabeledContent("Last synced", value: CloudSync.shortDate(project.updatedAt))
                }
            }
            if project != nil {
                Section {
                    if loading { HStack { Spacer(); ProgressView(); Spacer() } }
                    ForEach(backups) { b in
                        Button { confirmRestore = b } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(CloudSync.shortDate(b.createdAt))
                                    Text("\(b.files) files · \(ByteCountFormatter.string(fromByteCount: Int64(b.size), countStyle: .file)) · \(b.device ?? "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Backups")
                } footer: {
                    Text("The last 20 syncs are kept. Restoring makes a separate copy next to your projects, so nothing current is replaced.")
                }
                Section {
                    Button("Delete from Cloud", role: .destructive, action: onDelete)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working != nil)
        .overlay {
            if let working {
                VStack(spacing: 12) { ProgressView(); Text(working).font(.subheadline.weight(.medium)) }
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .task {
            guard project != nil else { return }
            loading = true
            do { backups = try await CloudEngine.shared.history(name) } catch { errorText = error.localizedDescription }
            loading = false
        }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }), titleVisibility: .visible) {
            Button("Restore as a Copy") { if let b = confirmRestore { restore(b) } }
        } message: {
            Text("It will be downloaded into a new folder, \"\(name) (backup …)\".")
        }
        .alert("Cloud", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func restore(_ b: CloudBackup) {
        working = "Restoring…"
        Task {
            do {
                let url = try await cloud.restore(name, backup: b)
                working = nil
                editor.lastProject = url
                router.revealRequest = url
                router.flash("Restored to \(url.lastPathComponent)")
            } catch {
                working = nil
                errorText = error.localizedDescription
            }
        }
    }
}

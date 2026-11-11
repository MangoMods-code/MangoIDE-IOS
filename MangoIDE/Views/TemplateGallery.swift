import SwiftUI
import UIKit

/// Browse ready-made projects by language and category, preview one, and create it.
struct TemplateGallery: View {
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [ProjectTemplate] = []
    @State private var search = ""
    @State private var language = ""          // "" = every language
    @State private var loaded = false

    private var languages: [String] {
        var seen: [String] = []
        for t in templates where !seen.contains(t.language) { seen.append(t.language) }
        return seen
    }

    private var shown: [ProjectTemplate] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return templates.filter { t in
            (language.isEmpty || t.language == language) &&
            (q.isEmpty || t.name.lowercased().contains(q) || t.summary.lowercased().contains(q) || t.category.lowercased().contains(q))
        }
    }

    /// Categories in the order they first appear in the packs.
    private var groups: [(String, [ProjectTemplate])] {
        var order: [String] = []
        var map: [String: [ProjectTemplate]] = [:]
        for t in shown {
            if map[t.category] == nil { order.append(t.category) }
            map[t.category, default: []].append(t)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if languages.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("All", "")
                            ForEach(languages, id: \.self) { chip(TemplateLibrary.languageName($0), $0) }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                if !loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                } else if shown.isEmpty {
                    Text("No templates match.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.0) { category, list in
                    Section(category) {
                        ForEach(list) { t in
                            NavigationLink { TemplateDetail(template: t) } label: { TemplateRow(template: t) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(templates.count) templates")
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                guard !loaded else { return }
                templates = await Task.detached(priority: .userInitiated) { TemplateLibrary.all }.value
                loaded = true
            }
        }
    }

    private func chip(_ title: String, _ id: String) -> some View {
        Button { withAnimation(Anim.quick) { language = id } } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(language == id ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
                .foregroundStyle(language == id ? Color.white : Color.primary)
        }
        .buttonStyle(PressableStyle(scale: 0.94))
    }
}

/// Colored icon tile for a template; the color comes from its category so groups look related.
struct TemplateIcon: View {
    let template: ProjectTemplate
    var size: CGFloat = 36

    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .red, .mint, .brown]
    private var color: Color {
        let sum = template.category.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return TemplateIcon.palette[sum % TemplateIcon.palette.count]
    }
    private var symbol: String { UIImage(systemName: template.icon) == nil ? "doc.fill" : template.icon }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

private struct TemplateRow: View {
    let template: ProjectTemplate
    var body: some View {
        HStack(spacing: 12) {
            TemplateIcon(template: template)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name).font(.body.weight(.medium))
                Text(template.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One template: what it is, its files, a peek at the code, and Create.
struct TemplateDetail: View {
    let template: ProjectTemplate
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var router: Router
    @EnvironmentObject var settings: AppSettings
    @State private var name = ""
    @State private var inMyFolder = true
    @State private var error: String?

    private var preview: String {
        let code = template.files[template.entry] ?? ""
        let lines = code.components(separatedBy: "\n")
        return lines.prefix(40).joined(separator: "\n") + (lines.count > 40 ? "\n…" : "")
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    TemplateIcon(template: template, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.name).font(.title3.bold())
                        Text("\(TemplateLibrary.languageName(template.language)) · \(template.category)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(template.summary).font(.subheadline)
            }
            Section {
                TextField("Project name", text: $name).autocorrectionDisabled()
                if let pr = workspace.projectsRoot {
                    Picker("Create In", selection: $inMyFolder) {
                        Text(pr.lastPathComponent).tag(true)
                        Text("MangoIDE › Projects").tag(false)
                    }
                }
                Button(action: create) {
                    Label("Create Project", systemImage: "plus.circle.fill").fontWeight(.semibold)
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } header: { Text("Name") }
            Section("Files (\(template.files.count))") {
                ForEach(template.sortedPaths, id: \.self) { path in
                    HStack {
                        let icon = FileIcons.icon(for: URL(fileURLWithPath: path), isDirectory: false, open: false)
                        Image(systemName: icon.0).foregroundStyle(icon.1).frame(width: 22)
                        Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if path == template.entry { Text("opens first").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Preview of \(template.entry)") {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create", action: create).bold().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { if name.isEmpty { name = template.name.components(separatedBy: " (").first ?? template.name } }
    }

    private func create() {
        let useMine = inMyFolder && workspace.projectsRoot != nil
        let parent = useMine ? workspace.projectsRoot! : workspace.projectsFolder
        do {
            let made = try TemplateLibrary.create(template, named: name, in: parent)
            workspace.refresh()
            if useMine { workspace.openProject(made.folder) }
            editor.lastProject = made.folder
            editor.open(made.entry)
            router.revealRequest = made.entry
            settings.haptic()
            router.sheet = nil
            router.flash("Created \(made.folder.lastPathComponent)")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

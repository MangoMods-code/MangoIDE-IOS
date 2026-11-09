import SwiftUI

// Problems list, Find in Files, Outline and Go to Definition.

extension Router {
    /// Opens a file and jumps to a line.
    func reveal(_ url: URL, line: Int) {
        guard let editor else { return }
        if editor.activeDocument?.url.standardizedFileURL != url.standardizedFileURL { editor.open(url) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editor.goToLine(line) }
    }
}

/// The current project: the open project, or the folder the active file belongs to.
func currentProjectFolder(_ editor: EditorState, _ workspace: Workspace) -> URL? {
    let candidate = editor.lastProject ?? workspace.activeProject
        ?? editor.activeDocument.flatMap { workspace.projectFolder(containing: $0.url) }
    guard let c = candidate, workspace.isDirectory(c), !workspace.isBuiltInFolder(c),
          c.standardizedFileURL != workspace.root.standardizedFileURL else { return nil }
    return c
}

// MARK: - Problems

struct ProblemsBadge: View {
    @ObservedObject var doc: EditorDocument
    @EnvironmentObject var router: Router
    var body: some View {
        let errors = doc.diagnostics.filter { $0.severity == .error }.count
        let warnings = doc.diagnostics.count - errors
        if !doc.diagnostics.isEmpty {
            Button { router.show(.problems) } label: {
                HStack(spacing: 6) {
                    if errors > 0 { Label("\(errors)", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                    if warnings > 0 { Label("\(warnings)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
        }
    }
}

struct ProblemsSheet: View {
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var router: Router
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var docs: [EditorDocument] {
        editor.documents.values.filter { !$0.diagnostics.isEmpty }.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if docs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
                        Text("No problems in open files.").foregroundStyle(.secondary)
                        if !settings.checkErrors { Text("Error checking is off in Settings › Editor.").font(.footnote).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                ForEach(docs) { doc in
                    Section(doc.name) {
                        ForEach(doc.diagnostics) { d in
                            Button {
                                dismiss()
                                router.reveal(doc.url, line: d.line)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: d.severity == .error ? "xmark.octagon.fill" : d.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                        .foregroundStyle(d.severity == .error ? Color.red : d.severity == .warning ? Color.orange : Color.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(d.message).font(.callout).foregroundStyle(.primary)
                                        Text("Line \(d.line), column \(d.col)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Problems")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Find in Files

struct FindInFilesView: View {
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) private var dismiss

    struct Hit: Identifiable, Hashable {
        let id = UUID()
        let url: URL
        let path: String
        let line: Int
        let preview: String
        let matchRange: Range<String.Index>?
    }

    @State private var query = ""
    @State private var replacement = ""
    @State private var showReplace = false
    @State private var matchCase = false
    @State private var wholeWord = false
    @State private var useRegex = false
    @State private var hits: [Hit] = []
    @State private var searching = false
    @State private var truncated = false
    @State private var errorText: String?
    @State private var confirmReplace = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var root: URL { currentProjectFolder(editor, workspace) ?? workspace.projectsRoot ?? workspace.projectsFolder }
    private var grouped: [(String, [Hit])] {
        var order: [String] = []
        var map: [String: [Hit]] = [:]
        for h in hits { if map[h.path] == nil { order.append(h.path) }; map[h.path, default: []].append(h) }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search in \(root.lastPathComponent)", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced())
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit(search)
                    if showReplace {
                        TextField("Replace with", text: $replacement)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.body.monospaced())
                    }
                    HStack(spacing: 8) {
                        toggle("Aa", $matchCase)
                        toggle("ab|", $wholeWord)
                        toggle(".*", $useRegex)
                        Spacer()
                        Button(showReplace ? "Hide Replace" : "Replace") { showReplace.toggle() }.font(.footnote)
                    }
                } footer: {
                    if !hits.isEmpty {
                        Text("\(hits.count)\(truncated ? "+" : "") results in \(grouped.count) files")
                    }
                }
                if showReplace && !hits.isEmpty {
                    Section {
                        Button("Replace All \(hits.count) in \(grouped.count) Files", role: .destructive) { confirmReplace = true }
                    }
                }
                if searching { HStack { Spacer(); ProgressView(); Spacer() } }
                ForEach(grouped, id: \.0) { path, list in
                    Section(path) {
                        ForEach(list) { h in
                            Button {
                                dismiss()
                                router.reveal(h.url, line: h.line)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(h.line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 30, alignment: .trailing)
                                    Text(highlighted(h)).font(.callout.monospaced()).lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Find in Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Search", action: search).disabled(query.isEmpty) }
            }
            .onAppear { focused = true; if let sel = selectedWord(), query.isEmpty { query = sel } }
            .onChange(of: matchCase) { _ in if !hits.isEmpty { search() } }
            .onChange(of: wholeWord) { _ in if !hits.isEmpty { search() } }
            .onChange(of: useRegex) { _ in if !hits.isEmpty { search() } }
            .alert("Find in Files", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
            .confirmationDialog("Replace \(hits.count) matches in \(grouped.count) files?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace All", role: .destructive, action: replaceAll)
            } message: { Text("Open files can be undone with Discard; closed files are saved right away.") }
        }
    }

    private func toggle(_ title: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(title).font(.footnote.monospaced().bold())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(on.wrappedValue ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func selectedWord() -> String? {
        guard let tv = editor.activeTextView, tv.selectedRange.length > 0, tv.selectedRange.length < 200 else { return nil }
        return (tv.textStorage.string as NSString).substring(with: tv.selectedRange)
    }

    private func highlighted(_ h: Hit) -> AttributedString {
        var a = AttributedString(h.preview)
        if let r = h.matchRange, let lower = AttributedString.Index(r.lowerBound, within: a), let upper = AttributedString.Index(r.upperBound, within: a) {
            a[lower..<upper].swiftUI.backgroundColor = Color.yellow.opacity(0.45)
            a[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return a
    }

    private func makeRegex() -> NSRegularExpression? {
        var pattern = useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b" + pattern + "\\b" }
        return try? NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
    }

    private func search() {
        guard !query.isEmpty else { return }
        guard let regex = makeRegex() else { errorText = "That regular expression isn't valid."; return }
        searchTask?.cancel()
        searching = true
        hits = []
        let root = self.root
        // Unsaved edits in open files are searched too.
        let open = Dictionary(editor.documents.values.filter { !$0.isBinary }.map { ($0.url.standardizedFileURL.path, $0.text) }, uniquingKeysWith: { a, _ in a })
        searchTask = Task {
            let (found, cut) = await Task.detached(priority: .userInitiated) { () -> ([Hit], Bool) in
                var out: [Hit] = []
                for (path, url) in ProjectFiles.textFiles(in: root) {
                    if Task.isCancelled { break }
                    let text = open[url.standardizedFileURL.path] ?? (try? String(contentsOf: url, encoding: .utf8))
                    guard let text else { continue }
                    let ns = text as NSString
                    var lineNo = 0
                    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { sub, _, _, stop in
                        lineNo += 1
                        guard let sub, let m = regex.firstMatch(in: sub, range: NSRange(location: 0, length: (sub as NSString).length)) else { return }
                        let trimmedStart = sub.prefix { $0 == " " || $0 == "\t" }.utf16.count
                        let shown = String(sub.dropFirst(sub.prefix { $0 == " " || $0 == "\t" }.count).prefix(200))
                        let loc = m.range.location - trimmedStart
                        let range = loc >= 0 ? Range(NSRange(location: loc, length: m.range.length), in: shown) : nil
                        out.append(Hit(url: url, path: path, line: lineNo, preview: shown, matchRange: range))
                        if out.count >= 2000 { stop.pointee = true }
                    }
                    if out.count >= 2000 { return (out, true) }
                }
                return (out, false)
            }.value
            guard !Task.isCancelled else { return }
            hits = found
            truncated = cut
            searching = false
        }
    }

    private func replaceAll() {
        guard let regex = makeRegex() else { return }
        let template = useRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        let files = Set(hits.map(\.url))
        var changedFiles = 0
        for url in files {
            if let doc = editor.documents.values.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }), !doc.isBinary {
                let ns = doc.text as NSString
                let out = regex.stringByReplacingMatches(in: doc.text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
                if out != doc.text { doc.replaceAll(out); changedFiles += 1 }
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                let out = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
                if out != text, (try? out.write(to: url, atomically: true, encoding: .utf8)) != nil { changedFiles += 1 }
            }
        }
        router.flash("Replaced in \(changedFiles) file\(changedFiles == 1 ? "" : "s")")
        search()
    }
}

// MARK: - Outline (symbols in this file)

struct OutlineSheet: View {
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var symbols: [CodeSymbol] = []
    @State private var filter = ""

    private var shown: [CodeSymbol] {
        filter.isEmpty ? symbols : symbols.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        NavigationStack {
            List {
                if symbols.isEmpty { Text("No functions, classes or headings found in this file.").foregroundStyle(.secondary) }
                ForEach(shown) { s in
                    Button {
                        dismiss()
                        if let doc = editor.activeDocument { router.reveal(doc.url, line: s.line) }
                    } label: {
                        HStack {
                            Image(systemName: s.icon).foregroundStyle(.tint)
                            Text(s.name).font(.body.monospaced())
                            Spacer()
                            Text("\(s.line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Jump to…")
            .navigationTitle(editor.activeDocument?.name ?? "Outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                guard let doc = editor.activeDocument else { return }
                let text = doc.text, url = doc.url
                let lang = ExtensionManager.shared.languageID(for: url)
                symbols = await Task.detached { Symbols.scan(text, languageID: lang, url: url) }.value
            }
        }
    }
}

// MARK: - Go to Definition results

struct DefinitionsSheet: View {
    let name: String
    let results: [CodeSymbol]
    @EnvironmentObject var router: Router
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(results) { s in
                Button {
                    dismiss()
                    if let url = s.url { router.reveal(url, line: s.line) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(s.name, systemImage: s.icon).font(.body.monospaced())
                        Text("\(s.url.map { workspace.displayPath($0) } ?? "") : \(s.line)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Definitions of \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

enum CodeActions {
    /// The identifier under (or just before) the cursor.
    static func wordAtCursor(_ editor: EditorState) -> String? {
        guard let tv = editor.activeTextView else { return nil }
        let ns = tv.textStorage.string as NSString
        let sel = tv.selectedRange
        if sel.length > 0 && sel.length < 100 { return ns.substring(with: sel).trimmingCharacters(in: .whitespacesAndNewlines) }
        var start = sel.location, end = sel.location
        while start > 0 && Completion.isWordChar(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length && Completion.isWordChar(ns.character(at: end)) { end += 1 }
        guard end > start else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    static func goToDefinition(editor: EditorState, workspace: Workspace, router: Router) {
        guard let doc = editor.activeDocument else { return }
        guard let name = wordAtCursor(editor), !name.isEmpty else { router.flash("Put the cursor on a name first"); return }
        let project = currentProjectFolder(editor, workspace)
        let lang = ExtensionManager.shared.languageID(for: doc.url)
        let current = (text: doc.text, url: doc.url, language: lang)
        router.busy = "Looking for \(name)…"
        Task { @MainActor in
            let found = await Symbols.findDefinition(name, in: project, current: current)
            router.busy = nil
            if found.isEmpty { router.flash("No definition of \(name) found") }
            else if found.count == 1, let s = found.first, let url = s.url { router.reveal(url, line: s.line) }
            else { router.show(.definitions(name, found)) }
        }
    }

    static func format(editor: EditorState, router: Router) {
        guard let doc = editor.activeDocument, !doc.isBinary else { return }
        let text = doc.text, name = doc.name
        router.busy = "Formatting…"
        Task { @MainActor in
            do {
                let out = try await CodeFormatter.format(text, fileName: name)
                router.busy = nil
                guard doc.text == text else { router.flash("File changed while formatting; try again"); return }
                if out == text { router.flash("Already formatted") } else { doc.replaceAll(out); router.flash("Formatted") }
            } catch {
                router.busy = nil
                router.errorMessage = error.localizedDescription
            }
        }
    }
}

import SwiftUI

/// The agent chat panel.
struct AgentView: View {
    @EnvironmentObject var agent: AgentSession
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var editor: EditorState
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) var dismiss
    @State private var input = ""
    @FocusState private var focused: Bool

    private var projectName: String {
        (agent.project ?? agent.currentProject())?.lastPathComponent ?? "No project open"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if agent.items.isEmpty { intro }
                            ForEach(agent.items) { item in row(item).id(item.id) }
                            if let a = agent.approval { approvalCard(a).id("approval") }
                            if agent.isWorking && agent.approval == nil {
                                HStack(spacing: 8) { ProgressView(); Text("Working…").foregroundStyle(.secondary) }
                                    .font(.subheadline).id("working")
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: agent.items.count) { _ in
                        if let id = agent.items.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                    .onChange(of: agent.approval?.id) { _ in
                        withAnimation { proxy.scrollTo("approval", anchor: .bottom) }
                    }
                }
                Divider()
                inputBar
            }
            .navigationTitle(projectName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(projectName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(String(format: "$%.3f this chat", agent.cost)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .primaryAction) { menu }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Coding agent", systemImage: "sparkles").font(.headline)
            Text("Ask it to change, create or fix things in **\(projectName)**. It reads your files, edits them, and can run code to test. Deletes and overwrites ask you first, and you can undo everything it did.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Try: “Add a function that…”, “Fix the error in main.py”, “Remember that I use tabs”.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func row(_ item: AgentSession.Item) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .padding(10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }
        case .assistant:
            Text((try? AttributedString(markdown: item.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(item.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Button {
                if let p = item.path, let root = agent.project {
                    let u = root.appendingPathComponent(p)
                    if FileManager.default.fileExists(atPath: u.path) && !workspace.isDirectory(u) { editor.open(u) }
                }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: item.failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(item.failed ? Color.orange : Color.green)
                    Text(item.text).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
        case .error:
            Label(item.text, systemImage: "xmark.octagon").font(.subheadline).foregroundStyle(.red)
        case .info:
            Text(item.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private func approvalCard(_ a: AgentSession.Approval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(a.title, systemImage: "hand.raised").font(.subheadline.weight(.semibold))
            if !a.detail.isEmpty {
                ScrollView {
                    Text(a.detail).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Allow") { a.resolve(true) }.buttonStyle(.borderedProminent)
                Button("Don't Allow", role: .destructive) { a.resolve(false) }.buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask the agent…", text: $input, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(10)
                .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 18))
            if agent.isWorking {
                Button { agent.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 32)) }
                    .tint(.red)
            } else {
                Button {
                    let t = input
                    input = ""
                    agent.send(t)
                } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
    }

    private var menu: some View {
        Menu {
            Picker("Model", selection: $settings.agentModel) {
                ForEach(AgentSession.models, id: \.id) { m in Text(m.name).tag(m.id) }
            }
            Divider()
            if agent.changedCount > 0 {
                Button(role: .destructive) { agent.undoChanges() } label: {
                    Label("Undo All Changes (\(agent.changedCount) file\(agent.changedCount == 1 ? "" : "s"))", systemImage: "arrow.uturn.backward")
                }
            }
            if let root = agent.project ?? agent.currentProject() {
                Button {
                    let notes = root.appendingPathComponent(".mango/agent-notes.md")
                    if !FileManager.default.fileExists(atPath: notes.path) {
                        try? FileManager.default.createDirectory(at: notes.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? "# Agent notes\n\n## Overview\n\n## Remembered\n".write(to: notes, atomically: true, encoding: .utf8)
                    }
                    editor.open(notes)
                    dismiss()
                } label: { Label("Open Memory", systemImage: "brain") }
            }
            Button { agent.newChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }
        } label: { Image(systemName: "ellipsis.circle") }
    }
}

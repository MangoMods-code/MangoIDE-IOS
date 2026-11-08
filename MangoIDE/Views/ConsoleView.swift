import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject var console: ConsoleModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: Router
    @State private var showInput = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Console", systemImage: "terminal").font(.subheadline.weight(.semibold))
                if console.isRunning { ProgressView().scaleEffect(0.7) }
                Spacer()
                Button { showInput.toggle() } label: {
                    Image(systemName: "keyboard").foregroundStyle(showInput || !console.stdin.isEmpty ? Color.accentColor : Color.secondary)
                }
                Button {
                    UIPasteboard.general.string = console.plainText
                    router.flash("Output copied")
                } label: { Image(systemName: "doc.on.doc") }
                Button { console.clear() } label: { Image(systemName: "trash") }
                Menu {
                    Button("Small") { settings.consoleHeight = 0.22 }
                    Button("Medium") { settings.consoleHeight = 0.33 }
                    Button("Large") { settings.consoleHeight = 0.5 }
                } label: { Image(systemName: "arrow.up.and.down") }
                Button { console.isVisible = false } label: { Image(systemName: "xmark") }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.bar)
            if showInput {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Program input (stdin), one value per line").font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: $console.stdin)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .padding(8)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if console.lines.isEmpty {
                            Text("Tap ▶ to run the open file. Output shows up here.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(console.lines) { line in
                            Text(line.text)
                                .foregroundStyle(color(line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .font(.system(size: CGFloat(settings.consoleFontSize), design: .monospaced))
                    .padding(10)
                }
                .onChange(of: console.lines.count) { _ in
                    if let last = console.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func color(_ k: ConsoleLine.Kind) -> Color {
        switch k {
        case .out: return .primary
        case .err: return .red
        case .info: return .secondary
        case .success: return .green
        }
    }
}

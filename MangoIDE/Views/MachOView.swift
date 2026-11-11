import SwiftUI

/// Info about a compiled binary (.dylib and friends): what it's built for and what it links against.
struct MachOView: View {
    let url: URL
    @State private var slices: [MachOSlice]?
    @State private var loaded = false
    @State private var showHex = false

    var body: some View {
        Group {
            if showHex || (loaded && slices == nil) {
                HexView(url: url)
            } else if let slices {
                List {
                    ForEach(slices) { s in
                        Section {
                            row("Kind", s.fileType)
                            row("Architecture", "\(s.arch) (\(s.bits)-bit)")
                            if let p = s.platform { row("Built for", p + (s.minOS.map { " \($0) or later" } ?? "")) }
                            if let sdk = s.sdk { row("SDK", sdk) }
                            row("Size", ByteCountFormatter.string(fromByteCount: Int64(s.size), countStyle: .file))
                            if let n = s.installName { row("Install name", n) }
                            row("Code signed", s.signed ? "Yes" : "No")
                            if let e = s.encrypted { row("Encrypted (App Store DRM)", e ? "Yes" : "No") }
                            if let u = s.uuid { row("UUID", u) }
                        } header: { Text(slices.count > 1 ? "\(s.arch) slice" : "Binary") }

                        if !s.libraries.isEmpty {
                            Section("Links against (\(s.libraries.count))") {
                                ForEach(s.libraries) { lib in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text((lib.name as NSString).lastPathComponent).font(.callout.monospaced())
                                        Text(lib.name + (lib.kind.isEmpty ? "" : " · \(lib.kind)") + " · v\(lib.version)")
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    .textSelection(.enabled)
                                }
                            }
                        }
                        if !s.rpaths.isEmpty {
                            Section("Search paths (rpath)") {
                                ForEach(s.rpaths, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                            }
                        }
                        if !s.segments.isEmpty {
                            Section("Segments") {
                                ForEach(s.segments) { seg in
                                    row(seg.name.isEmpty ? "(unnamed)" : seg.name, ByteCountFormatter.string(fromByteCount: Int64(seg.size), countStyle: .file))
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if slices != nil {
                Picker("View", selection: $showHex) {
                    Text("Info").tag(false); Text("Hex").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 60).padding(.vertical, 8)
                .background(.bar)
            }
        }
        .task(id: url) {
            let u = url
            slices = await Task.detached(priority: .userInitiated) { MachO.parse(u) }.value
            loaded = true
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

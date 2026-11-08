import SwiftUI
import UIKit
import OSLog
import UniformTypeIdentifiers

/// Settings › About › File Access Diagnostics.
/// Tries every way iOS offers to pick a folder/file, records exactly what comes back, reads the
/// app's signing info, and collects this app's system log lines so the real cause is visible.
final class DiagnosticsModel: ObservableObject {
    @Published var lines: [String] = []
    private let log = Logger(subsystem: "com.mangomods.mangoide", category: "diagnostics")
    private let started = Date()

    func note(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lines.append("[\(t)] \(s)")
        log.notice("\(s, privacy: .public)")
    }

    func clear() { lines = [] }

    // MARK: Signing info

    func signingInfo() {
        let b = Bundle.main
        note("Bundle ID: \(b.bundleIdentifier ?? "?") · version \(b.appVersion) (\(b.appBuild))")
        note("iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
        guard let url = b.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<?xml"), let end = raw.range(of: "</plist>"),
              let plistData = String(raw[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            note("No embedded.mobileprovision found (unusual for a sideloaded app).")
            return
        }
        note("Profile: \(plist["Name"] as? String ?? "?") · team \(plist["TeamName"] as? String ?? "?") \((plist["TeamIdentifier"] as? [String])?.first ?? "")")
        if let exp = plist["ExpirationDate"] as? Date { note("Profile expires: \(exp)") }
        let isEnterprise = plist["ProvisionsAllDevices"] as? Bool ?? false
        note("Profile type: \(isEnterprise ? "enterprise (all devices)" : "development/ad hoc (listed devices)")")
        if let ent = plist["Entitlements"] as? [String: Any] {
            note("App identifier in profile: \(ent["application-identifier"] as? String ?? "?")")
            for key in ent.keys.sorted() where key != "application-identifier" {
                note("  entitlement: \(key) = \(String(describing: ent[key]!).replacingOccurrences(of: "\n", with: " ").prefix(120))")
            }
        }
        if let why = SigningInfo.explanation { note("⚠️ " + why) } else { note("✅ Signing profile matches this app's bundle ID") }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        note("App container: \(home.lastPathComponent)")
        note("Documents writable: \(FileManager.default.isWritableFile(atPath: Workspace.shared.root.path))")
    }

    // MARK: Results from any picker

    func handlePicked(_ urls: [URL], via method: String) {
        note("\(method): picker returned \(urls.count) item(s)")
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            note("  url: \(u.path)")
            note("  security scope granted: \(scoped)")
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            note("  exists: \(exists) · folder: \(isDir.boolValue)")
            do {
                if isDir.boolValue {
                    let items = try FileManager.default.contentsOfDirectory(atPath: u.path)
                    note("  ✅ can list folder: \(items.count) item(s)")
                } else {
                    let data = try Data(contentsOf: u, options: .mappedIfSafe)
                    note("  ✅ can read file: \(data.count) bytes")
                }
            } catch {
                note("  ❌ can't read: \(error.localizedDescription)")
            }
            do {
                _ = try u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                note("  ✅ bookmark can be saved")
            } catch {
                note("  ❌ bookmark failed: \(error.localizedDescription)")
            }
            if scoped { u.stopAccessingSecurityScopedResource() }
        }
    }

    // MARK: System log lines from this app (where iOS explains picker failures)

    func collectLogs() {
        note("Collecting system log lines from the last 15 minutes…")
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [String] = []
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let pos = store.position(date: Date().addingTimeInterval(-900))
                let keywords = ["entitlement", "bookmark", "sandbox", "extension", "documentpicker", "document picker",
                                "documentmanager", "fileprovider", "file provider", "permission", "denied", "not permitted",
                                "picker", "security", "scope", "error", "fail"]
                for case let e as OSLogEntryLog in try store.getEntries(at: pos) {
                    let msg = e.composedMessage
                    let sub = e.subsystem.lowercased(), cat = e.category.lowercased(), low = msg.lowercased()
                    let relevant = sub.contains("documentmanager") || sub.contains("fileprovider") || sub.contains("uikit.documentpicker")
                        || sub.contains("sandbox") || cat.contains("picker") || sub == "com.mangomods.mangoide"
                        || keywords.contains(where: { low.contains($0) })
                    guard relevant else { continue }
                    let t = DateFormatter.localizedString(from: e.date, dateStyle: .none, timeStyle: .medium)
                    out.append("\(t) [\(e.subsystem)/\(e.category)] \(msg.prefix(400))")
                    if out.count > 400 { break }
                }
            } catch {
                out.append("Couldn't read logs: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self.note("---- \(out.count) log line(s) ----")
                self.lines.append(contentsOf: out)
                self.note("---- end of logs ----")
            }
        }
    }

    var report: String { lines.joined(separator: "\n") }
}

/// Each test keeps its own delegate alive until the picker reports back.
private final class DiagPickerDelegate: NSObject, UIDocumentPickerDelegate {
    static var active: DiagPickerDelegate?
    let method: String
    let model: DiagnosticsModel
    init(method: String, model: DiagnosticsModel) { self.method = method; self.model = model }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        model.handlePicked(urls, via: method)
        DiagPickerDelegate.active = nil
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        model.note("\(method): picker said CANCELLED (closed without a pick)")
        DiagPickerDelegate.active = nil
    }
}

struct DiagnosticsView: View {
    @StateObject private var model = DiagnosticsModel()
    @EnvironmentObject var router: Router
    @State private var showImporter = false

    var body: some View {
        List {
            Section {
                Text("Run each test, tap Open in the picker (pick any folder, even an empty one), then tap Collect Logs and Copy Report. Paste the report back to whoever's fixing this.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Tests") {
                Button("1. Folder picker (current method)") { present(types: [.folder], asCopy: false, method: "Test 1 modern folder") }
                Button("2. Folder picker (older iOS method)") { presentLegacy() }
                Button("3. Folder picker (SwiftUI importer)") { model.note("Test 3: presenting SwiftUI importer"); showImporter = true }
                Button("4. File, open in place") { present(types: [.item], asCopy: false, method: "Test 4 file in place") }
                Button("5. File, copy (known to work)") { present(types: [.item], asCopy: true, method: "Test 5 file copy") }
            }
            Section("Report") {
                Button("Show Signing Info") { model.signingInfo() }
                Button("Collect Logs") { model.collectLogs() }
                Button("Copy Report") {
                    UIPasteboard.general.string = model.report
                    router.flash("Report copied")
                }
                if !model.lines.isEmpty {
                    ShareLink(item: model.report) { Label("Share Report", systemImage: "square.and.arrow.up") }
                }
                Button("Clear", role: .destructive) { model.clear() }
            }
            if !model.lines.isEmpty {
                Section("Output") {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("File Access Diagnostics")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): model.handlePicked(urls, via: "Test 3 SwiftUI importer")
            case .failure(let e): model.note("Test 3: importer error: \(e.localizedDescription)")
            }
        }
        .onAppear { if model.lines.isEmpty { model.signingInfo() } }
    }

    private func present(types: [UTType], asCopy: Bool, method: String) {
        guard let top = FilePicker.topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        let d = DiagPickerDelegate(method: method, model: model)
        DiagPickerDelegate.active = d
        picker.delegate = d
        model.note("\(method): presenting picker")
        top.present(picker, animated: true)
    }

    private func presentLegacy() {
        guard let top = FilePicker.topViewController() else { return }
        let picker = UIDocumentPickerViewController(documentTypes: [UTType.folder.identifier], in: .open)
        let d = DiagPickerDelegate(method: "Test 2 legacy folder", model: model)
        DiagPickerDelegate.active = d
        picker.delegate = d
        model.note("Test 2 legacy folder: presenting picker")
        top.present(picker, animated: true)
    }
}

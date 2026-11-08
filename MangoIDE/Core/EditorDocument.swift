import Foundation
import CoreGraphics
import Combine

/// One open file. The same document is shared by every tab/pane showing that file,
/// so editing it in one side of a split updates the other instantly.
final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL
    @Published private(set) var text: String
    @Published private(set) var isDirty = false
    @Published var isBinary = false
    @Published var loadError: String?
    @Published var saveError: String?
    @Published var lastSaved: Date?
    /// Bumped whenever the text is replaced from outside a text view (reload, format), so views resync.
    @Published private(set) var externalRevision = 0

    private var autosaveWork: DispatchWorkItem?
    /// Where the user was, so switching tabs comes back to the same spot.
    var savedSelection = NSRange(location: 0, length: 0)
    var savedOffset = CGPoint.zero

    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.url = url
        self.text = ""
        load()
    }

    func load() {
        do {
            let data = try Data(contentsOf: url)
            let probe = data.prefix(8000)
            if probe.contains(0) {
                isBinary = true
                text = ""
            } else if let s = String(data: data, encoding: .utf8) {
                text = s
            } else if let s = String(data: data, encoding: .utf16) {
                text = s
            } else {
                text = String(decoding: data, as: UTF8.self)
            }
            isDirty = false
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        externalRevision += 1
    }

    /// Called by the text view on every edit.
    func userEdited(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = true
        scheduleAutosave()
    }

    /// Replace everything (e.g. snippet insert from outside, reload). Text views will pick it up.
    func replaceAll(_ newText: String, markDirty: Bool = true) {
        text = newText
        if markDirty { isDirty = true; scheduleAutosave() }
        externalRevision += 1
    }

    private func scheduleAutosave() {
        let s = AppSettings.shared
        guard s.autosave, !isBinary else { return }
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save(applyCleanup: false) }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.3, s.autosaveDelay), execute: work)
    }

    @discardableResult
    func save(applyCleanup: Bool = true) -> Bool {
        guard !isBinary, loadError == nil else { return false }
        autosaveWork?.cancel()
        let s = AppSettings.shared
        var out = text
        if applyCleanup {
            var changed = false
            if s.trimTrailingWhitespace {
                let trimmed = out.components(separatedBy: "\n").map { line -> String in
                    var l = line
                    while let last = l.last, last == " " || last == "\t" { l.removeLast() }
                    return l
                }.joined(separator: "\n")
                if trimmed != out { out = trimmed; changed = true }
            }
            if s.insertFinalNewline && !out.isEmpty && !out.hasSuffix("\n") { out += "\n"; changed = true }
            if changed { text = out; externalRevision += 1 }
        }
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            saveError = nil
            lastSaved = Date()
            if Workspace.shared.isInside(url, Workspace.shared.extensionsFolder) {
                DispatchQueue.main.async { ExtensionManager.shared.reload() }
            }
            return true
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }
}

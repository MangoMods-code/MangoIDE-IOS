import Foundation
import CoreGraphics
import Combine

/// One open file. The same document is shared by every tab/pane showing that file,
/// so editing it in one side of a split updates the other.
///
/// The text itself is deliberately *not* @Published: publishing it on every keystroke made
/// SwiftUI re-check the whole screen per key. Views that show the text register a listener instead.
final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL
    private(set) var text: String = ""
    @Published private(set) var isDirty = false
    @Published private(set) var isBinary = false
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var lastSaved: Date?
    /// Bumped when the text is replaced from outside the editor (reload, save cleanup, snippet).
    @Published private(set) var contentVersion = 0

    /// Where the user was, so switching tabs comes back to the same spot.
    var savedSelection = NSRange(location: 0, length: 0)
    var savedOffset = CGPoint.zero

    private var autosaveWork: DispatchWorkItem?
    private var listeners: [UUID: (String) -> Void] = [:]
    private var syncWork: DispatchWorkItem?
    private var lastEditor: UUID?
    private static let saveQueue = DispatchQueue(label: "mango.save", qos: .utility)

    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.url = url
        load()
    }

    func load() {
        do {
            let data = try Data(contentsOf: url)
            if data.prefix(8000).contains(0) {
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
        contentVersion += 1
    }

    // MARK: Live sync between editors showing this file

    func addListener(_ id: UUID, _ onChange: @escaping (String) -> Void) { listeners[id] = onChange }
    func removeListener(_ id: UUID) { listeners[id] = nil }

    /// Called by a text view on every edit. `source` is that view's id so it isn't told about its own change.
    func userEdited(_ newText: String, source: UUID) {
        text = newText
        lastEditor = source
        if !isDirty { isDirty = true }
        scheduleAutosave()
        guard listeners.count > 1 else { return }
        // Other panes catch up after a short pause instead of on every key.
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for (id, cb) in self.listeners where id != self.lastEditor { cb(self.text) }
        }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Replace everything from outside a text view. Every open view picks it up.
    func replaceAll(_ newText: String, markDirty: Bool = true) {
        text = newText
        if markDirty { isDirty = true; scheduleAutosave() }
        contentVersion += 1
    }

    // MARK: Saving

    private func scheduleAutosave() {
        let s = AppSettings.shared
        guard s.autosave, !isBinary else { return }
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save(applyCleanup: false) }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.3, s.autosaveDelay), execute: work)
    }

    /// Saves in the background so big files never stall typing. Returns false only if it can't save at all.
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
                    var l = Substring(line)
                    while let last = l.last, last == " " || last == "\t" { l.removeLast() }
                    return String(l)
                }.joined(separator: "\n")
                if trimmed != out { out = trimmed; changed = true }
            }
            if s.insertFinalNewline && !out.isEmpty && !out.hasSuffix("\n") { out += "\n"; changed = true }
            if changed { text = out; contentVersion += 1 }
        }
        let target = url
        isDirty = false
        EditorDocument.saveQueue.async { [weak self] in
            var failure: String?
            do { try out.write(to: target, atomically: true, encoding: .utf8) }
            catch { failure = "Couldn't save: \(error.localizedDescription)" }
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure {
                    self.saveError = failure
                    self.isDirty = true
                } else {
                    self.saveError = nil
                    self.lastSaved = Date()
                    if Workspace.shared.isInside(target, Workspace.shared.extensionsFolder) {
                        ExtensionManager.shared.reload()
                    }
                }
            }
        }
        return true
    }

    /// Throw away unsaved edits: cancel any pending autosave and go back to what's on disk.
    func discardChanges() {
        autosaveWork?.cancel()
        syncWork?.cancel()
        load()
    }

    /// Blocking save used when the app is about to go to the background.
    func saveNow() {
        guard isDirty, !isBinary, loadError == nil else { return }
        autosaveWork?.cancel()
        do { try text.write(to: url, atomically: true, encoding: .utf8); isDirty = false }
        catch { saveError = "Couldn't save: \(error.localizedDescription)" }
    }
}

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
    /// How to show it when it isn't editable text (image, PDF, video, Office doc, hex…).
    @Published private(set) var viewer: FileViewerKind?
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

    // MARK: Live sessions

    /// Set while this file is part of a live session: told about every change made on this device (old, new).
    var onLocalChange: ((String, String) -> Void)?
    /// Set while this file is part of a live session: told where your cursor is.
    var onLocalSelection: ((NSRange) -> Void)?
    private var remoteListeners: [UUID: (_ edits: [(NSRange, String)], _ old: String, _ new: String) -> Void] = [:]
    private var peerListeners: [UUID: ([PeerCaret]) -> Void] = [:]
    /// Other people's cursors in this file.
    private(set) var peers: [PeerCaret] = []

    // MARK: Problems

    /// Errors and warnings found in this file (see DiagnosticsCenter).
    @Published private(set) var diagnostics: [Diagnostic] = []
    private var diagnosticListeners: [UUID: ([Diagnostic]) -> Void] = [:]

    func addDiagnosticsListener(_ id: UUID, _ cb: @escaping ([Diagnostic]) -> Void) { diagnosticListeners[id] = cb }

    func setDiagnostics(_ list: [Diagnostic]) {
        guard list != diagnostics else { return }
        diagnostics = list
        for cb in diagnosticListeners.values { cb(list) }
    }

    private func textChanged() {
        DiagnosticsCenter.shared.schedule(self)
        NotificationCenter.default.post(name: .documentEdited, object: self)
    }

    func addRemoteListener(_ id: UUID, _ cb: @escaping (_ edits: [(NSRange, String)], _ old: String, _ new: String) -> Void) { remoteListeners[id] = cb }
    func addPeerListener(_ id: UUID, _ cb: @escaping ([PeerCaret]) -> Void) { peerListeners[id] = cb }

    /// Someone else's edit: every open view applies just that change, keeping your cursor where it was.
    func applyRemote(_ edits: [(NSRange, String)], newText: String) {
        let old = text
        text = newText
        if !isDirty { isDirty = true }
        scheduleDraft()
        for cb in remoteListeners.values { cb(edits, old, newText) }
        textChanged()
    }

    /// The live session's copy wins (after a resync). Doesn't count as your edit.
    func replaceFromRemote(_ newText: String) {
        guard newText != text else { return }
        text = newText
        if !isDirty { isDirty = true }
        contentVersion += 1
    }

    func setPeers(_ p: [PeerCaret]) {
        peers = p
        for cb in peerListeners.values { cb(p) }
    }

    init(url: URL) {
        self.url = url
        load()
        restoreDraft()
        DiagnosticsCenter.shared.schedule(self, delay: 0.4)
    }

    // MARK: Drafts (unsaved edits that survive closing the app)

    private var draftWork: DispatchWorkItem?

    /// If you closed the app with unsaved edits, bring them back (still unsaved).
    private func restoreDraft() {
        guard !isBinary, loadError == nil, let draft = DraftStore.load(for: url) else { return }
        if draft == text { DraftStore.remove(for: url); return }
        text = draft
        isDirty = true
        contentVersion += 1
        scheduleAutosave()
    }

    private func scheduleDraft() {
        draftWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isDirty else { return }
            DraftStore.save(self.text, for: self.url)
        }
        draftWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Writes the draft right away (used when the app leaves the screen).
    func writeDraftNow() {
        draftWork?.cancel()
        if isDirty && !isBinary { DraftStore.save(text, for: url, sync: true) }
    }

    func clearDraft() {
        draftWork?.cancel()
        DraftStore.remove(for: url)
    }

    func load() {
        if let kind = FileViewerKind.forURL(url) {
            // Known non-text type: don't read it into memory at all.
            isBinary = true
            viewer = kind
            text = ""
            loadError = FileManager.default.fileExists(atPath: url.path) ? nil : "The file is missing."
            contentVersion += 1
            return
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let before = text
            defer { if !isBinary, before != text { onLocalChange?(before, text); textChanged() } }
            if data.prefix(8000).contains(0) {
                isBinary = true
                viewer = .hex
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
    func removeListener(_ id: UUID) { listeners[id] = nil; remoteListeners[id] = nil; peerListeners[id] = nil; diagnosticListeners[id] = nil }

    /// Called by a text view on every edit. `source` is that view's id so it isn't told about its own change.
    func userEdited(_ newText: String, source: UUID) {
        let old = text
        text = newText
        onLocalChange?(old, newText)
        textChanged()
        lastEditor = source
        if !isDirty { isDirty = true }
        scheduleAutosave()
        scheduleDraft()
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
        let old = text
        text = newText
        onLocalChange?(old, newText)
        textChanged()
        if markDirty { isDirty = true; scheduleAutosave(); scheduleDraft() }
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
            if changed { let old = text; text = out; contentVersion += 1; onLocalChange?(old, out) }
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
                    NotificationCenter.default.post(name: .documentSaved, object: self)
                    if !self.isDirty { self.clearDraft() }
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
        clearDraft()
        load()
    }

    /// Blocking save used when the app is about to go to the background.
    func saveNow() {
        guard isDirty, !isBinary, loadError == nil else { return }
        autosaveWork?.cancel()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8); isDirty = false; clearDraft()
            NotificationCenter.default.post(name: .documentSaved, object: self)
        }
        catch { saveError = "Couldn't save: \(error.localizedDescription)" }
    }
}


/// Another person's cursor in a live session.
struct PeerCaret: Equatable {
    let id: String
    let name: String
    let color: String
    let location: Int
    let length: Int
}

extension Notification.Name {
    /// Posted (object: EditorDocument) whenever a document's text changes.
    static let documentEdited = Notification.Name("mango.documentEdited")
    /// Posted (object: EditorDocument) after a document is written to disk.
    static let documentSaved = Notification.Name("mango.documentSaved")
}

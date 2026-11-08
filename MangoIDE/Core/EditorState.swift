import Foundation
import SwiftUI
import UIKit

struct PaneState: Identifiable, Equatable {
    let id = UUID()
    var tabs: [UUID] = []
    var active: UUID?
}

struct CloseRequest: Identifiable {
    let id = UUID()
    let pane: Int
    let doc: UUID
}

/// Open files, tabs and the (optional) side-by-side split.
final class EditorState: ObservableObject {
    @Published private(set) var documents: [UUID: EditorDocument] = [:]
    @Published var panes: [PaneState] = [PaneState()]
    @Published var focusedPane = 0
    @Published var closeRequest: CloseRequest?
    /// Cursor position lives in its own object so moving the caret only redraws the status bar.
    let cursor = CursorModel()

    private var textViews: [UUID: WeakTextView] = [:]
    private var didRestore = false

    final class WeakTextView { weak var view: CodeTextView?; init(_ v: CodeTextView) { view = v } }

    var isSplit: Bool { panes.count > 1 }

    var activeDocument: EditorDocument? {
        guard panes.indices.contains(focusedPane), let id = panes[focusedPane].active else { return nil }
        return documents[id]
    }

    func doc(_ id: UUID?) -> EditorDocument? { id.flatMap { documents[$0] } }

    // MARK: Text view registry (so toolbar buttons can reach the focused editor)

    func register(_ view: CodeTextView, pane: UUID) { textViews[pane] = WeakTextView(view) }

    var activeTextView: CodeTextView? {
        guard panes.indices.contains(focusedPane) else { return nil }
        return textViews[panes[focusedPane].id]?.view
    }

    // MARK: Opening

    private func existing(_ url: URL) -> EditorDocument? {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        return documents.values.first { $0.url.standardizedFileURL.resolvingSymlinksInPath().path == key }
    }

    func open(_ url: URL, inPane paneIndex: Int? = nil) {
        if Workspace.shared.isDirectory(url) { return }
        let pane = min(paneIndex ?? focusedPane, panes.count - 1)
        let doc = existing(url) ?? {
            let d = EditorDocument(url: url)
            documents[d.id] = d
            return d
        }()
        if !panes[pane].tabs.contains(doc.id) {
            if let active = panes[pane].active, let i = panes[pane].tabs.firstIndex(of: active) {
                panes[pane].tabs.insert(doc.id, at: i + 1)
            } else {
                panes[pane].tabs.append(doc.id)
            }
        }
        panes[pane].active = doc.id
        focusedPane = pane
        enforceTabLimit(pane)
        if !Workspace.shared.isKnownLocation(url) { Workspace.shared.noteRecent(url) }
        saveSession()
    }

    /// A file handed to us from another app or the Files app.
    func openExternal(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        if scoped || FileManager.default.isReadableFile(atPath: url.path) {
            open(url)
        } else if let copy = Workspace.shared.importFiles([url]).first {
            open(copy)
        }
    }

    private func enforceTabLimit(_ pane: Int) {
        let limit = max(2, AppSettings.shared.maxTabs)
        while panes[pane].tabs.count > limit {
            guard let victim = panes[pane].tabs.first(where: { $0 != panes[pane].active && documents[$0]?.isDirty == false }) else { break }
            removeTab(victim, from: pane)
        }
    }

    func activate(_ id: UUID, pane: Int) {
        guard panes.indices.contains(pane) else { return }
        panes[pane].active = id
        focusedPane = pane
        saveSession()
    }

    // MARK: Closing

    private func isOpenElsewhere(_ id: UUID, besides pane: Int) -> Bool {
        panes.indices.contains { $0 != pane && panes[$0].tabs.contains(id) }
    }

    /// Unsaved tabs waiting for a Save / Discard answer (one dialog at a time).
    private var closeQueue: [CloseRequest] = []

    func requestClose(_ id: UUID, pane: Int) {
        guard let d = documents[id] else { return }
        if d.isDirty && !isOpenElsewhere(id, besides: pane) {
            // Always ask: closing never silently saves or throws away changes.
            guard !closeQueue.contains(where: { $0.doc == id }) && closeRequest?.doc != id else { return }
            closeQueue.append(CloseRequest(pane: pane, doc: id))
            showNextCloseRequest()
        } else {
            removeTab(id, from: pane)
        }
    }

    private func showNextCloseRequest() {
        guard closeRequest == nil, !closeQueue.isEmpty else { return }
        closeRequest = closeQueue.removeFirst()
    }

    /// Save = write it then close. Discard = drop the edits (file on disk stays as last saved) then close.
    func finishClose(_ req: CloseRequest, save: Bool) {
        closeRequest = nil
        if let d = documents[req.doc] {
            if save { d.save() } else { d.discardChanges() }
        }
        // The tab may have moved panes while the dialog was up.
        let pane = panes.firstIndex(where: { $0.tabs.contains(req.doc) }) ?? req.pane
        removeTab(req.doc, from: pane)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.showNextCloseRequest() }
    }

    /// Cancel keeps the tab open and stops closing any others that were lined up.
    func cancelClose() {
        closeRequest = nil
        closeQueue.removeAll()
    }

    func removeTab(_ id: UUID, from pane: Int) {
        guard panes.indices.contains(pane), let i = panes[pane].tabs.firstIndex(of: id) else { return }
        panes[pane].tabs.remove(at: i)
        if panes[pane].active == id {
            let tabs = panes[pane].tabs
            panes[pane].active = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)]
        }
        if !panes.contains(where: { $0.tabs.contains(id) }) { documents[id] = nil }
        if isSplit && panes[pane].tabs.isEmpty { closePane(pane) }
        saveSession()
    }

    func closeOthers(keep id: UUID, pane: Int) {
        for t in panes[pane].tabs where t != id { requestClose(t, pane: pane) }
    }

    func closeAll(pane: Int) {
        for t in panes[pane].tabs { requestClose(t, pane: pane) }
    }

    func closeEverything() {
        for p in panes.indices.reversed() where panes.indices.contains(p) {
            for t in panes[p].tabs { requestClose(t, pane: p) }
        }
    }

    // MARK: Split

    func toggleSplit() {
        if isSplit { closePane(1) } else { openToSide(activeDocument?.id) }
    }

    func openToSide(_ id: UUID?) {
        if !isSplit { panes.append(PaneState()) }
        let target = focusedPane == 0 ? 1 : 0
        if let id {
            if !panes[target].tabs.contains(id) { panes[target].tabs.append(id) }
            panes[target].active = id
        }
        focusedPane = target
        saveSession()
    }

    func closePane(_ index: Int) {
        guard isSplit, panes.indices.contains(index) else { return }
        let leaving = panes[index].tabs
        let other = index == 0 ? 1 : 0
        for t in leaving where !panes[other].tabs.contains(t) { panes[other].tabs.append(t) }
        if panes[other].active == nil { panes[other].active = panes[index].active ?? panes[other].tabs.first }
        panes.remove(at: index)
        focusedPane = 0
        textViews = textViews.filter { key, _ in panes.contains { $0.id == key } }
        saveSession()
    }

    func moveTab(_ id: UUID, from pane: Int) {
        let target = pane == 0 ? 1 : 0
        if !isSplit { openToSide(id); removeTab(id, from: 0); return }
        if !panes[target].tabs.contains(id) { panes[target].tabs.append(id) }
        panes[target].active = id
        removeTab(id, from: pane)
        focusedPane = panes.count > 1 ? target : 0
    }

    // MARK: Saving

    func saveActive() -> Bool { activeDocument?.save() ?? false }

    func saveAll() { documents.values.filter { $0.isDirty }.forEach { $0.save() } }

    /// Synchronous save for when the app is leaving the foreground.
    /// Used when the app leaves the screen. Only saves if autosave is on, so "Discard" stays meaningful.
    func saveAllNow() {
        guard AppSettings.shared.autosave else { return }
        documents.values.forEach { $0.saveNow() }
    }

    var dirtyCount: Int { documents.values.filter { $0.isDirty }.count }

    // MARK: File system changes

    func fileRenamed(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        for d in documents.values {
            let p = d.url.standardizedFileURL.path
            if p == oldPath { d.url = new }
            else if p.hasPrefix(oldPath + "/") {
                d.url = URL(fileURLWithPath: new.standardizedFileURL.path + String(p.dropFirst(oldPath.count)))
            }
        }
        objectWillChange.send()
        saveSession()
    }

    func fileDeleted(_ url: URL) {
        let path = url.standardizedFileURL.path
        let doomed = documents.values.filter {
            let p = $0.url.standardizedFileURL.path
            return p == path || p.hasPrefix(path + "/")
        }.map { $0.id }
        for id in doomed {
            for p in panes.indices.reversed() where panes.indices.contains(p) { removeTab(id, from: p) }
        }
    }

    // MARK: Session restore

    private struct Session: Codable { var panes: [[Data]]; var active: [Int?]; var focused: Int }

    func saveSession() {
        guard didRestore, AppSettings.shared.restoreTabs else { return }
        var bookmarkPanes: [[Data]] = []
        var actives: [Int?] = []
        for p in panes {
            var list: [Data] = []
            var activeIndex: Int?
            for id in p.tabs {
                guard let d = documents[id], let b = try? d.url.bookmarkData() else { continue }
                if id == p.active { activeIndex = list.count }
                list.append(b)
            }
            bookmarkPanes.append(list)
            actives.append(activeIndex)
        }
        let s = Session(panes: bookmarkPanes, active: actives, focused: focusedPane)
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "session.tabs")
    }

    func restoreSession() {
        guard !didRestore else { return }
        defer { didRestore = true }
        guard AppSettings.shared.restoreTabs,
              let raw = UserDefaults.standard.data(forKey: "session.tabs"),
              let s = try? JSONDecoder().decode(Session.self, from: raw) else { return }
        for (pi, list) in s.panes.enumerated() {
            if pi > 0 { panes.append(PaneState()) }
            var urls: [URL] = []
            for b in list {
                var stale = false
                if let u = try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                   FileManager.default.fileExists(atPath: u.path) {
                    _ = u.startAccessingSecurityScopedResource()
                    urls.append(u)
                }
            }
            for u in urls { open(u, inPane: pi) }
            if pi < s.active.count, let a = s.active[pi], a < panes[pi].tabs.count {
                panes[pi].active = panes[pi].tabs[a]
            }
        }
        if isSplit && panes[1].tabs.isEmpty { panes.remove(at: 1) }
        if isSplit && panes[0].tabs.isEmpty { panes.remove(at: 0) }
        focusedPane = min(s.focused, panes.count - 1)
    }

    // MARK: Editing helpers for the focused editor

    func insertIntoActive(_ text: String) {
        activeTextView?.insertSnippet(text)
    }

    func goToLine(_ line: Int) {
        activeTextView?.goTo(line: line)
    }

    func showFind(replace: Bool) {
        guard let tv = activeTextView else { return }
        tv.becomeFirstResponder()
        tv.findInteraction?.presentFindNavigator(showingReplace: replace)
    }
}

final class CursorModel: ObservableObject {
    @Published private(set) var line = 1
    @Published private(set) var column = 1

    func update(line: Int, column: Int) {
        if self.line != line { self.line = line }
        if self.column != column { self.column = column }
    }
}

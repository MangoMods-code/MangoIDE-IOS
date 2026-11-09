import SwiftUI
import UIKit

/// SwiftUI wrapper around EditorContainerView for one pane.
/// It doesn't observe the document: typing never makes SwiftUI rebuild anything.
struct CodeEditorView: UIViewRepresentable {
    let document: EditorDocument
    let contentVersion: Int
    let paneID: UUID
    let theme: EditorTheme
    let language: LanguageDef
    let config: EditorConfig
    let transparency: CGFloat
    let editor: EditorState
    let onFocus: () -> Void

    final class Coordinator {
        weak var document: EditorDocument?
        let listenerID = UUID()
        var appliedVersion = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> EditorContainerView {
        let v = EditorContainerView(frame: .zero)
        let c = context.coordinator
        c.document = document
        wire(v, c)
        v.transparency = transparency
        v.apply(config: config, theme: theme, language: language)
        v.setText(document.text)
        c.appliedVersion = document.contentVersion
        document.addListener(c.listenerID) { [weak v] text in
            guard let v, v.textView.textStorage.string != text else { return }
            v.setText(text)
        }
        document.addRemoteListener(c.listenerID) { [weak v] edits, old, new in v?.applyRemoteEdits(edits, old: old, new: new) }
        document.addPeerListener(c.listenerID) { [weak v] peers in v?.showPeers(peers) }
        if !document.peers.isEmpty { v.showPeers(document.peers) }
        document.addDiagnosticsListener(c.listenerID) { [weak v] list in v?.showDiagnostics(list) }
        if !document.diagnostics.isEmpty { v.showDiagnostics(document.diagnostics) }
        editor.register(v.textView, pane: paneID)
        let doc = document
        DispatchQueue.main.async {
            let len = v.textView.textStorage.length
            let sel = doc.savedSelection
            v.textView.selectedRange = NSRange(location: min(sel.location, len), length: 0)
            v.textView.setContentOffset(doc.savedOffset, animated: false)
            v.gutter.setNeedsDisplay()
        }
        return v
    }

    func updateUIView(_ v: EditorContainerView, context: Context) {
        let c = context.coordinator
        wire(v, c)
        v.transparency = transparency
        v.apply(config: config, theme: theme, language: language)
        if c.appliedVersion != document.contentVersion {
            c.appliedVersion = document.contentVersion
            v.setText(document.text)
        }
        editor.register(v.textView, pane: paneID)
    }

    static func dismantleUIView(_ v: EditorContainerView, coordinator: Coordinator) {
        guard let doc = coordinator.document else { return }
        doc.removeListener(coordinator.listenerID)
        doc.savedSelection = v.textView.selectedRange
        doc.savedOffset = v.textView.contentOffset
    }

    private func wire(_ v: EditorContainerView, _ c: Coordinator) {
        let doc = document
        let source = c.listenerID
        v.onTextChange = { [weak doc, weak v] text in
            guard let doc else { return }
            doc.userEdited(text, source: source)
            if let v { doc.savedSelection = v.textView.selectedRange }
        }
        v.onSelection = { [weak doc] r in doc?.onLocalSelection?(r) }
        v.onFocus = onFocus
        let cursor = editor.cursor
        let ed = editor
        v.onCursor = { [weak ed, weak doc, weak cursor] line, col in
            guard let ed, let cursor, ed.activeDocument === doc else { return }
            cursor.update(line: line, column: col)
        }
    }
}

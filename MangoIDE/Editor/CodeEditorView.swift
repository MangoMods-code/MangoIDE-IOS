import SwiftUI
import UIKit

/// SwiftUI wrapper around EditorContainerView for one pane.
struct CodeEditorView: UIViewRepresentable {
    @ObservedObject var document: EditorDocument
    let paneID: UUID
    let theme: EditorTheme
    let language: LanguageDef
    let config: EditorConfig
    let editor: EditorState
    let onFocus: () -> Void

    final class Coordinator {
        weak var document: EditorDocument?
        var restored = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> EditorContainerView {
        let v = EditorContainerView(frame: .zero)
        context.coordinator.document = document
        wire(v)
        v.apply(config: config, theme: theme, language: language)
        v.setText(document.text)
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
        wire(v)
        v.apply(config: config, theme: theme, language: language)
        if v.textView.textStorage.string != document.text {
            v.setText(document.text)
        }
        editor.register(v.textView, pane: paneID)
    }

    static func dismantleUIView(_ v: EditorContainerView, coordinator: Coordinator) {
        guard let doc = coordinator.document else { return }
        doc.savedSelection = v.textView.selectedRange
        doc.savedOffset = v.textView.contentOffset
    }

    private func wire(_ v: EditorContainerView) {
        let doc = document
        v.onTextChange = { [weak doc, weak v] text in
            doc?.userEdited(text)
            if let doc, let v { doc.savedSelection = v.textView.selectedRange }
        }
        v.onFocus = onFocus
        let ed = editor
        v.onCursor = { [weak ed, weak doc] line, col in
            guard let ed else { return }
            if ed.activeDocument === doc {
                if ed.cursorLine != line { ed.cursorLine = line }
                if ed.cursorColumn != col { ed.cursorColumn = col }
            }
        }
    }
}

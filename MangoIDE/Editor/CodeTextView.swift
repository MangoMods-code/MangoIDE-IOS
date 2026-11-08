import UIKit

/// The text view itself. Editing behaviour lives in EditorContainerView (its delegate).
final class CodeTextView: UITextView {
    weak var owner: EditorContainerView?

    var wraps = true {
        didSet { if wraps != oldValue { applyWrap() } }
    }

    func applyWrap() {
        textContainer.widthTracksTextView = wraps
        if wraps {
            textContainer.size = CGSize(width: max(10, bounds.width - textContainerInset.left - textContainerInset.right),
                                        height: CGFloat.greatestFiniteMagnitude)
            alwaysBounceHorizontal = false
        } else {
            textContainer.size = CGSize(width: 50_000, height: CGFloat.greatestFiniteMagnitude)
            alwaysBounceHorizontal = true
        }
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length), actualCharacterRange: nil)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !wraps {
            let used = layoutManager.usedRect(for: textContainer)
            let w = max(bounds.width, ceil(used.width) + textContainerInset.left + textContainerInset.right + 40)
            if abs(contentSize.width - w) > 1 { contentSize = CGSize(width: w, height: contentSize.height) }
        }
        owner?.gutter.setNeedsDisplay()
    }

    // MARK: Called from toolbar / menus

    func insertSnippet(_ raw: String) {
        guard let owner else { return }
        var body = raw
        if body == "DATE" {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            body = f.string(from: Date())
        }
        let ns = textStorage.string as NSString
        let sel = selectedRange
        let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        var lines = body.components(separatedBy: "\n")
        if lines.count > 1 {
            for i in 1..<lines.count where !lines[i].isEmpty { lines[i] = indent + lines[i] }
        }
        let output = lines.joined(separator: "\n")
        // Put the cursor on the first empty indented line if there is one, otherwise at the end.
        var cursor = (output as NSString).length
        if let r = output.range(of: "\n" + indent + "    \n") ?? output.range(of: "\n" + indent + "  \n") ?? output.range(of: "\n" + indent + "\t\n") {
            cursor = (String(output[..<r.upperBound]) as NSString).length - 1
        } else if let r = output.range(of: "()") {
            cursor = (String(output[..<r.lowerBound]) as NSString).length + 1
        }
        owner.replace(sel, with: output, cursorOffset: cursor)
        becomeFirstResponder()
    }

    func goTo(line: Int) {
        guard let owner else { return }
        let starts = owner.lineStarts
        let idx = max(0, min(starts.count - 1, line - 1))
        let loc = min(starts[idx], textStorage.length)
        becomeFirstResponder()
        selectedRange = NSRange(location: loc, length: 0)
        scrollRangeToVisible(selectedRange)
    }

    func selectLine() {
        let ns = textStorage.string as NSString
        selectedRange = ns.lineRange(for: selectedRange)
    }

    func toggleComment(lineComment: String?) {
        guard let token = lineComment, let owner else { return }
        let ns = textStorage.string as NSString
        let range = ns.lineRange(for: selectedRange)
        let block = ns.substring(with: range)
        var lines = block.components(separatedBy: "\n")
        let trailing = block.hasSuffix("\n")
        if trailing { lines.removeLast() }
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(token) }
        lines = lines.map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let rest = String(line.dropFirst(indent.count))
            if allCommented {
                var r = String(rest.dropFirst(token.count))
                if r.hasPrefix(" ") { r.removeFirst() }
                return indent + r
            }
            return indent + token + " " + rest
        }
        let out = lines.joined(separator: "\n") + (trailing ? "\n" : "")
        owner.replace(range, with: out, cursorOffset: (out as NSString).length, select: true)
    }

    func indentSelection(outdent: Bool) {
        guard let owner, let config = owner.config else { return }
        let unit = config.indentUnit
        let ns = textStorage.string as NSString
        let range = ns.lineRange(for: selectedRange)
        let block = ns.substring(with: range)
        var lines = block.components(separatedBy: "\n")
        let trailing = block.hasSuffix("\n")
        if trailing { lines.removeLast() }
        lines = lines.map { line in
            if outdent {
                if line.hasPrefix(unit) { return String(line.dropFirst(unit.count)) }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                let spaces = line.prefix { $0 == " " }.count
                return String(line.dropFirst(min(spaces, unit.count)))
            }
            return line.isEmpty ? line : unit + line
        }
        let out = lines.joined(separator: "\n") + (trailing ? "\n" : "")
        owner.replace(range, with: out, cursorOffset: (out as NSString).length, select: true)
    }

    func duplicateLine() {
        guard let owner else { return }
        let ns = textStorage.string as NSString
        let range = ns.lineRange(for: selectedRange)
        var line = ns.substring(with: range)
        if !line.hasSuffix("\n") { line = "\n" + line }
        let insertAt = NSMaxRange(range)
        let caret = selectedRange.location + (line as NSString).length
        owner.replace(NSRange(location: insertAt, length: 0), with: line, cursorOffset: 0)
        selectedRange = NSRange(location: min(caret, textStorage.length), length: 0)
    }

    func deleteLine() {
        guard let owner else { return }
        let ns = textStorage.string as NSString
        let range = ns.lineRange(for: selectedRange)
        owner.replace(range, with: "", cursorOffset: 0)
    }
}

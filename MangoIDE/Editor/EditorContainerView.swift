import UIKit

/// Gutter + text view, plus all the "smart" typing behaviour.
final class EditorContainerView: UIView, UITextViewDelegate {
    let textView: CodeTextView = CodeTextView(usingTextLayoutManager: false)
    let gutter = GutterView()

    private(set) var config: EditorConfig?
    private(set) var theme: EditorTheme = ThemeLibrary.builtIn[0]
    private(set) var language: LanguageDef = .plain
    private(set) var lineStarts: [Int] = [0]

    var onTextChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCursor: ((Int, Int) -> Void)?
    var onSelection: ((NSRange) -> Void)?
    private var peers: [PeerCaret] = []
    private var peerViews: [UIView] = []
    // Autocomplete
    private var wordIndex: [String: Int] = [:]
    private var indexWork: DispatchWorkItem?
    private var completionRange: NSRange?
    private var completionItems: [Completion.Item] = []
    private static let indexQueue = DispatchQueue(label: "mango.wordindex", qos: .utility)
    // Problems
    private(set) var diagnostics: [Diagnostic] = []
    /// line (1-based) → worst problem on it, for the gutter.
    private(set) var problemLines: [Int: Diagnostic.Severity] = [:]
    var snippetProvider: (() -> [Snippet])?

    private var highlightWork: DispatchWorkItem?
    private var highlightGeneration = 0
    private var isReplacing = false
    private static let highlightQueue = DispatchQueue(label: "mango.highlight", qos: .userInitiated)
    /// How see-through the editor is (0 = solid). Used when a background image/video is set.
    var transparency: CGFloat = 0 { didSet { if transparency != oldValue { applyBackgroundColors() } } }
    private var gutterWidth: CGFloat = 0
    private var accessory: AccessoryBar?

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.owner = self
        textView.delegate = self
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.dataDetectorTypes = []
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 8)
        textView.textContainer.lineFragmentPadding = 2
        textView.layoutManager.allowsNonContiguousLayout = false
        if #available(iOS 16.0, *) { textView.isFindInteractionEnabled = true }
        gutter.textView = textView
        gutter.owner = self
        gutter.isUserInteractionEnabled = false
        addSubview(textView)
        addSubview(gutter)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gw = (config?.showLineNumbers ?? true) ? gutterWidth : 0
        gutter.isHidden = gw == 0
        gutter.frame = CGRect(x: 0, y: 0, width: gw, height: bounds.height)
        textView.frame = CGRect(x: gw, y: 0, width: max(0, bounds.width - gw), height: bounds.height)
        let bottom = (config?.scrollPastEnd ?? true) ? bounds.height * 0.4 : 0
        if abs(textView.contentInset.bottom - bottom) > 1 { textView.contentInset.bottom = bottom }
        if textView.wraps {
            textView.textContainer.size.width = max(10, textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right)
        }
        gutter.setNeedsDisplay()
        if !peers.isEmpty { layoutPeers() }
    }

    // MARK: Problems

    func showDiagnostics(_ list: [Diagnostic]) {
        diagnostics = list
        var lines: [Int: Diagnostic.Severity] = [:]
        for d in list where lines[d.line] != .error { lines[d.line] = d.severity }
        problemLines = lines
        applyDiagnosticMarks()
        gutter.setNeedsDisplay()
    }

    /// Dotted underlines under the problem spots. They're cleared as soon as you type and come back
    /// after the next check, so they never get saved or spread into new text.
    private var hasMarks = false
    private func applyDiagnosticMarks() {
        let storage = textView.textStorage
        let length = storage.length
        let full = NSRange(location: 0, length: length)
        if hasMarks {
            storage.beginEditing()
            storage.removeAttribute(.underlineStyle, range: full)
            storage.removeAttribute(.underlineColor, range: full)
            storage.endEditing()
            hasMarks = false
            textView.typingAttributes[.underlineStyle] = nil
            textView.typingAttributes[.underlineColor] = nil
        }
        guard length > 0, !diagnostics.isEmpty else { return }
        storage.beginEditing()
        defer { storage.endEditing() }
        let ns = textView.textStorage.string as NSString
        for d in diagnostics.prefix(300) {
            let li = d.line - 1
            guard li >= 0, li < lineStarts.count else { continue }
            let start = lineStarts[li]
            var end = li + 1 < lineStarts.count ? lineStarts[li + 1] - 1 : length
            end = max(start, min(end, length))
            var from = min(start + max(0, d.col - 1), end)
            // Underline the word at the column, or the whole line when the column is at its end.
            var to = from
            while to < end && Completion.isWordChar(ns.character(at: to)) { to += 1 }
            if to == from {
                from = start
                while from < end && (ns.character(at: from) == 32 || ns.character(at: from) == 9) { from += 1 }
                to = end
            }
            guard to > from else { continue }
            let color: UIColor = d.severity == .error ? .systemRed : d.severity == .warning ? .systemOrange : .systemBlue
            storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                   .underlineColor: color], range: NSRange(location: from, length: to - from))
            hasMarks = true
        }
    }

    // MARK: Autocomplete

    private func scheduleIndex() {
        guard config?.autocomplete == true else { return }
        indexWork?.cancel()
        // The text is only copied once typing pauses, not on every key.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let text = String(self.textView.textStorage.string)
            EditorContainerView.indexQueue.async {
                let words = Completion.index(text)
                DispatchQueue.main.async { [weak self] in self?.wordIndex = words }
            }
        }
        indexWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private var completionWork: DispatchWorkItem?

    /// Several cursor moves in a row (fast typing) only look up suggestions once.
    private func updateCompletions() {
        guard accessory != nil, config?.autocomplete == true || !completionItems.isEmpty else { return }
        completionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshCompletions() }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func refreshCompletions() {
        guard let accessory else { return }
        let sel = textView.selectedRange
        guard config?.autocomplete == true, textView.isFirstResponder, sel.length == 0, textView.markedTextRange == nil,
              let range = Completion.prefix(in: textView.textStorage.string as NSString, at: sel.location) else {
            completionRange = nil; completionItems = []
            accessory.setSuggestions([])
            return
        }
        let prefix = (textView.textStorage.string as NSString).substring(with: range)
        let items = Completion.suggestions(prefix: prefix, words: wordIndex, language: language,
                                           snippets: ExtensionManager.shared.snippets(for: language))
        completionRange = range
        completionItems = items
        accessory.setSuggestions(items.map(\.label))
    }

    private func acceptCompletion(_ i: Int) {
        guard let range = completionRange, completionItems.indices.contains(i),
              NSMaxRange(range) <= textView.textStorage.length else { return }
        let item = completionItems[i]
        completionRange = nil; completionItems = []
        accessory?.setSuggestions([])
        if item.isSnippet {
            textView.selectedRange = range
            textView.insertSnippet(item.insert)
        } else {
            replace(range, with: item.insert, cursorOffset: (item.insert as NSString).length)
        }
    }

    // MARK: Live sessions

    /// Applies someone else's edit without touching your cursor or scroll position.
    func applyRemoteEdits(_ edits: [(NSRange, String)], old: String, new: String) {
        guard textView.markedTextRange == nil, textView.textStorage.string == old else { setText(new); return }
        var sel = textView.selectedRange
        var start = sel.location, end = NSMaxRange(sel)
        let attrs = config.map { SyntaxHighlighter.baseAttributes(theme: theme, config: $0) } ?? [:]
        isReplacing = true
        textView.textStorage.beginEditing()
        for (r, str) in edits {
            textView.textStorage.replaceCharacters(in: r, with: NSAttributedString(string: str, attributes: attrs))
            let delta = (str as NSString).length - r.length
            func move(_ i: Int) -> Int { i < r.location ? i : (i >= NSMaxRange(r) ? i + delta : r.location) }
            start = move(start); end = move(end)
        }
        textView.textStorage.endEditing()
        isReplacing = false
        let len = textView.textStorage.length
        start = min(max(0, start), len); end = min(max(start, end), len)
        sel = NSRange(location: start, length: end - start)
        if textView.selectedRange != sel { textView.selectedRange = sel }
        textView.undoManager?.removeAllActions()
        recomputeLines()
        scheduleHighlight()
        gutter.setNeedsDisplay()
        layoutPeers()
    }

    /// Other people's cursors, with their names.
    func showPeers(_ p: [PeerCaret]) {
        peers = p
        layoutPeers()
    }

    private func layoutPeers() {
        peerViews.forEach { $0.removeFromSuperview() }
        peerViews.removeAll()
        let len = textView.textStorage.length
        for p in peers {
            guard let pos = textView.position(from: textView.beginningOfDocument, offset: min(max(0, p.location), len)) else { continue }
            let r = textView.caretRect(for: pos)
            guard r.origin.x.isFinite, r.origin.y.isFinite else { continue }
            let color = UIColor(hex: p.color)
            if p.length > 0, let endPos = textView.position(from: pos, offset: min(p.length, len - min(p.location, len))),
               let range = textView.textRange(from: pos, to: endPos) {
                for sr in textView.selectionRects(for: range) where sr.rect.width > 0 {
                    let v = UIView(frame: sr.rect)
                    v.backgroundColor = color.withAlphaComponent(0.22)
                    v.isUserInteractionEnabled = false
                    textView.addSubview(v); peerViews.append(v)
                }
            }
            let caret = UIView(frame: CGRect(x: r.minX, y: r.minY, width: 2, height: r.height))
            caret.backgroundColor = color
            caret.isUserInteractionEnabled = false
            let label = UILabel()
            label.text = " \(p.name) "
            label.font = .systemFont(ofSize: 10, weight: .bold)
            label.textColor = .white
            label.backgroundColor = color
            label.layer.cornerRadius = 3
            label.layer.masksToBounds = true
            label.sizeToFit()
            label.frame.origin = CGPoint(x: r.minX, y: max(0, r.minY - label.frame.height))
            label.isUserInteractionEnabled = false
            label.alpha = 0.92
            textView.addSubview(caret); textView.addSubview(label)
            peerViews += [caret, label]
        }
    }

    // MARK: Configuration

    func apply(config newConfig: EditorConfig, theme newTheme: EditorTheme, language newLanguage: LanguageDef) {
        let configChanged = newConfig != config
        let themeChanged = newTheme != theme
        let langChanged = newLanguage != language
        guard configChanged || themeChanged || langChanged || config == nil else { return }
        let accessoryChanged = config.map { $0.showAccessory != newConfig.showAccessory || $0.accessoryKeys != newConfig.accessoryKeys
            || $0.accessoryArrows != newConfig.accessoryArrows || $0.accessoryUndo != newConfig.accessoryUndo } ?? true
        config = newConfig
        theme = newTheme
        language = newLanguage

        applyBackgroundColors()
        textView.tintColor = UIColor(hex: newTheme.cursor)
        textView.keyboardAppearance = newTheme.isDark ? .dark : .light
        textView.indicatorStyle = newTheme.isDark ? .white : .black
        textView.spellCheckingType = newConfig.spellCheck ? .yes : .no
        textView.autocorrectionType = newConfig.autocorrect ? .yes : .no
        textView.wraps = newConfig.wordWrap

        if accessoryChanged {
            if newConfig.showAccessory {
                let bar = AccessoryBar(config: newConfig, theme: newTheme)
                bar.onKey = { [weak self] key in self?.accessoryKey(key) }
                accessory = bar
                textView.inputAccessoryView = bar
            } else {
                accessory = nil
                textView.inputAccessoryView = nil
            }
            if textView.isFirstResponder { textView.reloadInputViews() }
        } else if themeChanged {
            accessory?.applyTheme(newTheme)
        }
        if configChanged || themeChanged {
            applyBaseAttributes()
        }
        updateGutterWidth()
        highlightNow(sync: true)
        setNeedsLayout()
    }

    private func applyBackgroundColors() {
        let alpha = 1 - max(0, min(0.95, transparency))
        textView.backgroundColor = theme.bg.withAlphaComponent(alpha)
        backgroundColor = .clear
        gutter.backgroundColor = UIColor(hex: theme.gutterBackground).withAlphaComponent(alpha)
        gutter.isOpaque = alpha >= 1
        gutter.setNeedsDisplay()
    }

    /// Font, spacing and tab stops for the whole text. Only needed when those settings change.
    private func applyBaseAttributes() {
        guard let config else { return }
        let base = SyntaxHighlighter.baseAttributes(theme: theme, config: config)
        let storage = textView.textStorage
        storage.beginEditing()
        storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.typingAttributes = base
    }

    func setText(_ text: String) {
        let sel = textView.selectedRange
        let offset = textView.contentOffset
        if let config {
            textView.attributedText = NSAttributedString(string: text, attributes: SyntaxHighlighter.baseAttributes(theme: theme, config: config))
            textView.typingAttributes = SyntaxHighlighter.baseAttributes(theme: theme, config: config)
        } else {
            textView.text = text
        }
        recomputeLines()
        highlightNow(sync: true)
        scheduleIndex()
        let len = textView.textStorage.length
        textView.selectedRange = NSRange(location: min(sel.location, len), length: 0)
        textView.setContentOffset(offset, animated: false)
        gutter.setNeedsDisplay()
        if !peers.isEmpty { layoutPeers() }
    }

    // MARK: Change handling

    /// Where each line begins, read in bulk chunks straight from the text storage (fast even for big files).
    private func recomputeLines() {
        let ns = textView.textStorage.string as NSString
        let length = ns.length
        var starts = [0]
        starts.reserveCapacity(max(16, lineStarts.count + 8))
        let chunk = 16_384
        var buffer = [unichar](repeating: 0, count: chunk)
        var offset = 0
        while offset < length {
            let n = min(chunk, length - offset)
            buffer.withUnsafeMutableBufferPointer { buf in
                ns.getCharacters(buf.baseAddress!, range: NSRange(location: offset, length: n))
                for i in 0..<n where buf[i] == 10 { starts.append(offset + i + 1) }
            }
            offset += n
        }
        lineStarts = starts
        updateGutterWidth()
    }

    private func updateGutterWidth() {
        guard let config else { return }
        let digits = max(2, String(lineStarts.count).count)
        let font = GutterView.font(for: config)
        let w = ceil(("8" as NSString).size(withAttributes: [.font: font]).width * CGFloat(digits)) + 18
        if abs(w - gutterWidth) > 0.5 { gutterWidth = w; setNeedsLayout() }
    }

    func lineIndex(for location: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func handleChange() {
        if isReplacing { return }
        if !problemLines.isEmpty { showDiagnostics([]) }   // stale until the next check
        recomputeLines()
        scheduleIndex()
        onTextChange?(textView.textStorage.string)
        scheduleHighlight()
        reportCursor()
        gutter.setNeedsDisplay()
    }

    private func scheduleHighlight() {
        highlightWork?.cancel()
        let len = textView.textStorage.length
        let delay = len < 20_000 ? 0.05 : (len < 100_000 ? 0.15 : 0.35)
        let work = DispatchWorkItem { [weak self] in self?.highlightNow() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Colors the text. Small files color instantly; bigger ones are worked out in the
    /// background and applied only if nothing changed meanwhile, so typing never waits on it.
    func highlightNow(sync: Bool = false) {
        guard let config else { return }
        if textView.markedTextRange != nil { scheduleHighlight(); return }
        highlightWork?.cancel()
        highlightGeneration += 1
        let gen = highlightGeneration
        let storage = textView.textStorage
        let length = storage.length
        let lang = language, th = theme
        guard SyntaxHighlighter.shouldColor(length: length, language: lang, config: config) else {
            SyntaxHighlighter.applyColors([], to: storage, foreground: th.fg)
            return
        }
        let text = String(storage.string)
        if sync && length < 30_000 {
            SyntaxHighlighter.applyColors(SyntaxHighlighter.spans(for: text, language: lang, theme: th), to: storage, foreground: th.fg)
            return
        }
        EditorContainerView.highlightQueue.async { [weak self] in
            let spans = SyntaxHighlighter.spans(for: text, language: lang, theme: th)
            DispatchQueue.main.async {
                guard let self, self.highlightGeneration == gen, self.textView.textStorage.length == length,
                      self.textView.markedTextRange == nil else { return }
                SyntaxHighlighter.applyColors(spans, to: self.textView.textStorage, foreground: th.fg)
            }
        }
    }

    private func reportCursor() {
        let loc = textView.selectedRange.location
        let line = lineIndex(for: loc)
        let col = loc - lineStarts[line] + 1
        let cb = onCursor
        DispatchQueue.main.async { cb?(line + 1, col) }
    }

    /// Replace text with undo support and place the caret.
    func replace(_ range: NSRange, with string: String, cursorOffset: Int, select: Bool = false) {
        let len = textView.textStorage.length
        let safe = NSRange(location: min(range.location, len), length: min(range.length, len - min(range.location, len)))
        guard let start = textView.position(from: textView.beginningOfDocument, offset: safe.location),
              let end = textView.position(from: start, offset: safe.length),
              let tr = textView.textRange(from: start, to: end) else { return }
        isReplacing = true
        textView.replace(tr, withText: string)
        isReplacing = false
        let newLen = (string as NSString).length
        if select {
            textView.selectedRange = NSRange(location: safe.location, length: newLen)
        } else {
            textView.selectedRange = NSRange(location: safe.location + min(cursorOffset, newLen), length: 0)
        }
        handleChange()
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ tv: UITextView) { handleChange() }

    func textViewDidChangeSelection(_ tv: UITextView) {
        reportCursor()
        onSelection?(tv.selectedRange)
        updateCompletions()
        gutter.setNeedsDisplay()
    }

    func textViewDidBeginEditing(_ tv: UITextView) { onFocus?() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { gutter.setNeedsDisplay() }

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private static let closers: Set<Character> = [")", "]", "}"]
    private static let quoteChars: Set<Character> = ["\"", "'", "`"]

    private func char(at i: Int, in ns: NSString) -> Character? {
        guard i >= 0, i < ns.length else { return nil }
        return Character(ns.substring(with: ns.rangeOfComposedCharacterSequence(at: i)))
    }

    func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        smartShouldChange(range, text)
    }

    /// Returns true to let UIKit insert the text as-is, false when we handled it ourselves.
    func smartShouldChange(_ range: NSRange, _ text: String) -> Bool {
        let tv: UITextView = textView
        guard let c = config, tv.markedTextRange == nil else { return true }
        let ns = tv.textStorage.string as NSString
        let next = char(at: NSMaxRange(range), in: ns)
        let prev = char(at: range.location - 1, in: ns)

        // Enter: keep indentation, indent after an opening bracket/colon, split {} onto lines.
        if text == "\n" && c.autoIndent {
            let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
            let upToCursor = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            let indent = String(upToCursor.prefix { $0 == " " || $0 == "\t" })
            let trimmed = upToCursor.trimmingCharacters(in: .whitespaces)
            var extra = ""
            if let last = trimmed.last {
                if "{[(".contains(last) { extra = c.indentUnit }
                if last == ":" && ["python", "nim", "yaml"].contains(language.id) { extra = c.indentUnit }
                if ["lua", "ruby", "elixir", "julia"].contains(language.id) {
                    let lower = trimmed.lowercased()
                    if lower.hasSuffix(" do") || lower.hasSuffix(" then") || lower.hasPrefix("function") || lower.hasPrefix("def ") || lower.hasPrefix("local function") {
                        extra = c.indentUnit
                    }
                }
                if (language.markup ?? false), last == ">", !trimmed.hasPrefix("</"), !trimmed.hasSuffix("/>"),
                   let next, next == "<" { extra = c.indentUnit }
            }
            if !extra.isEmpty, let p = trimmed.last, let n = next,
               (EditorContainerView.pairs[p] == n && EditorContainerView.closers.contains(n)) || (p == ">" && n == "<") {
                let s = "\n" + indent + extra + "\n" + indent
                replace(range, with: s, cursorOffset: (("\n" + indent + extra) as NSString).length)
                return false
            }
            let s = "\n" + indent + extra
            replace(range, with: s, cursorOffset: (s as NSString).length)
            return false
        }

        // Backspace: remove an empty bracket/quote pair, or a whole indent step.
        if text.isEmpty && range.length == 1 {
            if c.smartBackspace, let deleted = char(at: range.location, in: ns), let n = char(at: range.location + 1, in: ns),
               EditorContainerView.pairs[deleted] == n {
                replace(NSRange(location: range.location, length: 2), with: "", cursorOffset: 0)
                return false
            }
            if c.smartBackspace && c.insertSpaces, char(at: range.location, in: ns) == " " {
                let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
                let before = ns.substring(with: NSRange(location: lineStart, length: NSMaxRange(range) - lineStart))
                if !before.isEmpty && before.allSatisfy({ $0 == " " }) {
                    let unit = max(1, c.tabWidth)
                    let remove = before.count % unit == 0 ? unit : before.count % unit
                    let start = NSMaxRange(range) - remove
                    replace(NSRange(location: start, length: remove), with: "", cursorOffset: 0)
                    return false
                }
            }
            return true
        }

        guard text.count == 1, let ch = text.first else { return true }
        let isQuote = EditorContainerView.quoteChars.contains(ch)
        let enabled = isQuote ? c.autoCloseQuotes : c.autoCloseBrackets

        // Typing a closer that is already there just steps over it.
        if enabled && range.length == 0, let n = next, n == ch,
           EditorContainerView.closers.contains(ch) || isQuote {
            tv.selectedRange = NSRange(location: range.location + 1, length: 0)
            return false
        }

        if enabled, let close = EditorContainerView.pairs[ch] {
            if range.length > 0 {
                // Wrap the selection.
                let inner = ns.substring(with: range)
                let s = String(ch) + inner + String(close)
                replace(range, with: s, cursorOffset: (s as NSString).length)
                return false
            }
            if isQuote {
                if let p = prev, p.isLetter || p.isNumber || p == "\\" { return true }
                if ch == "'" && ["markdown", "plaintext", "rust"].contains(language.id) { return true }
            }
            if let n = next, !(n.isWhitespace || EditorContainerView.closers.contains(n) || n == "," || n == ";" || n == ":") { return true }
            replace(range, with: String(ch) + String(close), cursorOffset: 1)
            return false
        }
        return true
    }

    // MARK: Accessory bar keys

    private func accessoryKey(_ key: AccessoryBar.Key) {
        let tv = textView
        switch key {
        case .text(let s):
            let range = tv.selectedRange
            if smartShouldChange(range, s) {
                replace(range, with: s, cursorOffset: (s as NSString).length)
            }
        case .tab:
            if tv.selectedRange.length > 0 { tv.indentSelection(outdent: false) }
            else if let c = config { replace(tv.selectedRange, with: c.indentUnit, cursorOffset: (c.indentUnit as NSString).length) }
        case .outdent:
            tv.indentSelection(outdent: true)
        case .left:
            let r = tv.selectedRange
            tv.selectedRange = NSRange(location: max(0, r.length > 0 ? r.location : r.location - 1), length: 0)
        case .right:
            let r = tv.selectedRange
            tv.selectedRange = NSRange(location: min(tv.textStorage.length, r.length > 0 ? NSMaxRange(r) : r.location + 1), length: 0)
        case .up, .down:
            let loc = tv.selectedRange.location
            let line = lineIndex(for: loc)
            let col = loc - lineStarts[line]
            let target = key == .up ? line - 1 : line + 1
            guard target >= 0 && target < lineStarts.count else { return }
            let start = lineStarts[target]
            let end = target + 1 < lineStarts.count ? lineStarts[target + 1] - 1 : tv.textStorage.length
            tv.selectedRange = NSRange(location: min(start + col, max(start, end)), length: 0)
        case .undo:
            tv.undoManager?.undo(); handleChange()
        case .redo:
            tv.undoManager?.redo(); handleChange()
        case .comment:
            tv.toggleComment(lineComment: language.lineComment)
        case .snippets:
            NotificationCenter.default.post(name: .showSnippets, object: nil)
        case .dismiss:
            tv.resignFirstResponder()
        case .complete(let i):
            acceptCompletion(i)
        }
        tv.scrollRangeToVisible(tv.selectedRange)
    }
}

extension Notification.Name {
    static let showSnippets = Notification.Name("mango.showSnippets")
}

// MARK: - Line number gutter

final class GutterView: UIView {
    weak var textView: CodeTextView?
    weak var owner: EditorContainerView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        isOpaque = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    static func font(for config: EditorConfig) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: max(9, CGFloat(config.fontSize) * 0.82), weight: .regular)
    }

    override func draw(_ rect: CGRect) {
        guard let tv = textView, let owner, let config = owner.config else { return }
        let theme = owner.theme
        (backgroundColor ?? UIColor(hex: theme.gutterBackground)).setFill()
        UIRectFill(bounds)

        let lm = tv.layoutManager
        let container = tv.textContainer
        let inset = tv.textContainerInset
        let storageLength = tv.textStorage.length
        let starts = owner.lineStarts
        let font = GutterView.font(for: config)
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(hex: theme.gutterForeground)]
        let active: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .bold),
                                                     .foregroundColor: UIColor(hex: theme.gutterActive)]
        let currentLine = config.highlightCurrentLine ? owner.lineIndex(for: tv.selectedRange.location) : -1

        let visible = CGRect(x: 0, y: tv.contentOffset.y - inset.top, width: max(1, container.size.width), height: tv.bounds.height)
        var firstLine = 0
        if storageLength > 0 {
            let glyphs = lm.glyphRange(forBoundingRect: visible, in: container)
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            firstLine = owner.lineIndex(for: chars.location)
        }
        var lastBaselineOffset: CGFloat = font.ascender + 2
        var line = firstLine
        while line < starts.count {
            let start = starts[line]
            var fragment: CGRect
            var baselineOffset = lastBaselineOffset
            if start < storageLength {
                let g = lm.glyphIndexForCharacter(at: start)
                fragment = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                baselineOffset = lm.location(forGlyphAt: g).y
                lastBaselineOffset = baselineOffset
            } else {
                fragment = lm.extraLineFragmentRect
                if fragment.isEmpty && storageLength == 0 {
                    fragment = CGRect(x: 0, y: 0, width: 10, height: font.lineHeight * CGFloat(config.lineHeight))
                }
                if fragment.isEmpty { break }
            }
            let y = fragment.minY + inset.top - tv.contentOffset.y
            if y > bounds.height { break }
            var attrs = line == currentLine ? active : normal
            if let sev = owner.problemLines[line + 1] {
                let color: UIColor = sev == .error ? .systemRed : sev == .warning ? .systemOrange : .systemBlue
                attrs[.foregroundColor] = color
                let dotY = y + baselineOffset - font.ascender + font.lineHeight / 2 - 2.5
                color.setFill()
                UIBezierPath(ovalIn: CGRect(x: 3, y: dotY, width: 5, height: 5)).fill()
            }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            let drawY = y + baselineOffset - font.ascender
            label.draw(at: CGPoint(x: bounds.width - size.width - 8, y: drawY), withAttributes: attrs)
            line += 1
        }
    }
}

import UIKit

/// Regex + scanner based highlighter. Fast enough to recolor a whole file on each pause in typing.
final class SyntaxHighlighter {
    private struct Rules {
        var keywords: NSRegularExpression?
        var types: NSRegularExpression?
        var literals: NSRegularExpression?
        var capitalized: NSRegularExpression?
        var number: NSRegularExpression?
        var function: NSRegularExpression?
        var decorator: NSRegularExpression?
        var preprocessor: NSRegularExpression?
        var tag: NSRegularExpression?
        var attributeName: NSRegularExpression?
        var mdHeading: NSRegularExpression?
        var mdEmphasis: NSRegularExpression?
        var mdLink: NSRegularExpression?
        var cssProperty: NSRegularExpression?
        var jsonKey: NSRegularExpression?
    }

    private static var cache: [String: Rules] = [:]
    private static let cacheLock = NSLock()

    private static func words(_ list: [String]?, caseInsensitive: Bool) -> NSRegularExpression? {
        guard let list, !list.isEmpty else { return nil }
        let escaped = list.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // Word boundaries that also work for words like "defined?" or ".true."
        let pattern = "(?<![\\w$])(?:\(escaped))(?![\\w$])"
        return try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: p, options: o)
    }

    private static func rules(for lang: LanguageDef) -> Rules {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let r = cache[lang.id] { return r }
        let ci = lang.caseInsensitive ?? false
        var r = Rules()
        r.keywords = words(lang.keywords, caseInsensitive: ci)
        r.types = words(lang.types, caseInsensitive: ci)
        r.literals = words(lang.literals, caseInsensitive: ci)
        let isCode = !(lang.markup ?? false) && !["markdown", "plaintext", "json", "yaml", "toml", "css"].contains(lang.id)
        if isCode {
            r.capitalized = rx("\\b[A-Z][A-Za-z0-9_]*[a-z][A-Za-z0-9_]*\\b")
            r.function = rx("\\b([A-Za-z_][A-Za-z0-9_]*)(?=\\s*\\()")
        }
        if lang.id != "plaintext" && lang.id != "markdown" {
            r.number = rx("(?<![\\w.])(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b")
        }
        if lang.decorators ?? false { r.decorator = rx("@[A-Za-z_][A-Za-z0-9_.]*") }
        if lang.preprocessor ?? false { r.preprocessor = rx("^[ \\t]*#[ \\t]*[a-z]+", [.anchorsMatchLines]) }
        if lang.markup ?? false {
            r.tag = rx("</?[A-Za-z][\\w:.-]*|/?>|<!DOCTYPE[^>]*>", [.caseInsensitive])
            r.attributeName = rx("\\b[A-Za-z_:][\\w:.-]*(?=\\s*=)")
        }
        if lang.id == "markdown" {
            r.mdHeading = rx("^#{1,6} .*$", [.anchorsMatchLines])
            r.mdEmphasis = rx("(\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__|(?<![*\\w])\\*[^*\\n]+\\*(?!\\*)|^\\s*[-*+] |^\\s*\\d+\\. |^>.*$)", [.anchorsMatchLines])
            r.mdLink = rx("\\[[^\\]\\n]*\\]\\([^)\\n]*\\)")
        }
        if lang.id == "css" {
            r.cssProperty = rx("[\\w-]+(?=\\s*:)")
            r.tag = rx("(^|[\\s,}])([.#]?[A-Za-z][\\w-]*)(?=[^{};]*\\{)", [.anchorsMatchLines])
        }
        if lang.id == "json" || lang.id == "yaml" || lang.id == "toml" {
            r.jsonKey = rx(lang.id == "json" ? "\"(?:[^\"\\\\\\n]|\\\\.)*\"(?=\\s*:)" : "^[ \\t-]*[\\w.\"'-]+(?=\\s*[:=])", [.anchorsMatchLines])
        }
        cache[lang.id] = r
        return r
    }

    static func clearCache() { cacheLock.lock(); cache = [:]; cacheLock.unlock() }

    // MARK: Highlight

    struct Span { let range: NSRange; let color: UIColor }

    static func baseAttributes(theme: EditorTheme, config: EditorConfig) -> [NSAttributedString.Key: Any] {
        let font = config.font()
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = CGFloat(config.lineHeight)
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        para.defaultTabInterval = space * CGFloat(max(1, config.tabWidth))
        para.tabStops = []
        para.lineBreakMode = config.wordWrap ? .byWordWrapping : .byClipping
        return [.font: font, .foregroundColor: theme.fg, .paragraphStyle: para]
    }

    static func shouldColor(length: Int, language: LanguageDef, config: EditorConfig) -> Bool {
        config.syntaxHighlighting && length <= config.largeFileThreshold && language.id != "plaintext"
    }

    /// Works out every colored range. Safe to call off the main thread.
    static func spans(for text: String, language: LanguageDef, theme: EditorTheme) -> [Span] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let r = rules(for: language)
        var out: [Span] = []
        out.reserveCapacity(1024)

        func paint(_ re: NSRegularExpression?, _ hex: String, group: Int = 0) {
            guard let re else { return }
            let color = UIColor(hex: hex)
            re.enumerateMatches(in: text, options: [], range: full) { m, _, _ in
                guard let m else { return }
                let range = m.range(at: group)
                guard range.location != NSNotFound, range.length > 0 else { return }
                out.append(Span(range: range, color: color))
            }
        }

        paint(r.capitalized, theme.type)
        paint(r.function, theme.function, group: 1)
        paint(r.number, theme.number)
        paint(r.types, theme.type)
        paint(r.literals, theme.number)
        paint(r.keywords, theme.keyword)
        paint(r.decorator, theme.attribute)
        paint(r.preprocessor, theme.attribute)
        paint(r.cssProperty, theme.function)
        paint(r.jsonKey, theme.function)
        if language.id == "css" { paint(r.tag, theme.tagColor, group: 2) } else { paint(r.tag, theme.tagColor) }
        paint(r.attributeName, theme.attribute)
        paint(r.mdEmphasis, theme.type)
        paint(r.mdLink, theme.function)
        paint(r.mdHeading, theme.keyword)

        // Strings and comments last so they win over everything inside them.
        let commentColor = UIColor(hex: theme.comment), stringColor = UIColor(hex: theme.string)
        scanStringsAndComments(text, language: language) { range, isComment in
            out.append(Span(range: range, color: isComment ? commentColor : stringColor))
        }
        return out
    }

    /// Only touches colors, so UIKit redraws without re-laying out the text.
    static func applyColors(_ spans: [Span], to storage: NSTextStorage, foreground: UIColor) {
        let len = storage.length
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: foreground, range: NSRange(location: 0, length: len))
        for s in spans where NSMaxRange(s.range) <= len {
            storage.addAttribute(.foregroundColor, value: s.color, range: s.range)
        }
        storage.endEditing()
    }

    /// Single pass over UTF-16 so ranges line up with NSString.
    static func scanStringsAndComments(_ text: String, language: LanguageDef, _ found: (NSRange, Bool) -> Void) {
        let u = Array(text.utf16)
        let n = u.count
        if n == 0 { return }
        let line = language.lineComment.map { Array($0.utf16) }
        let blockStart = language.blockCommentStart.map { Array($0.utf16) }
        let blockEnd = language.blockCommentEnd.map { Array($0.utf16) }
        let quotes = language.allQuotes.map { Array($0.utf16) }
        let isMarkup = language.markup ?? false
        let isMarkdown = language.id == "markdown"

        @inline(__always) func matches(_ p: [UInt16], at i: Int) -> Bool {
            if i + p.count > n { return false }
            var k = 0
            while k < p.count { if u[i + k] != p[k] { return false }; k += 1 }
            return true
        }

        var insideTag = false
        var i = 0
        while i < n {
            let c = u[i]
            if isMarkup {
                if c == 60 { insideTag = true }        // <
                else if c == 62 { insideTag = false }  // >
            }
            if let bs = blockStart, let be = blockEnd, matches(bs, at: i) {
                var j = i + bs.count
                while j < n && !matches(be, at: j) { j += 1 }
                j = min(n, j + be.count)
                found(NSRange(location: i, length: j - i), true)
                i = j
                continue
            }
            if let lc = line, matches(lc, at: i) {
                // Avoid treating "#" inside words (like C# or $#) as a comment start for shell-ish languages.
                let prevOK = lc != [35] || i == 0 || u[i - 1] == 32 || u[i - 1] == 9 || u[i - 1] == 10
                if prevOK {
                    var j = i
                    while j < n && u[j] != 10 { j += 1 }
                    found(NSRange(location: i, length: j - i), true)
                    i = j
                    continue
                }
            }
            if !isMarkup || insideTag {
                var matched = false
                for q in quotes where matches(q, at: i) {
                    // Skip apostrophes inside words (it's, don't) in markdown-ish text.
                    if isMarkdown && !q.allSatisfy({ $0 == 96 }) { continue }
                    var j = i + q.count
                    var closed = false
                    while j < n {
                        if u[j] == 92 && !isMarkdown { j += 2; continue }
                        if matches(q, at: j) { j += q.count; closed = true; break }
                        if q.count == 1 && u[j] == 10 && !(isMarkdown) { break }
                        j += 1
                    }
                    j = min(j, n)
                    if closed || q.count > 1 || !isMarkdown {
                        found(NSRange(location: i, length: j - i), false)
                        i = j
                        matched = true
                    }
                    break
                }
                if matched { continue }
            }
            i += 1
        }
    }
}

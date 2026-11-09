import Foundation

/// Operational transformation for text, the same algorithm the server runs (accounts/ot.js).
/// An operation walks the whole document: keep n characters, delete n, or insert text.
/// Lengths are UTF-16 code units, exactly like NSString / UITextView ranges.
enum OTComp: Equatable {
    case retain(Int)
    case insert(String)
    case delete(Int)
}

struct TextOp: Equatable {
    var comps: [OTComp] = []
    /// Optional id so a resend after reconnecting can be recognised.
    var id: String?

    static func == (a: TextOp, b: TextOp) -> Bool { a.comps == b.comps }

    static func len(_ s: String) -> Int { s.utf16.count }
    private static func slice(_ s: String, _ from: Int, _ to: Int? = nil) -> String {
        let ns = s as NSString
        let end = to ?? ns.length
        return ns.substring(with: NSRange(location: from, length: end - from))
    }

    mutating func push(_ c: OTComp) {
        switch c {
        case .retain(let n) where n == 0, .delete(let n) where n == 0: return
        case .insert(let s) where s.isEmpty: return
        default: break
        }
        if let last = comps.last {
            switch (last, c) {
            case (.retain(let a), .retain(let b)): comps[comps.count - 1] = .retain(a + b); return
            case (.delete(let a), .delete(let b)): comps[comps.count - 1] = .delete(a + b); return
            case (.insert(let a), .insert(let b)): comps[comps.count - 1] = .insert(a + b); return
            default: break
            }
        }
        comps.append(c)
    }

    var baseLength: Int {
        comps.reduce(0) { n, c in
            switch c { case .retain(let k), .delete(let k): return n + k; case .insert: return n }
        }
    }

    // MARK: JSON (retain = positive number, delete = negative number, insert = string)

    var json: [Any] {
        comps.map { c -> Any in
            switch c { case .retain(let n): return n; case .delete(let n): return -n; case .insert(let s): return s }
        }
    }

    init(comps: [OTComp] = [], id: String? = nil) { self.comps = comps; self.id = id }

    init?(json: Any?) {
        guard let arr = json as? [Any] else { return nil }
        for x in arr {
            if let s = x as? String { push(.insert(s)) }
            else if let n = (x as? NSNumber)?.intValue, n != 0 { push(n > 0 ? .retain(n) : .delete(-n)) }
            else { return nil }
        }
    }

    // MARK: Apply

    func apply(_ text: String) throws -> String {
        let ns = text as NSString
        guard baseLength == ns.length else { throw NSError(domain: "OT", code: 1, userInfo: [NSLocalizedDescriptionKey: "Edit doesn't fit the file."]) }
        let out = NSMutableString(capacity: ns.length + 16)
        var i = 0
        for c in comps {
            switch c {
            case .retain(let n): out.append(ns.substring(with: NSRange(location: i, length: n))); i += n
            case .delete(let n): i += n
            case .insert(let s): out.append(s)
            }
        }
        return out as String
    }

    /// The same edit as a list of range replacements, applied one after another.
    var edits: [(NSRange, String)] {
        var out: [(NSRange, String)] = []
        var pos = 0
        for c in comps {
            switch c {
            case .retain(let n): pos += n
            case .delete(let n): out.append((NSRange(location: pos, length: n), ""))
            case .insert(let s): out.append((NSRange(location: pos, length: 0), s)); pos += TextOp.len(s)
            }
        }
        return out
    }

    /// Where a position in the old text ends up after this edit.
    func transformIndex(_ idx: Int) -> Int {
        var pos = 0, newPos = 0
        for c in comps {
            switch c {
            case .retain(let n):
                if idx < pos + n { return newPos + (idx - pos) }
                pos += n; newPos += n
            case .delete(let n):
                if idx < pos + n { return newPos }
                pos += n
            case .insert(let s):
                newPos += TextOp.len(s)
            }
        }
        return newPos + max(0, idx - pos)
    }

    // MARK: Diff

    /// One edit that turns `old` into `new` (common start and end kept). nil if they're equal.
    static func diff(_ old: String, _ new: String) -> TextOp? {
        if old == new { return nil }
        let a = old as NSString, b = new as NSString
        let la = a.length, lb = b.length
        var ca = [unichar](repeating: 0, count: la), cb = [unichar](repeating: 0, count: lb)
        a.getCharacters(&ca, range: NSRange(location: 0, length: la))
        b.getCharacters(&cb, range: NSRange(location: 0, length: lb))
        var p = 0
        let m = min(la, lb)
        while p < m && ca[p] == cb[p] { p += 1 }
        if p > 0 && UTF16.isLeadSurrogate(ca[p - 1]) { p -= 1 }
        var s = 0
        while s < m - p && ca[la - 1 - s] == cb[lb - 1 - s] { s += 1 }
        if s > 0 && UTF16.isTrailSurrogate(ca[la - s]) { s -= 1 }
        var op = TextOp()
        op.push(.retain(p))
        op.push(.delete(la - p - s))
        if lb - p - s > 0 { op.push(.insert(b.substring(with: NSRange(location: p, length: lb - p - s)))) }
        op.push(.retain(s))
        return op
    }

    // MARK: Transform & compose (ported from ot.js; see accounts/ot.js)

    /// (a', b') so that applying a then b' equals b then a'. a's inserts go first on ties.
    static func transform(_ a: TextOp, _ b: TextOp) throws -> (TextOp, TextOp) {
        var pa = TextOp(), pb = TextOp()
        var i = 0, j = 0
        var x: OTComp? = a.comps.first, y: OTComp? = b.comps.first
        func nx() { i += 1; x = i < a.comps.count ? a.comps[i] : nil }
        func ny() { j += 1; y = j < b.comps.count ? b.comps[j] : nil }
        while x != nil || y != nil {
            if case .insert(let s)? = x { pa.push(.insert(s)); pb.push(.retain(len(s))); nx(); continue }
            if case .insert(let s)? = y { pa.push(.retain(len(s))); pb.push(.insert(s)); ny(); continue }
            guard let cx = x, let cy = y else { throw NSError(domain: "OT", code: 2) }
            switch (cx, cy) {
            case (.retain(let p), .retain(let q)):
                let m = min(p, q); pa.push(.retain(m)); pb.push(.retain(m))
                if p > q { x = .retain(p - q); ny() } else if p == q { nx(); ny() } else { y = .retain(q - p); nx() }
            case (.delete(let p), .delete(let q)):
                if p > q { x = .delete(p - q); ny() } else if p == q { nx(); ny() } else { y = .delete(q - p); nx() }
            case (.delete(let p), .retain(let q)):
                let m = min(p, q); pa.push(.delete(m))
                if p > q { x = .delete(p - q); ny() } else if p == q { nx(); ny() } else { y = .retain(q - p); nx() }
            case (.retain(let p), .delete(let q)):
                let m = min(p, q); pb.push(.delete(m))
                if p > q { x = .retain(p - q); ny() } else if p == q { nx(); ny() } else { y = .delete(q - p); nx() }
            default:
                throw NSError(domain: "OT", code: 3)
            }
        }
        return (pa, pb)
    }

    /// One edit that does `a` then `b`.
    static func compose(_ a: TextOp, _ b: TextOp) throws -> TextOp {
        var out = TextOp()
        var i = 0, j = 0
        var x: OTComp? = a.comps.first, y: OTComp? = b.comps.first
        func nx() { i += 1; x = i < a.comps.count ? a.comps[i] : nil }
        func ny() { j += 1; y = j < b.comps.count ? b.comps[j] : nil }
        while x != nil || y != nil {
            if case .delete(let n)? = x { out.push(.delete(n)); nx(); continue }
            if case .insert(let s)? = y { out.push(.insert(s)); ny(); continue }
            guard let cx = x, let cy = y else { throw NSError(domain: "OT", code: 4) }
            switch (cx, cy) {
            case (.retain(let p), .retain(let q)):
                out.push(.retain(min(p, q)))
                if p > q { x = .retain(p - q); ny() } else if p == q { nx(); ny() } else { y = .retain(q - p); nx() }
            case (.insert(let s), .delete(let q)):
                let l = len(s)
                if l > q { x = .insert(slice(s, q)); ny() } else if l == q { nx(); ny() } else { y = .delete(q - l); nx() }
            case (.insert(let s), .retain(let q)):
                let l = len(s)
                if l > q { out.push(.insert(slice(s, 0, q))); x = .insert(slice(s, q)); ny() }
                else if l == q { out.push(.insert(s)); nx(); ny() }
                else { out.push(.insert(s)); y = .retain(q - l); nx() }
            case (.retain(let p), .delete(let q)):
                if p > q { out.push(.delete(q)); x = .retain(p - q); ny() }
                else if p == q { out.push(.delete(q)); nx(); ny() }
                else { out.push(.delete(p)); y = .delete(q - p); nx() }
            default:
                throw NSError(domain: "OT", code: 5)
            }
        }
        return out
    }
}

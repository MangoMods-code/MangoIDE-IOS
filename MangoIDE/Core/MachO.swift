import Foundation

/// What's inside a compiled binary (.dylib, framework binary, executable): read from its headers only,
/// so even a huge file opens instantly.
struct MachOSlice: Identifiable {
    struct Library: Identifiable { let id = UUID(); let name: String; let kind: String; let version: String }
    struct Segment: Identifiable { let id = UUID(); let name: String; let size: UInt64 }

    let id = UUID()
    var arch = "unknown"
    var fileType = "unknown"
    var bits = 64
    var size = 0
    var installName: String?
    var libraries: [Library] = []
    var rpaths: [String] = []
    var segments: [Segment] = []
    var uuid: String?
    var platform: String?
    var minOS: String?
    var sdk: String?
    var encrypted: Bool?
    var signed = false
    var hasEntryPoint = false
}

private extension Data {
    /// Little-endian unless `big`. Out-of-range reads return 0 instead of crashing on damaged files.
    func u32(_ o: Int, big: Bool = false) -> UInt32 {
        guard o >= 0, o + 4 <= count else { return 0 }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(self[startIndex + o + i]) }
        return big ? v : v.byteSwapped
    }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | (UInt64(u32(o + 4)) << 32) }
    func cstring(_ o: Int, limit: Int) -> String {
        guard o >= 0, o < count else { return "" }
        let end = Swift.min(count, Swift.max(o, limit))
        var bytes: [UInt8] = []
        var i = o
        while i < end, self[startIndex + i] != 0 { bytes.append(self[startIndex + i]); i += 1 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum MachO {
    private static let thin64: UInt32 = 0xcffaedfe, thin32: UInt32 = 0xcefaedfe
    private static let fat: UInt32 = 0xcafebabe, fat64: UInt32 = 0xcafebabf

    /// True if the first bytes look like a Mach-O binary (thin or universal).
    static func isMachO(_ head: Data) -> Bool {
        guard head.count >= 8 else { return false }
        let magic = head.u32(0, big: true)
        if magic == thin64 || magic == thin32 { return true }
        // Java .class files share the universal magic; they never have fewer than 45 "architectures".
        return (magic == fat || magic == fat64) && (1...20).contains(Int(head.u32(4, big: true)))
    }

    static func parse(_ url: URL) -> [MachOSlice]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        func read(_ offset: UInt64, _ length: Int) -> Data {
            guard (try? fh.seek(toOffset: offset)) != nil else { return Data() }
            return (try? fh.read(upToCount: length)) ?? Data()
        }
        let fileSize = Int((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let head = read(0, 4096)
        guard isMachO(head) else { return nil }
        let magic = head.u32(0, big: true)
        var slices: [MachOSlice] = []
        if magic == fat || magic == fat64 {
            let n = Int(head.u32(4, big: true))
            let entry = magic == fat64 ? 32 : 20
            for i in 0..<n {
                let p = 8 + i * entry
                let offset: UInt64, size: UInt64
                if magic == fat64 {
                    offset = (UInt64(head.u32(p + 8, big: true)) << 32) | UInt64(head.u32(p + 12, big: true))
                    size = (UInt64(head.u32(p + 16, big: true)) << 32) | UInt64(head.u32(p + 20, big: true))
                } else {
                    offset = UInt64(head.u32(p + 8, big: true)); size = UInt64(head.u32(p + 12, big: true))
                }
                if let s = slice(read, offset, Int(size)) { slices.append(s) }
            }
        } else if let s = slice(read, 0, fileSize) {
            slices.append(s)
        }
        return slices.isEmpty ? nil : slices
    }

    private static func version(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xff).\(v & 0xff)" }

    private static func slice(_ read: (UInt64, Int) -> Data, _ offset: UInt64, _ size: Int) -> MachOSlice? {
        let h = read(offset, 32)
        let magic = h.u32(0, big: true)
        guard magic == thin64 || magic == thin32 else { return nil }
        var s = MachOSlice()
        s.bits = magic == thin64 ? 64 : 32
        s.size = size
        let cpu = h.u32(4), sub = h.u32(8) & 0x00ff_ffff
        switch cpu {
        case 0x0100_000c: s.arch = sub == 2 ? "arm64e" : "arm64"
        case 0x0200_000c: s.arch = "arm64_32"
        case 12: s.arch = sub == 11 ? "armv7s" : sub == 9 ? "armv7" : "arm"
        case 0x0100_0007: s.arch = "x86_64"
        case 7: s.arch = "i386"
        default: s.arch = "cpu \(cpu)"
        }
        switch h.u32(12) {
        case 1: s.fileType = "Object file"
        case 2: s.fileType = "Executable"
        case 6: s.fileType = "Dynamic library (dylib)"
        case 7: s.fileType = "Dynamic linker"
        case 8: s.fileType = "Bundle"
        case 9: s.fileType = "Stub library"
        case 10: s.fileType = "Debug symbols (dSYM)"
        case 11: s.fileType = "Kernel extension"
        default: s.fileType = "Type \(h.u32(12))"
        }
        let ncmds = Int(h.u32(16))
        let cmds = read(offset + UInt64(s.bits == 64 ? 32 : 28), min(Int(h.u32(20)), 8 * 1024 * 1024))
        var p = 0
        for _ in 0..<min(ncmds, 20000) {
            let cmd = cmds.u32(p), len = Int(cmds.u32(p + 4))
            guard len >= 8, p + len <= cmds.count else { break }
            switch cmd {
            case 0x19:  // LC_SEGMENT_64
                s.segments.append(.init(name: cmds.cstring(p + 8, limit: p + 24), size: cmds.u64(p + 48)))
            case 0x1:   // LC_SEGMENT
                s.segments.append(.init(name: cmds.cstring(p + 8, limit: p + 24), size: UInt64(cmds.u32(p + 36))))
            case 0xd:   // LC_ID_DYLIB
                s.installName = cmds.cstring(p + Int(cmds.u32(p + 8)), limit: p + len)
            case 0xc, 0x8000_0018, 0x8000_001f, 0x20, 0x8000_0023:
                let kind = cmd == 0x8000_0018 ? "weak" : cmd == 0x8000_001f ? "re-exported" : cmd == 0x20 ? "lazy" : cmd == 0x8000_0023 ? "upward" : ""
                s.libraries.append(.init(name: cmds.cstring(p + Int(cmds.u32(p + 8)), limit: p + len), kind: kind, version: version(cmds.u32(p + 16))))
            case 0x8000_001c:  // LC_RPATH
                s.rpaths.append(cmds.cstring(p + Int(cmds.u32(p + 8)), limit: p + len))
            case 0x1b:  // LC_UUID
                if p + 24 <= cmds.count {
                    let b = (0..<16).map { String(format: "%02X", cmds[cmds.startIndex + p + 8 + $0]) }
                    s.uuid = [b[0..<4], b[4..<6], b[6..<8], b[8..<10], b[10..<16]].map { $0.joined() }.joined(separator: "-")
                }
            case 0x32:  // LC_BUILD_VERSION
                let names: [UInt32: String] = [1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 5: "bridgeOS", 6: "Mac Catalyst",
                                               7: "iOS Simulator", 8: "tvOS Simulator", 9: "watchOS Simulator", 11: "visionOS"]
                s.platform = names[cmds.u32(p + 8)] ?? "Platform \(cmds.u32(p + 8))"
                s.minOS = version(cmds.u32(p + 12)); s.sdk = version(cmds.u32(p + 16))
            case 0x24, 0x25, 0x2f, 0x30:  // LC_VERSION_MIN_*
                s.platform = [0x24: "macOS", 0x25: "iOS", 0x2f: "tvOS", 0x30: "watchOS"][Int(cmd)]
                s.minOS = version(cmds.u32(p + 8)); s.sdk = version(cmds.u32(p + 12))
            case 0x21, 0x2c:  // LC_ENCRYPTION_INFO(_64)
                s.encrypted = cmds.u32(p + 16) != 0
            case 0x1d: s.signed = true
            case 0x8000_0028: s.hasEntryPoint = true
            default: break
            }
            p += len
        }
        return s
    }
}

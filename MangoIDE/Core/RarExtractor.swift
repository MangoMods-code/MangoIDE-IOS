import Foundation
import Unrar

/// RAR extraction (RAR 4 and 5). Kept in its own file because Unrar and ZIPFoundation both
/// define a type called `Archive`.
enum RarExtractor {
    static func extract(_ url: URL, to dest: URL, password: String?) throws {
        let fm = FileManager.default
        let pw = (password?.isEmpty ?? true) ? nil : password
        let archive: Unrar.Archive
        do {
            archive = try Unrar.Archive(fileURL: url, password: pw)
        } catch let e as UnrarError {
            throw map(e, hadPassword: pw != nil)
        }
        let entries: [Entry]
        do { entries = try archive.entries() }
        catch let e as UnrarError { throw map(e, hadPassword: pw != nil) }

        if pw == nil && entries.contains(where: { $0.encrypted }) { throw ArchiveError.needsPassword }

        for entry in entries {
            guard let target = ArchiveService.safeURL(for: entry.fileName, under: dest) else { continue }
            if entry.directory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: target.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: target) else {
                throw ArchiveError.failed("Couldn't write \(entry.fileName).")
            }
            defer { try? handle.close() }
            do {
                try archive.extract(entry) { data, _ in handle.write(data) }
            } catch let e as UnrarError {
                throw map(e, hadPassword: pw != nil)
            }
        }
    }

    private static func map(_ e: UnrarError, hadPassword: Bool) -> Error {
        switch e {
        case .missingPassword: return hadPassword ? ArchiveError.wrongPassword : ArchiveError.needsPassword
        case .badData: return hadPassword ? ArchiveError.wrongPassword : ArchiveError.failed("The archive looks damaged.")
        case .badArchive, .unknownFormat: return ArchiveError.failed("That isn't a RAR file MangoIDE can read.")
        case .eopen: return ArchiveError.failed("Couldn't open the archive.")
        case .noMemory: return ArchiveError.failed("Not enough memory to extract this archive.")
        default: return ArchiveError.failed("Couldn't extract the RAR archive.")
        }
    }
}

import Foundation

/// Reads the app's own signing profile (embedded.mobileprovision).
enum SigningInfo {
    struct Profile {
        let name: String
        let team: String
        let appIdentifier: String   // e.g. "ABCDE12345.com.example.app" or "ABCDE12345.*"
        let entitlements: [String: Any]

        /// The bundle ID part of the app identifier (without the team prefix).
        var profileBundleID: String {
            guard let dot = appIdentifier.firstIndex(of: ".") else { return appIdentifier }
            return String(appIdentifier[appIdentifier.index(after: dot)...])
        }

        /// iOS hands file/folder access to apps by identity. If the profile was made for a different
        /// app ID than the one this app runs as, "open in place" access is refused.
        var mismatchesBundleID: Bool {
            let pattern = profileBundleID
            let actual = Bundle.main.bundleIdentifier ?? ""
            if pattern == "*" { return false }
            if pattern.hasSuffix(".*") { return !actual.hasPrefix(String(pattern.dropLast(1))) }
            return pattern != actual
        }
    }

    static let profile: Profile? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<?xml"), let end = raw.range(of: "</plist>"),
              let plistData = String(raw[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else { return nil }
        let ent = plist["Entitlements"] as? [String: Any] ?? [:]
        return Profile(name: plist["Name"] as? String ?? "?",
                       team: plist["TeamName"] as? String ?? "?",
                       appIdentifier: ent["application-identifier"] as? String ?? "",
                       entitlements: ent)
    }()

    static var explanation: String? {
        guard let p = profile, p.mismatchesBundleID else { return nil }
        let appID = Bundle.main.bundleIdentifier ?? "this app's ID"
        return "iOS refused access to that location. This copy of MangoIDE (\(appID)) was signed with a profile made for a different app (\(p.profileBundleID)), and iOS only gives folder and open-in-place access to the app a profile was made for.\n\nFix: re-sign MangoIDE in Mango Signer so the profile is made for \(appID). Importing (copying) files still works either way."
    }
}

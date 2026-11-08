import Foundation
import UIKit
import ZIPFoundation

/// Minecraft Bedrock add-ons: .mcaddon / .mcpack / .mcworld / .mctemplate are zip files.
enum Minecraft {
    static let fileTypes: Set<String> = ["mcaddon", "mcpack", "mcworld", "mctemplate"]

    static func isPack(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path)
    }

    /// Pack folders directly inside `folder` (each has a manifest.json).
    static func packs(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { Workspace.shared.isDirectory($0) && isPack($0) }
    }

    /// After unzipping an .mcaddon, open up the .mcpack/.mcworld files inside it too.
    static func expandNested(in folder: URL) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        var nested: [URL] = []
        for case let u as URL in en where fileTypes.contains(u.pathExtension.lowercased()) || u.pathExtension.lowercased() == "zip" {
            nested.append(u)
            if nested.count > 50 { break }
        }
        for u in nested {
            let dest = Workspace.shared.uniqueURL(in: u.deletingLastPathComponent(), name: u.deletingPathExtension().lastPathComponent)
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try fm.unzipItem(at: u, to: dest)
                try? fm.removeItem(at: u)
            } catch {
                try? fm.removeItem(at: dest)
            }
        }
    }

    enum ExportKind { case mcpack, mcaddon }

    /// Decides what a folder should become: a single pack → .mcpack, a folder of packs → .mcaddon.
    static func exportKind(for folder: URL) -> ExportKind? {
        if isPack(folder) { return .mcpack }
        return packs(in: folder).isEmpty ? nil : .mcaddon
    }

    /// Zips the folder's contents (manifest at the top level, the way Minecraft expects).
    static func export(_ folder: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error>
            if let kind = exportKind(for: folder) {
                let ext = kind == .mcpack ? "mcpack" : "mcaddon"
                let out = Workspace.shared.uniqueURL(in: folder.deletingLastPathComponent(), name: folder.lastPathComponent + "." + ext)
                do {
                    try FileManager.default.zipItem(at: folder, to: out, shouldKeepParent: false, compressionMethod: .deflate)
                    result = .success(out)
                } catch {
                    result = .failure(ArchiveError.failed("Couldn't build the \(ext): \(error.localizedDescription)"))
                }
            } else {
                result = .failure(ArchiveError.failed("No manifest.json found. Export a pack folder (one with manifest.json) or a folder that holds your behavior and resource packs."))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: New add-on template

    /// Creates a working add-on: a behavior pack and a resource pack linked to each other, with a custom
    /// "Mango" item, its texture, a sample function and an English name file. Returns the behavior manifest.
    static func createAddon(named name: String, in parent: URL) throws -> URL {
        let fm = FileManager.default
        let root = parent.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: root.path) { throw WorkspaceError.exists(name) }
        let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(20)
        let ns = slug.isEmpty ? "mango" : String(slug)
        let bp = root.appendingPathComponent("\(name) BP", isDirectory: true)
        let rp = root.appendingPathComponent("\(name) RP", isDirectory: true)
        let bpHeader = UUID().uuidString.lowercased(), bpModule = UUID().uuidString.lowercased()
        let rpHeader = UUID().uuidString.lowercased(), rpModule = UUID().uuidString.lowercased()

        func write(_ text: String, _ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        try write("""
        {
          "format_version": 2,
          "header": {
            "name": "\(name) BP",
            "description": "Behavior pack made with MangoIDE",
            "uuid": "\(bpHeader)",
            "version": [1, 0, 0],
            "min_engine_version": [1, 21, 0]
          },
          "modules": [
            { "type": "data", "uuid": "\(bpModule)", "version": [1, 0, 0] }
          ],
          "dependencies": [
            { "uuid": "\(rpHeader)", "version": [1, 0, 0] }
          ]
        }
        """, bp.appendingPathComponent("manifest.json"))

        try write("""
        {
          "format_version": 2,
          "header": {
            "name": "\(name) RP",
            "description": "Resource pack made with MangoIDE",
            "uuid": "\(rpHeader)",
            "version": [1, 0, 0],
            "min_engine_version": [1, 21, 0]
          },
          "modules": [
            { "type": "resources", "uuid": "\(rpModule)", "version": [1, 0, 0] }
          ],
          "dependencies": [
            { "uuid": "\(bpHeader)", "version": [1, 0, 0] }
          ]
        }
        """, rp.appendingPathComponent("manifest.json"))

        try write("""
        {
          "format_version": "1.21.0",
          "minecraft:item": {
            "description": {
              "identifier": "\(ns):mango",
              "menu_category": { "category": "items" }
            },
            "components": {
              "minecraft:icon": "\(ns)_mango",
              "minecraft:display_name": { "value": "Mango" },
              "minecraft:max_stack_size": 64,
              "minecraft:food": { "nutrition": 6, "saturation_modifier": 0.8, "can_always_eat": true },
              "minecraft:use_animation": "eat",
              "minecraft:use_modifiers": { "use_duration": 1.6 }
            }
          }
        }
        """, bp.appendingPathComponent("items/mango.json"))

        try write("""
        # Run in game with: /function hello
        say Hello from \(name)!
        give @s \(ns):mango 3
        """, bp.appendingPathComponent("functions/hello.mcfunction"))

        try write("""
        {
          "resource_pack_name": "\(ns)",
          "texture_name": "atlas.items",
          "texture_data": {
            "\(ns)_mango": { "textures": "textures/items/mango" }
          }
        }
        """, rp.appendingPathComponent("textures/item_texture.json"))

        try write("item.\(ns):mango=Mango\npack.name=\(name)\npack.description=Made with MangoIDE\n", rp.appendingPathComponent("texts/en_US.lang"))
        try write("[\"en_US\"]\n", rp.appendingPathComponent("texts/languages.json"))

        let texture = rp.appendingPathComponent("textures/items/mango.png")
        try fm.createDirectory(at: texture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try mangoTexture().write(to: texture)
        let icon = mangoTexture(size: 64)
        try icon.write(to: bp.appendingPathComponent("pack_icon.png"))
        try icon.write(to: rp.appendingPathComponent("pack_icon.png"))

        try write("""
        # \(name)

        A Minecraft Bedrock add-on made with MangoIDE.

        - **\(name) BP** – behavior pack (items, functions)
        - **\(name) RP** – resource pack (textures, names)

        Long-press the **\(name)** folder › Minecraft › Export & Open in Minecraft to try it.
        In game: turn on the packs for your world, then run `/function hello`.
        """, root.appendingPathComponent("README.md"))

        Workspace.shared.refresh()
        return bp.appendingPathComponent("items/mango.json")
    }

    /// A tiny pixel-art mango, made on the fly so the template has a real texture.
    static func mangoTexture(size: Int = 16) -> Data {
        let px: [String] = [
            "................",
            "..........gg....",
            ".........gg.....",
            "........b.......",
            "......oooo......",
            "....oyyyyoo.....",
            "...oyyyyyyoo....",
            "..oyyywyyyyoo...",
            "..oyyyyyyyyro...",
            "..oyyyyyyyrro...",
            "..ooyyyyyrrro...",
            "...ooyyyrrrro...",
            "....oorrrrro....",
            "......ooooo.....",
            "................",
            "................"
        ]
        let colors: [Character: UIColor] = ["g": UIColor(hex: "#4CAF50"), "b": UIColor(hex: "#6D4C41"), "o": UIColor(hex: "#E65100"),
                                            "y": UIColor(hex: "#FFC107"), "r": UIColor(hex: "#FF7043"), "w": UIColor(hex: "#FFF59D")]
        let scale = CGFloat(size) / 16
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            for (y, row) in px.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = colors[ch] else { continue }
                    c.setFill()
                    ctx.fill(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale))
                }
            }
        }
        return img.pngData() ?? Data()
    }

    /// Opens the iOS share sheet so the file can go straight to Minecraft.
    static func share(_ url: URL) {
        guard let top = FilePicker.topViewController() else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        top.present(vc, animated: true)
    }
}

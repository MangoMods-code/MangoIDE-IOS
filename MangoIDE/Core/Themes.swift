import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: CGFloat
        switch s.count {
        case 8:
            r = CGFloat((value >> 24) & 0xFF) / 255; g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255; a = CGFloat(value & 0xFF) / 255
        case 3:
            r = CGFloat((value >> 8) & 0xF) / 15; g = CGFloat((value >> 4) & 0xF) / 15
            b = CGFloat(value & 0xF) / 15; a = 1
        default:
            r = CGFloat((value >> 16) & 0xFF) / 255; g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255; a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
}

/// An editor color theme. Extensions can add more with the same JSON shape.
struct EditorTheme: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var isDark: Bool
    var background: String
    var foreground: String
    var gutterBackground: String
    var gutterForeground: String
    var gutterActive: String
    var selection: String
    var cursor: String
    var keyword: String
    var type: String
    var string: String
    var number: String
    var comment: String
    var function: String
    var attribute: String
    var tag: String?
    var panel: String?
    /// Whole-app look (all optional so older/extension themes still work).
    var accent: String?
    var chrome: String?
    var chromeText: String?
    var category: String?
    var effect: String?
    var fontDesign: String?
    var emoji: String?

    var bg: UIColor { UIColor(hex: background) }
    var fg: UIColor { UIColor(hex: foreground) }
    var panelColor: Color { Color(hex: panel ?? gutterBackground) }
    var tagColor: String { tag ?? keyword }
    var accentColor: Color { Color(hex: accent ?? cursor) }
    var chromeColor: Color { Color(hex: chrome ?? panel ?? gutterBackground) }
    var chromeTextColor: Color { Color(hex: chromeText ?? foreground) }
    var group: String { category ?? "Classic" }

    var design: Font.Design {
        switch fontDesign {
        case "rounded": return .rounded
        case "serif": return .serif
        case "monospaced": return .monospaced
        default: return .default
        }
    }
}

enum ThemeLibrary {
    static let groups = ["Classic", "Dev Favorites", "Vibrant", "Holidays"]

    /// Compact way to define a theme: the rest of the colors are derived.
    private static func make(_ id: String, _ name: String, _ category: String, dark: Bool,
                             bg: String, fg: String, comment: String, keyword: String, type: String,
                             string: String, number: String, function: String, attribute: String,
                             accent: String, chrome: String, effect: String? = nil, font: String? = nil,
                             emoji: String? = nil) -> EditorTheme {
        EditorTheme(id: id, name: name, isDark: dark, background: bg, foreground: fg,
                    gutterBackground: bg, gutterForeground: comment, gutterActive: accent,
                    selection: accent + "44", cursor: accent, keyword: keyword, type: type, string: string,
                    number: number, comment: comment, function: function, attribute: attribute,
                    tag: keyword, panel: chrome, accent: accent, chrome: chrome, chromeText: fg,
                    category: category, effect: effect, fontDesign: font, emoji: emoji)
    }

    static let builtIn: [EditorTheme] = classic + extra

    static let extra: [EditorTheme] = [
        // Dev favorites
        make("tokyo-night", "Tokyo Night", "Dev Favorites", dark: true, bg: "#1A1B26", fg: "#C0CAF5", comment: "#565F89", keyword: "#BB9AF7", type: "#2AC3DE", string: "#9ECE6A", number: "#FF9E64", function: "#7AA2F7", attribute: "#E0AF68", accent: "#7AA2F7", chrome: "#16161E"),
        make("catppuccin-mocha", "Catppuccin Mocha", "Dev Favorites", dark: true, bg: "#1E1E2E", fg: "#CDD6F4", comment: "#6C7086", keyword: "#CBA6F7", type: "#F9E2AF", string: "#A6E3A1", number: "#FAB387", function: "#89B4FA", attribute: "#F38BA8", accent: "#CBA6F7", chrome: "#181825", font: "rounded"),
        make("catppuccin-latte", "Catppuccin Latte", "Dev Favorites", dark: false, bg: "#EFF1F5", fg: "#4C4F69", comment: "#9CA0B0", keyword: "#8839EF", type: "#DF8E1D", string: "#40A02B", number: "#FE640B", function: "#1E66F5", attribute: "#D20F39", accent: "#8839EF", chrome: "#E6E9EF", font: "rounded"),
        make("gruvbox-dark", "Gruvbox Dark", "Dev Favorites", dark: true, bg: "#282828", fg: "#EBDBB2", comment: "#928374", keyword: "#FB4934", type: "#FABD2F", string: "#B8BB26", number: "#D3869B", function: "#8EC07C", attribute: "#FE8019", accent: "#FE8019", chrome: "#1D2021"),
        make("gruvbox-light", "Gruvbox Light", "Dev Favorites", dark: false, bg: "#FBF1C7", fg: "#3C3836", comment: "#928374", keyword: "#9D0006", type: "#B57614", string: "#79740E", number: "#8F3F71", function: "#427B58", attribute: "#AF3A03", accent: "#AF3A03", chrome: "#F2E5BC"),
        make("rose-pine", "Rosé Pine", "Dev Favorites", dark: true, bg: "#191724", fg: "#E0DEF4", comment: "#6E6A86", keyword: "#31748F", type: "#9CCFD8", string: "#F6C177", number: "#EBBCBA", function: "#C4A7E7", attribute: "#EB6F92", accent: "#EBBCBA", chrome: "#1F1D2E"),
        make("ayu-dark", "Ayu Dark", "Dev Favorites", dark: true, bg: "#0B0E14", fg: "#BFBDB6", comment: "#5C6773", keyword: "#FF8F40", type: "#59C2FF", string: "#AAD94C", number: "#D2A6FF", function: "#FFB454", attribute: "#F07178", accent: "#E6B450", chrome: "#0D1017"),
        make("ayu-light", "Ayu Light", "Dev Favorites", dark: false, bg: "#FCFCFC", fg: "#5C6166", comment: "#ADAEB1", keyword: "#FA8D3E", type: "#399EE6", string: "#86B300", number: "#A37ACC", function: "#F2AE49", attribute: "#F07171", accent: "#FA8D3E", chrome: "#F3F4F5"),
        make("night-owl", "Night Owl", "Dev Favorites", dark: true, bg: "#011627", fg: "#D6DEEB", comment: "#637777", keyword: "#C792EA", type: "#FFCB8B", string: "#ECC48D", number: "#F78C6C", function: "#82AAFF", attribute: "#7FDBCA", accent: "#82AAFF", chrome: "#01111D"),
        make("cobalt2", "Cobalt2", "Dev Favorites", dark: true, bg: "#193549", fg: "#FFFFFF", comment: "#0088FF", keyword: "#FF9D00", type: "#80FFBB", string: "#3AD900", number: "#FF628C", function: "#FFC600", attribute: "#FF9D00", accent: "#FFC600", chrome: "#15232D"),
        make("everforest", "Everforest", "Dev Favorites", dark: true, bg: "#2D353B", fg: "#D3C6AA", comment: "#859289", keyword: "#E67E80", type: "#DBBC7F", string: "#A7C080", number: "#D699B6", function: "#83C092", attribute: "#E69875", accent: "#A7C080", chrome: "#272E33"),
        make("kanagawa", "Kanagawa", "Dev Favorites", dark: true, bg: "#1F1F28", fg: "#DCD7BA", comment: "#727169", keyword: "#957FB8", type: "#7AA89F", string: "#98BB6C", number: "#D27E99", function: "#7E9CD8", attribute: "#FFA066", accent: "#7E9CD8", chrome: "#16161D"),
        make("palenight", "Palenight", "Dev Favorites", dark: true, bg: "#292D3E", fg: "#A6ACCD", comment: "#676E95", keyword: "#C792EA", type: "#FFCB6B", string: "#C3E88D", number: "#F78C6C", function: "#82AAFF", attribute: "#FF5370", accent: "#C792EA", chrome: "#202331"),
        make("horizon", "Horizon", "Dev Favorites", dark: true, bg: "#1C1E26", fg: "#E0E0E0", comment: "#6C6F93", keyword: "#B877DB", type: "#FAC29A", string: "#FAB795", number: "#F09483", function: "#25B0BC", attribute: "#E95678", accent: "#E95678", chrome: "#16161C"),
        make("vscode-dark", "VS Code Dark+", "Dev Favorites", dark: true, bg: "#1E1E1E", fg: "#D4D4D4", comment: "#6A9955", keyword: "#569CD6", type: "#4EC9B0", string: "#CE9178", number: "#B5CEA8", function: "#DCDCAA", attribute: "#9CDCFE", accent: "#007ACC", chrome: "#252526"),
        make("high-contrast", "High Contrast", "Dev Favorites", dark: true, bg: "#000000", fg: "#FFFFFF", comment: "#7CA668", keyword: "#569CD6", type: "#4EC9B0", string: "#CE9178", number: "#B5CEA8", function: "#DCDCAA", attribute: "#9CDCFE", accent: "#F38518", chrome: "#000000"),
        make("synthwave", "Synthwave '84", "Vibrant", dark: true, bg: "#262335", fg: "#FFFFFF", comment: "#848BBD", keyword: "#FEDE5D", type: "#FE4450", string: "#FF8B39", number: "#F97E72", function: "#36F9F6", attribute: "#FF7EDB", accent: "#FF7EDB", chrome: "#1E1A2E", effect: "stars"),

        // Vibrant
        make("matrix", "The Matrix", "Vibrant", dark: true, bg: "#000000", fg: "#00FF41", comment: "#008F11", keyword: "#00FF41", type: "#9DFF9D", string: "#00D432", number: "#6BFF6B", function: "#39FF14", attribute: "#00CC33", accent: "#00FF41", chrome: "#001100", effect: "matrix", font: "monospaced", emoji: "💊"),
        make("cyberpunk", "Cyberpunk", "Vibrant", dark: true, bg: "#0A0A12", fg: "#F3E600", comment: "#6B6B8A", keyword: "#FF2A6D", type: "#05D9E8", string: "#D1F7FF", number: "#FF9E00", function: "#01FFC3", attribute: "#FF2A6D", accent: "#FF2A6D", chrome: "#120D1F", effect: "rain", font: "monospaced", emoji: "🌃"),
        make("coffee", "Coffee House", "Vibrant", dark: true, bg: "#2B211C", fg: "#E8D9C5", comment: "#8A7563", keyword: "#D99058", type: "#E6B87D", string: "#A8C080", number: "#D4A373", function: "#C9A27E", attribute: "#B5683C", accent: "#C68B59", chrome: "#231A16", effect: "steam", font: "serif", emoji: "☕️"),
        make("lavender", "Lavender", "Vibrant", dark: false, bg: "#F7F3FF", fg: "#3F3553", comment: "#A99BC2", keyword: "#8A4FFF", type: "#B5568F", string: "#3E8E7E", number: "#D9730D", function: "#5A67D8", attribute: "#C2410C", accent: "#8A4FFF", chrome: "#EDE6FB", font: "rounded", emoji: "💜"),
        make("mint", "Mint", "Vibrant", dark: false, bg: "#F2FBF7", fg: "#22413A", comment: "#8AA8A0", keyword: "#0F9D7A", type: "#2B7A9E", string: "#4E8A2E", number: "#C2185B", function: "#11698E", attribute: "#D35400", accent: "#0F9D7A", chrome: "#E3F4EC", font: "rounded", emoji: "🌿"),
        make("bubblegum", "Bubblegum", "Vibrant", dark: false, bg: "#FFF0F7", fg: "#4A2040", comment: "#C79BB4", keyword: "#E0218A", type: "#7A4DD8", string: "#1E9E73", number: "#F06D06", function: "#2F80ED", attribute: "#D6336C", accent: "#FF4FA3", chrome: "#FFE1EE", effect: "bubbles", font: "rounded", emoji: "🍬"),
        make("amber", "Amber Terminal", "Vibrant", dark: true, bg: "#120B00", fg: "#FFB000", comment: "#7A5A00", keyword: "#FFCC00", type: "#FFD866", string: "#FFB000", number: "#FFE08A", function: "#FFC94D", attribute: "#FF9900", accent: "#FFB000", chrome: "#0D0800", font: "monospaced", emoji: "📟"),
        make("paper", "Paper", "Vibrant", dark: false, bg: "#F8F5EC", fg: "#2E2A24", comment: "#A39E93", keyword: "#7A3E9D", type: "#9C5D00", string: "#2F6F3E", number: "#B5452B", function: "#2C5F91", attribute: "#8A4B08", accent: "#2C5F91", chrome: "#EFEADD", font: "serif", emoji: "📜"),
        make("sepia", "Sepia", "Vibrant", dark: false, bg: "#F4ECD8", fg: "#5B4636", comment: "#A08C74", keyword: "#9B2C2C", type: "#8B5E3C", string: "#4E7A3A", number: "#A0522D", function: "#2F5D7C", attribute: "#7A4A1F", accent: "#A0522D", chrome: "#EADFC6", font: "serif"),
        make("deep-ocean", "Deep Ocean", "Vibrant", dark: true, bg: "#0F111A", fg: "#8F93A2", comment: "#464B5D", keyword: "#89DDFF", type: "#FFCB6B", string: "#C3E88D", number: "#F78C6C", function: "#82AAFF", attribute: "#F07178", accent: "#84FFFF", chrome: "#0B0D14", effect: "bubbles", emoji: "🌊"),
        make("sakura", "Sakura", "Vibrant", dark: true, bg: "#2A1F2D", fg: "#F5E1EA", comment: "#8E7A92", keyword: "#FF8FB1", type: "#FFD6E0", string: "#B5E8C9", number: "#F9A8D4", function: "#A0C4FF", attribute: "#FFB3C6", accent: "#FF8FB1", chrome: "#231A26", effect: "sakura", font: "rounded", emoji: "🌸"),
        make("aurora", "Aurora", "Vibrant", dark: true, bg: "#0B1021", fg: "#E6F1FF", comment: "#5B6B8C", keyword: "#7CF5C9", type: "#9AA8FF", string: "#A6F0C6", number: "#FF9AD5", function: "#6FD3FF", attribute: "#C792EA", accent: "#7CF5C9", chrome: "#080C1A", effect: "stars", emoji: "🌌"),
        make("lava", "Lava", "Vibrant", dark: true, bg: "#1A0A06", fg: "#FFE6D5", comment: "#8A5A48", keyword: "#FF5722", type: "#FFAB40", string: "#FFD180", number: "#FF8A65", function: "#FF7043", attribute: "#FF3D00", accent: "#FF5722", chrome: "#140704", effect: "embers", emoji: "🌋"),
        make("forest", "Forest", "Vibrant", dark: true, bg: "#14201A", fg: "#DDEBDD", comment: "#6E8A75", keyword: "#8BC34A", type: "#D4C36A", string: "#A5D6A7", number: "#FFB74D", function: "#81C784", attribute: "#E57373", accent: "#8BC34A", chrome: "#0F1913", effect: "fireflies", emoji: "🌲"),
        make("galaxy", "Galaxy", "Vibrant", dark: true, bg: "#0D0221", fg: "#E0D7FF", comment: "#6F5F99", keyword: "#B388FF", type: "#7DF9FF", string: "#F7AEF8", number: "#FFD166", function: "#8EC5FF", attribute: "#FF6BD6", accent: "#B388FF", chrome: "#090118", effect: "stars", emoji: "🪐"),

        // Holidays
        make("halloween", "Halloween", "Holidays", dark: true, bg: "#1A0F1F", fg: "#F4E8D8", comment: "#7A6A80", keyword: "#FF7518", type: "#B266FF", string: "#9AE66E", number: "#FFB347", function: "#FFD23F", attribute: "#FF4F4F", accent: "#FF7518", chrome: "#120A16", effect: "halloween", emoji: "🎃"),
        make("day-of-the-dead", "Día de Muertos", "Holidays", dark: true, bg: "#1B0F2E", fg: "#FFF0F5", comment: "#8D7AA6", keyword: "#FF6F00", type: "#E040FB", string: "#76FF03", number: "#FFEA00", function: "#00E5FF", attribute: "#FF4081", accent: "#FF6F00", chrome: "#140A24", effect: "marigolds", emoji: "💀"),
        make("diwali", "Diwali", "Holidays", dark: true, bg: "#1E0B24", fg: "#FFF3D6", comment: "#8A6F8E", keyword: "#FFB300", type: "#FF6F91", string: "#FFE29A", number: "#FF9E44", function: "#FFD54F", attribute: "#FF5E78", accent: "#FFB300", chrome: "#170820", effect: "diyas", emoji: "🪔"),
        make("thanksgiving", "Thanksgiving", "Holidays", dark: true, bg: "#2A1A10", fg: "#F3E3CC", comment: "#8E7058", keyword: "#E07A1F", type: "#D9A441", string: "#B5C26A", number: "#E8A87C", function: "#F2C14E", attribute: "#C1440E", accent: "#D2691E", chrome: "#221409", effect: "leaves", font: "serif", emoji: "🦃"),
        make("hanukkah", "Hanukkah", "Holidays", dark: true, bg: "#0D1B3E", fg: "#EAF2FF", comment: "#6B7FA8", keyword: "#4DA3FF", type: "#FFD24D", string: "#B8E1FF", number: "#C3D9FF", function: "#9CC9FF", attribute: "#FFE082", accent: "#4DA3FF", chrome: "#0A1631", effect: "candles", emoji: "🕎"),
        make("christmas", "Christmas", "Holidays", dark: true, bg: "#0E2A1A", fg: "#F5F5F0", comment: "#6E8F7A", keyword: "#E63946", type: "#FFD166", string: "#9AE19D", number: "#F4A261", function: "#F1FAEE", attribute: "#E9C46A", accent: "#E63946", chrome: "#0A2014", effect: "snow", emoji: "🎄"),
        make("winter", "Winter Wonderland", "Holidays", dark: false, bg: "#EEF6FC", fg: "#1F3B57", comment: "#8AA3B8", keyword: "#2E86DE", type: "#6C5CE7", string: "#0E9F6E", number: "#D6336C", function: "#1E6FB8", attribute: "#C0392B", accent: "#2E86DE", chrome: "#E1EEF8", effect: "snow", font: "rounded", emoji: "☃️"),
        make("new-years", "New Year's Eve", "Holidays", dark: true, bg: "#0A0A0F", fg: "#F5F0E1", comment: "#6F6A5F", keyword: "#FFD700", type: "#E5C07B", string: "#C9E4A6", number: "#F7C59F", function: "#F6E7B0", attribute: "#FFB347", accent: "#FFD700", chrome: "#08080C", effect: "gold", emoji: "🎉"),
        make("lunar-new-year", "Lunar New Year", "Holidays", dark: true, bg: "#2A0A0A", fg: "#FFF1E0", comment: "#9A6A5A", keyword: "#FF3B30", type: "#FFCC00", string: "#FFD9A0", number: "#FF9F43", function: "#FFD166", attribute: "#FF6B6B", accent: "#FF3B30", chrome: "#210707", effect: "lanterns", emoji: "🏮"),
        make("valentines", "Valentine's Day", "Holidays", dark: false, bg: "#FFF1F3", fg: "#4A1F2A", comment: "#C99AA5", keyword: "#E11D48", type: "#BE185D", string: "#0F766E", number: "#DB2777", function: "#7C3AED", attribute: "#F43F5E", accent: "#E11D48", chrome: "#FFE4E8", effect: "hearts", font: "rounded", emoji: "💘"),
        make("st-patricks", "St. Patrick's Day", "Holidays", dark: true, bg: "#0B2016", fg: "#E8F5E9", comment: "#6F8F77", keyword: "#2ECC71", type: "#F1C40F", string: "#A3E4A1", number: "#FFD54F", function: "#58D68D", attribute: "#E67E22", accent: "#2ECC71", chrome: "#08180F", effect: "clovers", emoji: "☘️"),
        make("easter", "Easter", "Holidays", dark: false, bg: "#FBF7FF", fg: "#3D3550", comment: "#AFA5C4", keyword: "#9B5DE5", type: "#F15BB5", string: "#00A6A6", number: "#E07A00", function: "#00BBF9", attribute: "#F15BB5", accent: "#9B5DE5", chrome: "#F3ECFF", effect: "spring", font: "rounded", emoji: "🐣"),
        make("earth-day", "Earth Day", "Holidays", dark: true, bg: "#0F2016", fg: "#E6F4EA", comment: "#6C8A74", keyword: "#34A853", type: "#4285F4", string: "#9AD0A3", number: "#FBBC05", function: "#7EC8E3", attribute: "#EA4335", accent: "#34A853", chrome: "#0B1A11", effect: "leaves", emoji: "🌍"),
        make("pride", "Pride", "Holidays", dark: true, bg: "#1A1A1A", fg: "#FFFFFF", comment: "#7A7A7A", keyword: "#FF5E5E", type: "#FFD166", string: "#7CE38B", number: "#6EC6FF", function: "#B28DFF", attribute: "#FF9E5E", accent: "#FF5E9C", chrome: "#141414", effect: "rainbow", emoji: "🏳️‍🌈"),
        make("fourth-of-july", "Fourth of July", "Holidays", dark: true, bg: "#0B1A3A", fg: "#F5F7FF", comment: "#6D7BA3", keyword: "#E63946", type: "#F1FAEE", string: "#A8DADC", number: "#FF6B6B", function: "#4EA8DE", attribute: "#FFD166", accent: "#E63946", chrome: "#081430", effect: "fireworks", emoji: "🎆")
    ]

    static let classic: [EditorTheme] = [
        EditorTheme(id: "mango-dark", name: "Mango Dark", isDark: true, background: "#1C1A24", foreground: "#E8E6F0",
                    gutterBackground: "#17151E", gutterForeground: "#5E5A70", gutterActive: "#FFAA28", selection: "#FFAA2844",
                    cursor: "#FFAA28", keyword: "#FF7A59", type: "#FFC857", string: "#9BE564", number: "#C792EA",
                    comment: "#6B6780", function: "#62B6F7", attribute: "#F78C6C", tag: "#FF7A59", panel: "#211F2A"),
        EditorTheme(id: "mango-light", name: "Mango Light", isDark: false, background: "#FFFDF8", foreground: "#2A2733",
                    gutterBackground: "#F6F1E7", gutterForeground: "#A9A3B5", gutterActive: "#E07B00", selection: "#FFB34755",
                    cursor: "#E07B00", keyword: "#D2461E", type: "#B7791F", string: "#2F8A3E", number: "#8B47C9",
                    comment: "#9C97A8", function: "#1F6FBF", attribute: "#C2410C", tag: "#D2461E", panel: "#F3EEE4"),
        EditorTheme(id: "monokai", name: "Monokai", isDark: true, background: "#272822", foreground: "#F8F8F2",
                    gutterBackground: "#22231E", gutterForeground: "#75715E", gutterActive: "#F8F8F2", selection: "#49483E",
                    cursor: "#F8F8F0", keyword: "#F92672", type: "#66D9EF", string: "#E6DB74", number: "#AE81FF",
                    comment: "#75715E", function: "#A6E22E", attribute: "#FD971F", tag: "#F92672", panel: "#1E1F1A"),
        EditorTheme(id: "dracula", name: "Dracula", isDark: true, background: "#282A36", foreground: "#F8F8F2",
                    gutterBackground: "#21222C", gutterForeground: "#6272A4", gutterActive: "#F8F8F2", selection: "#44475A",
                    cursor: "#F8F8F2", keyword: "#FF79C6", type: "#8BE9FD", string: "#F1FA8C", number: "#BD93F9",
                    comment: "#6272A4", function: "#50FA7B", attribute: "#FFB86C", tag: "#FF79C6", panel: "#1E1F29"),
        EditorTheme(id: "one-dark", name: "One Dark", isDark: true, background: "#282C34", foreground: "#ABB2BF",
                    gutterBackground: "#21252B", gutterForeground: "#4B5263", gutterActive: "#ABB2BF", selection: "#3E4451",
                    cursor: "#528BFF", keyword: "#C678DD", type: "#E5C07B", string: "#98C379", number: "#D19A66",
                    comment: "#5C6370", function: "#61AFEF", attribute: "#D19A66", tag: "#E06C75", panel: "#1D2025"),
        EditorTheme(id: "github-dark", name: "GitHub Dark", isDark: true, background: "#0D1117", foreground: "#E6EDF3",
                    gutterBackground: "#0D1117", gutterForeground: "#484F58", gutterActive: "#E6EDF3", selection: "#264F78",
                    cursor: "#E6EDF3", keyword: "#FF7B72", type: "#FFA657", string: "#A5D6FF", number: "#79C0FF",
                    comment: "#8B949E", function: "#D2A8FF", attribute: "#79C0FF", tag: "#7EE787", panel: "#161B22"),
        EditorTheme(id: "github-light", name: "GitHub Light", isDark: false, background: "#FFFFFF", foreground: "#1F2328",
                    gutterBackground: "#FFFFFF", gutterForeground: "#8C959F", gutterActive: "#1F2328", selection: "#B6E3FF",
                    cursor: "#1F2328", keyword: "#CF222E", type: "#953800", string: "#0A3069", number: "#0550AE",
                    comment: "#6E7781", function: "#8250DF", attribute: "#0550AE", tag: "#116329", panel: "#F6F8FA"),
        EditorTheme(id: "nord", name: "Nord", isDark: true, background: "#2E3440", foreground: "#D8DEE9",
                    gutterBackground: "#2B303B", gutterForeground: "#4C566A", gutterActive: "#D8DEE9", selection: "#434C5E",
                    cursor: "#D8DEE9", keyword: "#81A1C1", type: "#8FBCBB", string: "#A3BE8C", number: "#B48EAD",
                    comment: "#616E88", function: "#88C0D0", attribute: "#D08770", tag: "#81A1C1", panel: "#272C36"),
        EditorTheme(id: "solarized-dark", name: "Solarized Dark", isDark: true, background: "#002B36", foreground: "#93A1A1",
                    gutterBackground: "#00252F", gutterForeground: "#586E75", gutterActive: "#93A1A1", selection: "#073642",
                    cursor: "#93A1A1", keyword: "#859900", type: "#B58900", string: "#2AA198", number: "#D33682",
                    comment: "#586E75", function: "#268BD2", attribute: "#CB4B16", tag: "#268BD2", panel: "#00212B"),
        EditorTheme(id: "solarized-light", name: "Solarized Light", isDark: false, background: "#FDF6E3", foreground: "#586E75",
                    gutterBackground: "#EEE8D5", gutterForeground: "#93A1A1", gutterActive: "#586E75", selection: "#EEE8D5",
                    cursor: "#586E75", keyword: "#859900", type: "#B58900", string: "#2AA198", number: "#D33682",
                    comment: "#93A1A1", function: "#268BD2", attribute: "#CB4B16", tag: "#268BD2", panel: "#EEE8D5"),
        EditorTheme(id: "midnight", name: "Midnight (OLED)", isDark: true, background: "#000000", foreground: "#E0E0E0",
                    gutterBackground: "#000000", gutterForeground: "#3A3A3A", gutterActive: "#FFAA28", selection: "#FFAA2833",
                    cursor: "#FFAA28", keyword: "#FF6B6B", type: "#FFD166", string: "#06D6A0", number: "#B388FF",
                    comment: "#555555", function: "#4CC9F0", attribute: "#F4A261", tag: "#FF6B6B", panel: "#0A0A0A"),
        EditorTheme(id: "xcode-light", name: "Xcode Light", isDark: false, background: "#FFFFFF", foreground: "#000000",
                    gutterBackground: "#FFFFFF", gutterForeground: "#A6A6A6", gutterActive: "#000000", selection: "#B4D8FD",
                    cursor: "#000000", keyword: "#AD3DA4", type: "#4B21B0", string: "#D12F1B", number: "#272AD8",
                    comment: "#707F8C", function: "#3E8087", attribute: "#643820", tag: "#AD3DA4", panel: "#F5F5F5")
    ]
}

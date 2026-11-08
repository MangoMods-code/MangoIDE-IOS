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

    var bg: UIColor { UIColor(hex: background) }
    var fg: UIColor { UIColor(hex: foreground) }
    var panelColor: Color { Color(hex: panel ?? gutterBackground) }
    var tagColor: String { tag ?? keyword }
}

enum ThemeLibrary {
    static let builtIn: [EditorTheme] = [
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

import SwiftUI
import UIKit

/// Every user setting in one place. Values persist to UserDefaults the moment they change.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let d = UserDefaults.standard
    private static func v<T>(_ key: String, _ fallback: T) -> T {
        d.object(forKey: key) as? T ?? fallback
    }
    private func put(_ value: Any, _ key: String) { AppSettings.d.set(value, forKey: key) }

    // MARK: Editor
    @Published var fontSize: Double { didSet { put(fontSize, "fontSize") } }
    @Published var fontName: String { didSet { put(fontName, "fontName") } }
    @Published var lineHeight: Double { didSet { put(lineHeight, "lineHeight") } }
    @Published var tabWidth: Int { didSet { put(tabWidth, "tabWidth") } }
    @Published var insertSpaces: Bool { didSet { put(insertSpaces, "insertSpaces") } }
    @Published var showLineNumbers: Bool { didSet { put(showLineNumbers, "showLineNumbers") } }
    @Published var wordWrap: Bool { didSet { put(wordWrap, "wordWrap") } }
    @Published var highlightCurrentLine: Bool { didSet { put(highlightCurrentLine, "highlightCurrentLine") } }
    @Published var syntaxHighlighting: Bool { didSet { put(syntaxHighlighting, "syntaxHighlighting") } }
    @Published var autoIndent: Bool { didSet { put(autoIndent, "autoIndent") } }
    @Published var autoCloseBrackets: Bool { didSet { put(autoCloseBrackets, "autoCloseBrackets") } }
    @Published var autoCloseQuotes: Bool { didSet { put(autoCloseQuotes, "autoCloseQuotes") } }
    @Published var smartBackspace: Bool { didSet { put(smartBackspace, "smartBackspace") } }
    @Published var spellCheck: Bool { didSet { put(spellCheck, "spellCheck") } }
    @Published var autocorrect: Bool { didSet { put(autocorrect, "autocorrect") } }
    @Published var scrollPastEnd: Bool { didSet { put(scrollPastEnd, "scrollPastEnd") } }
    @Published var largeFileThreshold: Int { didSet { put(largeFileThreshold, "largeFileThreshold") } }
    @Published var autosave: Bool { didSet { put(autosave, "autosave") } }
    @Published var autosaveDelay: Double { didSet { put(autosaveDelay, "autosaveDelay") } }
    @Published var trimTrailingWhitespace: Bool { didSet { put(trimTrailingWhitespace, "trimTrailingWhitespace") } }
    @Published var insertFinalNewline: Bool { didSet { put(insertFinalNewline, "insertFinalNewline") } }

    // MARK: Keyboard
    @Published var showKeyboardAccessory: Bool { didSet { put(showKeyboardAccessory, "showKeyboardAccessory") } }
    @Published var accessoryKeys: String { didSet { put(accessoryKeys, "accessoryKeys") } }
    @Published var accessoryShowArrows: Bool { didSet { put(accessoryShowArrows, "accessoryShowArrows") } }
    @Published var accessoryShowUndo: Bool { didSet { put(accessoryShowUndo, "accessoryShowUndo") } }

    // MARK: Appearance
    @Published var themeID: String { didSet { put(themeID, "themeID") } }
    @Published var appearance: String { didSet { put(appearance, "appearance") } }
    @Published var accentName: String { didSet { put(accentName, "accentName") } }
    @Published var showFileIcons: Bool { didSet { put(showFileIcons, "showFileIcons") } }
    @Published var compactTabs: Bool { didSet { put(compactTabs, "compactTabs") } }
    @Published var showTabCloseButtons: Bool { didSet { put(showTabCloseButtons, "showTabCloseButtons") } }
    @Published var sidebarWidth: Double { didSet { put(sidebarWidth, "sidebarWidth") } }
    @Published var splitOrientation: String { didSet { put(splitOrientation, "splitOrientation") } }
    @Published var consoleFontSize: Double { didSet { put(consoleFontSize, "consoleFontSize") } }
    @Published var consoleHeight: Double { didSet { put(consoleHeight, "consoleHeight") } }
    @Published var showStatusBar: Bool { didSet { put(showStatusBar, "showStatusBar") } }
    @Published var themeControlsApp: Bool { didSet { put(themeControlsApp, "themeControlsApp") } }
    @Published var autoHolidayThemes: Bool { didSet { put(autoHolidayThemes, "autoHolidayThemes") } }
    @Published var showEffects: Bool { didSet { put(showEffects, "showEffects") } }
    @Published var effectIntensity: Double { didSet { put(effectIntensity, "effectIntensity") } }

    // MARK: Background (image, GIF, video or Live Photo)
    @Published var backgroundKind: String { didSet { put(backgroundKind, "backgroundKind") } }
    @Published var backgroundFile: String { didSet { put(backgroundFile, "backgroundFile") } }
    @Published var backgroundStrength: Double { didSet { put(backgroundStrength, "backgroundStrength") } }
    @Published var backgroundDim: Double { didSet { put(backgroundDim, "backgroundDim") } }
    @Published var backgroundBlur: Double { didSet { put(backgroundBlur, "backgroundBlur") } }
    @Published var backgroundFit: String { didSet { put(backgroundFit, "backgroundFit") } }
    @Published var animateBackground: Bool { didSet { put(animateBackground, "animateBackground") } }

    // MARK: Files
    @Published var showHiddenFiles: Bool { didSet { put(showHiddenFiles, "showHiddenFiles") } }
    @Published var foldersFirst: Bool { didSet { put(foldersFirst, "foldersFirst") } }
    @Published var sortMode: String { didSet { put(sortMode, "sortMode") } }
    @Published var confirmDelete: Bool { didSet { put(confirmDelete, "confirmDelete") } }
    @Published var restoreTabs: Bool { didSet { put(restoreTabs, "restoreTabs") } }
    @Published var maxTabs: Int { didSet { put(maxTabs, "maxTabs") } }
    @Published var defaultExtension: String { didSet { put(defaultExtension, "defaultExtension") } }
    @Published var projectReadme: Bool { didSet { put(projectReadme, "projectReadme") } }
    @Published var projectGitignore: Bool { didSet { put(projectGitignore, "projectGitignore") } }
    @Published var closeSidebarOnOpen: Bool { didSet { put(closeSidebarOnOpen, "closeSidebarOnOpen") } }

    // MARK: Run
    @Published var clearConsoleOnRun: Bool { didSet { put(clearConsoleOnRun, "clearConsoleOnRun") } }
    @Published var saveBeforeRun: Bool { didSet { put(saveBeforeRun, "saveBeforeRun") } }
    @Published var showConsoleOnRun: Bool { didSet { put(showConsoleOnRun, "showConsoleOnRun") } }
    @Published var runnerURL: String { didSet { put(runnerURL, "runnerURL"); KeychainStore.set(runnerURL, for: "runnerURL") } }
    @Published var runnerKey: String { didSet { put(runnerKey, "runnerKey"); KeychainStore.set(runnerKey, for: "runnerKey") } }
    @Published var runnerTimeout: Double { didSet { put(runnerTimeout, "runnerTimeout") } }
    @Published var showExecutionTime: Bool { didSet { put(showExecutionTime, "showExecutionTime") } }
    @Published var jsStrictMode: Bool { didSet { put(jsStrictMode, "jsStrictMode") } }

    // MARK: General
    @Published var hapticFeedback: Bool { didSet { put(hapticFeedback, "hapticFeedback") } }
    @Published var keepScreenAwake: Bool { didSet { put(keepScreenAwake, "keepScreenAwake"); applyIdleTimer() } }
    @Published var showWelcome: Bool { didSet { put(showWelcome, "showWelcome") } }
    @Published var extensionsEnabled: Bool { didSet { put(extensionsEnabled, "extensionsEnabled") } }

    /// Your own runner on Railway. The address isn't secret; the key is what protects it.
    static let defaultRunnerURL = "https://runner-production-4eb3.up.railway.app"
    static let defaultAccessoryKeys = "{ } [ ] ( ) < > ; : = + - * / \\ | & ! ? \" ' ` # $ % _ . ,"

    init() {
        fontSize = AppSettings.v("fontSize", 14.0)
        fontName = AppSettings.v("fontName", "System Mono")
        lineHeight = AppSettings.v("lineHeight", 1.25)
        tabWidth = AppSettings.v("tabWidth", 4)
        insertSpaces = AppSettings.v("insertSpaces", true)
        showLineNumbers = AppSettings.v("showLineNumbers", true)
        wordWrap = AppSettings.v("wordWrap", true)
        highlightCurrentLine = AppSettings.v("highlightCurrentLine", true)
        syntaxHighlighting = AppSettings.v("syntaxHighlighting", true)
        autoIndent = AppSettings.v("autoIndent", true)
        autoCloseBrackets = AppSettings.v("autoCloseBrackets", true)
        autoCloseQuotes = AppSettings.v("autoCloseQuotes", true)
        smartBackspace = AppSettings.v("smartBackspace", true)
        spellCheck = AppSettings.v("spellCheck", false)
        autocorrect = AppSettings.v("autocorrect", false)
        scrollPastEnd = AppSettings.v("scrollPastEnd", true)
        largeFileThreshold = AppSettings.v("largeFileThreshold", 300_000)
        autosave = AppSettings.v("autosave", true)
        autosaveDelay = AppSettings.v("autosaveDelay", 1.5)
        trimTrailingWhitespace = AppSettings.v("trimTrailingWhitespace", false)
        insertFinalNewline = AppSettings.v("insertFinalNewline", false)

        showKeyboardAccessory = AppSettings.v("showKeyboardAccessory", true)
        accessoryKeys = AppSettings.v("accessoryKeys", AppSettings.defaultAccessoryKeys)
        accessoryShowArrows = AppSettings.v("accessoryShowArrows", true)
        accessoryShowUndo = AppSettings.v("accessoryShowUndo", true)

        themeID = AppSettings.v("themeID", "mango-dark")
        appearance = AppSettings.v("appearance", "system")
        accentName = AppSettings.v("accentName", "Mango")
        showFileIcons = AppSettings.v("showFileIcons", true)
        compactTabs = AppSettings.v("compactTabs", false)
        showTabCloseButtons = AppSettings.v("showTabCloseButtons", true)
        sidebarWidth = AppSettings.v("sidebarWidth", 280.0)
        splitOrientation = AppSettings.v("splitOrientation", "auto")
        consoleFontSize = AppSettings.v("consoleFontSize", 13.0)
        consoleHeight = AppSettings.v("consoleHeight", 0.33)
        showStatusBar = AppSettings.v("showStatusBar", true)
        themeControlsApp = AppSettings.v("themeControlsApp", true)
        autoHolidayThemes = AppSettings.v("autoHolidayThemes", false)
        showEffects = AppSettings.v("showEffects", true)
        effectIntensity = AppSettings.v("effectIntensity", 1.0)
        backgroundKind = AppSettings.v("backgroundKind", "none")
        backgroundFile = AppSettings.v("backgroundFile", "")
        backgroundStrength = AppSettings.v("backgroundStrength", 0.55)
        backgroundDim = AppSettings.v("backgroundDim", 0.2)
        backgroundBlur = AppSettings.v("backgroundBlur", 0.0)
        backgroundFit = AppSettings.v("backgroundFit", "fill")
        animateBackground = AppSettings.v("animateBackground", true)

        showHiddenFiles = AppSettings.v("showHiddenFiles", false)
        foldersFirst = AppSettings.v("foldersFirst", true)
        sortMode = AppSettings.v("sortMode", "name")
        confirmDelete = AppSettings.v("confirmDelete", true)
        restoreTabs = AppSettings.v("restoreTabs", true)
        maxTabs = AppSettings.v("maxTabs", 20)
        defaultExtension = AppSettings.v("defaultExtension", "txt")
        projectReadme = AppSettings.v("projectReadme", true)
        projectGitignore = AppSettings.v("projectGitignore", true)
        closeSidebarOnOpen = AppSettings.v("closeSidebarOnOpen", true)

        clearConsoleOnRun = AppSettings.v("clearConsoleOnRun", true)
        saveBeforeRun = AppSettings.v("saveBeforeRun", true)
        showConsoleOnRun = AppSettings.v("showConsoleOnRun", true)
        // Runner settings live in the Keychain so they survive deleting and reinstalling the app.
        let savedRunner = KeychainStore.get("runnerURL") ?? AppSettings.v("runnerURL", "")
        runnerURL = savedRunner.isEmpty ? AppSettings.defaultRunnerURL : savedRunner
        let savedKey = KeychainStore.get("runnerKey") ?? AppSettings.v("runnerKey", "")
        runnerKey = savedKey
        if !savedKey.isEmpty && KeychainStore.get("runnerKey") == nil { KeychainStore.set(savedKey, for: "runnerKey") }
        runnerTimeout = AppSettings.v("runnerTimeout", 20.0)
        showExecutionTime = AppSettings.v("showExecutionTime", true)
        jsStrictMode = AppSettings.v("jsStrictMode", false)

        hapticFeedback = AppSettings.v("hapticFeedback", true)
        keepScreenAwake = AppSettings.v("keepScreenAwake", false)
        showWelcome = AppSettings.v("showWelcome", true)
        extensionsEnabled = AppSettings.v("extensionsEnabled", true)
    }

    func resetAll() {
        if let id = Bundle.main.bundleIdentifier {
            let keep = AppSettings.d.dictionaryRepresentation().filter { $0.key.hasPrefix("ws.") || $0.key.hasPrefix("ext.") || $0.key.hasPrefix("session.") || $0.key == "runnerURL" || $0.key == "runnerKey" }
            AppSettings.d.removePersistentDomain(forName: id)
            for (k, val) in keep { AppSettings.d.set(val, forKey: k) }
        }
        let fresh = AppSettings()
        fontSize = fresh.fontSize; fontName = fresh.fontName; lineHeight = fresh.lineHeight
        tabWidth = fresh.tabWidth; insertSpaces = fresh.insertSpaces; showLineNumbers = fresh.showLineNumbers
        wordWrap = fresh.wordWrap; highlightCurrentLine = fresh.highlightCurrentLine
        syntaxHighlighting = fresh.syntaxHighlighting; autoIndent = fresh.autoIndent
        autoCloseBrackets = fresh.autoCloseBrackets; autoCloseQuotes = fresh.autoCloseQuotes
        smartBackspace = fresh.smartBackspace; spellCheck = fresh.spellCheck; autocorrect = fresh.autocorrect
        scrollPastEnd = fresh.scrollPastEnd; largeFileThreshold = fresh.largeFileThreshold
        autosave = fresh.autosave; autosaveDelay = fresh.autosaveDelay
        trimTrailingWhitespace = fresh.trimTrailingWhitespace; insertFinalNewline = fresh.insertFinalNewline
        showKeyboardAccessory = fresh.showKeyboardAccessory; accessoryKeys = fresh.accessoryKeys
        accessoryShowArrows = fresh.accessoryShowArrows; accessoryShowUndo = fresh.accessoryShowUndo
        themeID = fresh.themeID; appearance = fresh.appearance; accentName = fresh.accentName
        showFileIcons = fresh.showFileIcons; compactTabs = fresh.compactTabs
        showTabCloseButtons = fresh.showTabCloseButtons; sidebarWidth = fresh.sidebarWidth
        splitOrientation = fresh.splitOrientation; consoleFontSize = fresh.consoleFontSize
        consoleHeight = fresh.consoleHeight; showStatusBar = fresh.showStatusBar
        themeControlsApp = fresh.themeControlsApp; autoHolidayThemes = fresh.autoHolidayThemes
        showEffects = fresh.showEffects; effectIntensity = fresh.effectIntensity
        backgroundStrength = fresh.backgroundStrength; backgroundDim = fresh.backgroundDim
        backgroundBlur = fresh.backgroundBlur; backgroundFit = fresh.backgroundFit; animateBackground = fresh.animateBackground
        showHiddenFiles = fresh.showHiddenFiles; foldersFirst = fresh.foldersFirst; sortMode = fresh.sortMode
        confirmDelete = fresh.confirmDelete; restoreTabs = fresh.restoreTabs; maxTabs = fresh.maxTabs
        defaultExtension = fresh.defaultExtension; projectReadme = fresh.projectReadme
        projectGitignore = fresh.projectGitignore; closeSidebarOnOpen = fresh.closeSidebarOnOpen
        clearConsoleOnRun = fresh.clearConsoleOnRun; saveBeforeRun = fresh.saveBeforeRun
        showConsoleOnRun = fresh.showConsoleOnRun
        runnerTimeout = fresh.runnerTimeout; showExecutionTime = fresh.showExecutionTime
        jsStrictMode = fresh.jsStrictMode; hapticFeedback = fresh.hapticFeedback
        keepScreenAwake = fresh.keepScreenAwake; showWelcome = fresh.showWelcome
        extensionsEnabled = fresh.extensionsEnabled
    }

    // MARK: Derived values

    /// The theme in use right now (a holiday theme when automatic holidays are on and it's that time).
    var effectiveThemeID: String {
        autoHolidayThemes ? (Holidays.current() ?? themeID) : themeID
    }

    static var backgroundsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Backgrounds", isDirectory: true)
    }

    var backgroundURL: URL? {
        guard backgroundKind != "none", !backgroundFile.isEmpty else { return nil }
        return AppSettings.backgroundsFolder.appendingPathComponent(backgroundFile)
    }

    var backgroundActive: Bool { backgroundURL != nil }

    var colorSchemeOverride: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    static let accents: [(String, Color)] = [
        ("Mango", Color(red: 1.0, green: 0.6, blue: 0.1)),
        ("Blue", .blue), ("Purple", .purple), ("Pink", .pink), ("Red", .red),
        ("Green", .green), ("Teal", .teal), ("Indigo", .indigo), ("Mint", .mint), ("Gray", .gray)
    ]

    var accentColor: Color {
        AppSettings.accents.first { $0.0 == accentName }?.1 ?? AppSettings.accents[0].1
    }

    static let fontNames = ["System Mono", "Menlo", "Courier New", "Courier", "American Typewriter"]

    func editorFont(size: CGFloat? = nil, bold: Bool = false) -> UIFont {
        let s = size ?? CGFloat(fontSize)
        if fontName == "System Mono" || UIFont(name: fontName, size: s) == nil {
            return UIFont.monospacedSystemFont(ofSize: s, weight: bold ? .semibold : .regular)
        }
        let f = UIFont(name: fontName, size: s)!
        if bold, let desc = f.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: desc, size: s)
        }
        return f
    }

    var indentUnit: String {
        insertSpaces ? String(repeating: " ", count: max(1, tabWidth)) : "\t"
    }

    func applyIdleTimer() {
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = self.keepScreenAwake }
    }

    func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard hapticFeedback else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// Snapshot of what the text view needs, so it only reconfigures when something really changed.
    var editorConfig: EditorConfig {
        EditorConfig(fontName: fontName, fontSize: fontSize, lineHeight: lineHeight, tabWidth: tabWidth,
                     insertSpaces: insertSpaces, showLineNumbers: showLineNumbers, wordWrap: wordWrap,
                     highlightCurrentLine: highlightCurrentLine, syntaxHighlighting: syntaxHighlighting,
                     autoIndent: autoIndent, autoCloseBrackets: autoCloseBrackets, autoCloseQuotes: autoCloseQuotes,
                     smartBackspace: smartBackspace, spellCheck: spellCheck, autocorrect: autocorrect,
                     scrollPastEnd: scrollPastEnd, largeFileThreshold: largeFileThreshold,
                     showAccessory: showKeyboardAccessory, accessoryKeys: accessoryKeys,
                     accessoryArrows: accessoryShowArrows, accessoryUndo: accessoryShowUndo)
    }
}

struct EditorConfig: Equatable {
    var fontName: String
    var fontSize: Double
    var lineHeight: Double
    var tabWidth: Int
    var insertSpaces: Bool
    var showLineNumbers: Bool
    var wordWrap: Bool
    var highlightCurrentLine: Bool
    var syntaxHighlighting: Bool
    var autoIndent: Bool
    var autoCloseBrackets: Bool
    var autoCloseQuotes: Bool
    var smartBackspace: Bool
    var spellCheck: Bool
    var autocorrect: Bool
    var scrollPastEnd: Bool
    var largeFileThreshold: Int
    var showAccessory: Bool
    var accessoryKeys: String
    var accessoryArrows: Bool
    var accessoryUndo: Bool

    var indentUnit: String { insertSpaces ? String(repeating: " ", count: max(1, tabWidth)) : "\t" }

    func font(bold: Bool = false) -> UIFont {
        let s = CGFloat(fontSize)
        if fontName == "System Mono" || UIFont(name: fontName, size: s) == nil {
            return UIFont.monospacedSystemFont(ofSize: s, weight: bold ? .semibold : .regular)
        }
        return UIFont(name: fontName, size: s)!
    }
}

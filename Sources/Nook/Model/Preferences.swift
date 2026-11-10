import AppKit
import Combine
import NookKit

enum Highlight: String, CaseIterable, Codable {
    case none, borderActive, borderAll, glowActive

    var title: String {
        switch self {
        case .none: "None"
        case .borderActive: "Border on active"
        case .borderAll: "Border on all"
        case .glowActive: "Glow on active"
        }
    }
}

enum MoveIntoFull: String, CaseIterable, Codable {
    case swap, stack

    var title: String { self == .swap ? "Swap places" : "Stack on top" }
}

enum ShortcutPrefix: String, CaseIterable, Codable {
    case controlOption, optionCommand, controlShift

    var title: String {
        switch self {
        case .controlOption: "⌃⌥"
        case .optionCommand: "⌥⌘"
        case .controlShift: "⌃⇧"
        }
    }
}

enum CleanBackground: String, CaseIterable, Codable {
    case graphite, mist, stone

    var title: String { rawValue.capitalized }

    var color: NSColor {
        switch self {
        case .graphite: NSColor(srgbRed: 0.13, green: 0.14, blue: 0.15, alpha: 1)
        case .mist: NSColor(srgbRed: 0.86, green: 0.88, blue: 0.90, alpha: 1)
        case .stone: NSColor(srgbRed: 0.55, green: 0.53, blue: 0.50, alpha: 1)
        }
    }
}

enum IconStyle: String, CaseIterable, Codable {
    case graphite, paper, terminal, ink, ember

    var title: String { rawValue.capitalized }
}

struct FloatRule: Codable, Hashable, Identifiable {
    var bundleID: String
    var appName: String
    var words: String

    var id: String { bundleID + "\u{1}" + words }

    func matches(bundleID: String?, title: String) -> Bool {
        bundleID == self.bundleID && !words.isEmpty && title.hasPrefix(words)
    }
}

/// Where one app's new windows open.
struct AppRule: Codable, Hashable, Identifiable {
    var bundleID: String
    var appName: String
    var open: InsertPosition
    /// Share of the screen's width its new windows' tile gets (0.25…0.75), or nil to leave sizes alone.
    var width: Double?

    var id: String { bundleID }
}

enum WindowBarMode: String, CaseIterable, Codable {
    case off, whileHolding, always

    var title: String {
        switch self {
        case .off: "Off"
        case .whileHolding: "While holding the shortcut keys"
        case .always: "Always"
        }
    }
}

enum BarEdge: String, CaseIterable, Codable {
    case top, bottom

    var title: String { rawValue.capitalized }
}

extension InsertPosition {
    var title: String {
        switch self {
        case .end: "At the end"
        case .afterActive: "Next to the active window"
        case .first: "As the main window"
        }
    }
}

/// One screen of a saved workspace.
struct WorkspaceScreen: Codable, Hashable {
    var display: String
    var name: String
    var layout: LayoutKind?
    var count: Int?
    var tiles: [[SavedWindow]]
}

/// A saved arrangement of windows to load again later.
struct Workspace: Codable, Hashable, Identifiable {
    var name: String
    var screens: [WorkspaceScreen]
    var saved: Date

    var id: String { name }
    var windowCount: Int { screens.reduce(0) { $0 + $1.tiles.reduce(0) { $0 + $1.count } } }
    var apps: [String] { Array(Set(screens.flatMap { $0.tiles.flatMap { $0.map(\.app) } })).sorted() }
}

struct LearnedSize: Codable, Hashable {
    var appName: String
    var width: Double?
    var height: Double?
}

/// A screen's own choice of layout and count, which wins over the defaults.
struct ScreenChoice: Codable, Hashable {
    var layout: LayoutKind?
    var count: Int?
}

/// Every user setting, persisted to UserDefaults as it changes.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let d = UserDefaults.standard
    private var loading = true

    // General
    @Published var tilingEnabled = true { didSet { save("tilingEnabled", tilingEnabled) } }
    @Published var setupComplete = false { didSet { save("setupComplete", setupComplete) } }
    @Published var iconStyle = IconStyle.graphite { didSet { save("iconStyle", iconStyle) } }
    @Published var cleanBackground = CleanBackground.graphite { didSet { save("cleanBackground", cleanBackground) } }
    @Published var restoreOnQuit = true { didSet { save("restoreOnQuit", restoreOnQuit) } }
    @Published var restartIfStuck = false { didSet { save("restartIfStuck", restartIfStuck) } }
    @Published var checkForUpdates = false { didSet { save("checkForUpdates", checkForUpdates) } }
    @Published var lastUpdateCheck: Date? { didSet { save("lastUpdateCheck", lastUpdateCheck) } }
    @Published var menuBarPosition = false { didSet { save("menuBarPosition", menuBarPosition) } }

    // Layout
    @Published var layout = LayoutKind.grid { didSet { save("layout", layout) } }
    @Published var mainSize = MainSize.half { didSet { save("mainSize", mainSize) } }
    @Published var windowsPerScreen = 3 { didSet { save("windowsPerScreen", windowsPerScreen) } }
    @Published var overflow = OverflowMode.stack { didSet { save("overflow", overflow) } }
    @Published var moveIntoFull = MoveIntoFull.swap { didSet { save("moveIntoFull", moveIntoFull) } }
    @Published var gap: Double = 8 { didSet { save("gap", gap) } }
    @Published var separateOuterGap = false { didSet { save("separateOuterGap", separateOuterGap) } }
    @Published var outerGap: Double = 8 { didSet { save("outerGap", outerGap) } }
    @Published var newWindowPosition = InsertPosition.end { didSet { save("newWindowPosition", newWindowPosition) } }
    @Published var keepShortHeights = false { didSet { save("keepShortHeights", keepShortHeights) } }
    @Published var windowBar = WindowBarMode.off { didSet { save("windowBar", windowBar) } }
    @Published var windowBarEdge = BarEdge.bottom { didSet { save("windowBarEdge", windowBarEdge) } }

    // Highlight
    @Published var highlight = Highlight.none { didSet { save("highlight", highlight) } }
    @Published var borderThickness: Double = 3 { didSet { save("borderThickness", borderThickness) } }
    @Published var useAccentColor = true { didSet { save("useAccentColor", useAccentColor) } }
    @Published var customColor = "#7AA2F7" { didSet { save("customColor", customColor) } }
    @Published var cornerRadius: Double = 12 { didSet { save("cornerRadius", cornerRadius) } }
    @Published var noPeek = false { didSet { save("noPeek", noPeek) } }
    @Published var dimAmount: Double = 0.5 { didSet { save("dimAmount", dimAmount) } }
    @Published var blurOthers = true { didSet { save("blurOthers", blurOthers) } }

    // Mouse
    @Published var quickActions = true { didSet { save("quickActions", quickActions) } }
    @Published var hoverFocus = false { didSet { save("hoverFocus", hoverFocus) } }
    @Published var mouseFollowsFocus = false { didSet { save("mouseFollowsFocus", mouseFollowsFocus) } }
    @Published var swipeToFocus = true { didSet { save("swipeToFocus", swipeToFocus) } }

    // Keyboard
    @Published var shortcutsEnabled = true { didSet { save("shortcutsEnabled", shortcutsEnabled) } }
    @Published var prefix = ShortcutPrefix.controlOption { didSet { save("prefix", prefix) } }
    @Published var tabViewEnabled = true { didSet { save("tabViewEnabled", tabViewEnabled) } }
    /// Keys chosen in Settings, by command name. Replaces that command's default keys; empty means none.
    @Published var customShortcuts: [String: [KeyCombo]] = [:] { didSet { save("customShortcuts", customShortcuts) } }

    // Apps
    @Published var excludedApps: [String] = [] { didSet { save("excludedApps", excludedApps) } }
    @Published var removedDefaultExclusions: [String] = [] { didSet { save("removedDefaultExclusions", removedDefaultExclusions) } }
    @Published var floatRules: [FloatRule] = [] { didSet { save("floatRules", floatRules) } }
    @Published var learnedSizes: [String: LearnedSize] = [:] { didSet { save("learnedSizes", learnedSizes) } }
    @Published var quietNeedsRoom: [String] = [] { didSet { save("quietNeedsRoom", quietNeedsRoom) } }
    @Published var appRules: [AppRule] = [] { didSet { save("appRules", appRules) } }

    // Sessions and workspaces
    /// The last arrangement of each screen, by display, to restore after a restart.
    @Published var session: [String: [[SavedWindow]]] = [:] { didSet { save("session", session) } }
    @Published var workspaces: [Workspace] = [] { didSet { save("workspaces", workspaces) } }

    // Per screen
    @Published var screenChoices: [String: ScreenChoice] = [:] { didSet { save("screenChoices", screenChoices) } }
    @Published var weights: [String: SplitWeights] = [:] { didSet { save("weights", weights) } }

    // Activity
    @Published var countActivity = true { didSet { save("countActivity", countActivity) } }
    @Published var activity = Activity() { didSet { save("activity", activity) } }

    /// Small tools and fixed-shape windows that look wrong stretched into a tile.
    static let defaultExclusions: [(String, String)] = [
        ("com.apple.ScreenContinuity", "iPhone Mirroring"),
        ("com.apple.iphonesimulator", "Simulator"),
        ("com.apple.calculator", "Calculator"),
        ("com.apple.systempreferences", "System Settings"),
        ("com.apple.Stickies", "Stickies"),
        ("com.apple.clock", "Clock"),
        ("com.apple.PhotoBooth", "Photo Booth"),
        ("com.apple.QuickTimePlayerX", "QuickTime Player"),
        ("com.apple.accessibility.Magnifier", "Magnifier"),
        ("com.apple.DeskView", "Desk View"),
        ("com.apple.DigitalColorMeter", "Digital Color Meter"),
        ("com.apple.screenshot.launcher", "Screenshot"),
        ("com.apple.archiveutility", "Archive Utility"),
        ("com.apple.installer", "Installer"),
        ("com.apple.iOSAppInstaller", "iOS App Installer"),
        ("com.apple.MigrateAssistant", "Migration Assistant"),
        ("com.apple.CaptiveNetworkAssistant", "Wi-Fi sign-in"),
        ("com.apple.problemreporter", "Problem Reporter"),
    ]

    private init() {
        load()
        loading = false
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if excludedApps.contains(bundleID) { return true }
        return Self.defaultExclusions.contains { $0.0 == bundleID } && !removedDefaultExclusions.contains(bundleID)
    }

    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        let isDefault = Self.defaultExclusions.contains { $0.0 == bundleID }
        if excluded {
            if isDefault { removedDefaultExclusions.removeAll { $0 == bundleID } }
            else if !excludedApps.contains(bundleID) { excludedApps.append(bundleID) }
        } else {
            excludedApps.removeAll { $0 == bundleID }
            if isDefault, !removedDefaultExclusions.contains(bundleID) { removedDefaultExclusions.append(bundleID) }
        }
    }

    /// Where a window of this app opens: its app rule, else the general choice.
    func openPosition(for bundleID: String?) -> InsertPosition {
        appRules.first { $0.bundleID == bundleID }?.open ?? newWindowPosition
    }

    var accentNSColor: NSColor {
        useAccentColor ? .controlAccentColor : (NSColor(hex: customColor) ?? .controlAccentColor)
    }

    /// The space between windows, grown to fit a border or the glow.
    var effectiveGap: CGFloat {
        switch highlight {
        case .none: CGFloat(gap)
        case .borderActive, .borderAll: max(CGFloat(gap), CGFloat(borderThickness) * 2)
        case .glowActive: max(CGFloat(gap), 4)
        }
    }

    var effectiveOuterGap: CGFloat {
        separateOuterGap ? max(CGFloat(outerGap), highlight == .none ? 0 : CGFloat(borderThickness)) : effectiveGap
    }

    // MARK: - Persistence

    private func save<T: Encodable>(_ key: String, _ value: T) {
        guard !loading else { return }
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    private func read<T: Decodable>(_ key: String, _ into: inout T) {
        guard let data = d.data(forKey: key), let v = try? JSONDecoder().decode(T.self, from: data) else { return }
        into = v
    }

    private func load() {
        read("tilingEnabled", &tilingEnabled)
        read("setupComplete", &setupComplete)
        read("iconStyle", &iconStyle)
        read("cleanBackground", &cleanBackground)
        read("restoreOnQuit", &restoreOnQuit)
        read("restartIfStuck", &restartIfStuck)
        read("checkForUpdates", &checkForUpdates)
        read("lastUpdateCheck", &lastUpdateCheck)
        read("menuBarPosition", &menuBarPosition)
        read("newWindowPosition", &newWindowPosition)
        read("keepShortHeights", &keepShortHeights)
        read("windowBar", &windowBar)
        read("windowBarEdge", &windowBarEdge)
        read("customShortcuts", &customShortcuts)
        read("appRules", &appRules)
        read("session", &session)
        read("workspaces", &workspaces)
        read("layout", &layout)
        read("mainSize", &mainSize)
        read("windowsPerScreen", &windowsPerScreen)
        read("overflow", &overflow)
        read("moveIntoFull", &moveIntoFull)
        read("gap", &gap)
        read("separateOuterGap", &separateOuterGap)
        read("outerGap", &outerGap)
        read("highlight", &highlight)
        read("borderThickness", &borderThickness)
        read("useAccentColor", &useAccentColor)
        read("customColor", &customColor)
        read("cornerRadius", &cornerRadius)
        read("noPeek", &noPeek)
        read("dimAmount", &dimAmount)
        read("blurOthers", &blurOthers)
        read("quickActions", &quickActions)
        read("hoverFocus", &hoverFocus)
        read("swipeToFocus", &swipeToFocus)
        read("mouseFollowsFocus", &mouseFollowsFocus)
        read("shortcutsEnabled", &shortcutsEnabled)
        read("prefix", &prefix)
        read("tabViewEnabled", &tabViewEnabled)
        read("excludedApps", &excludedApps)
        read("removedDefaultExclusions", &removedDefaultExclusions)
        read("floatRules", &floatRules)
        read("learnedSizes", &learnedSizes)
        read("quietNeedsRoom", &quietNeedsRoom)
        read("screenChoices", &screenChoices)
        read("weights", &weights)
        read("countActivity", &countActivity)
        read("activity", &activity)
    }

    // MARK: - Config files

    /// The settings worth keeping in dotfiles: everything except learned and per-screen state.
    struct Config: Codable {
        var layout: LayoutKind?
        var mainSize: MainSize?
        var windowsPerScreen: Int?
        var overflow: OverflowMode?
        var moveIntoFull: MoveIntoFull?
        var gap: Double?
        var outerGap: Double?
        var highlight: Highlight?
        var borderThickness: Double?
        var color: String?
        var cornerRadius: Double?
        var dimAmount: Double?
        var blurOthers: Bool?
        var quickActions: Bool?
        var hoverFocus: Bool?
        var mouseFollowsFocus: Bool?
        var shortcutsEnabled: Bool?
        var prefix: ShortcutPrefix?
        var tabViewEnabled: Bool?
        var cleanBackground: CleanBackground?
        var restoreOnQuit: Bool?
        var restartIfStuck: Bool?
        var swipeToFocus: Bool?
        var checkForUpdates: Bool?
        var menuBarPosition: Bool?
        var newWindowPosition: InsertPosition?
        var keepShortHeights: Bool?
        var windowBar: WindowBarMode?
        var windowBarEdge: BarEdge?
        var customShortcuts: [String: [KeyCombo]]?
        var appRules: [AppRule]?
        var excludedApps: [String]?
        var floatRules: [FloatRule]?
    }

    func exportConfig() -> Data {
        let c = Config(
            layout: layout, mainSize: mainSize, windowsPerScreen: windowsPerScreen, overflow: overflow,
            moveIntoFull: moveIntoFull, gap: gap, outerGap: separateOuterGap ? outerGap : nil,
            highlight: highlight, borderThickness: borderThickness, color: useAccentColor ? "accent" : customColor,
            cornerRadius: cornerRadius, dimAmount: dimAmount, blurOthers: blurOthers, quickActions: quickActions,
            hoverFocus: hoverFocus, mouseFollowsFocus: mouseFollowsFocus, shortcutsEnabled: shortcutsEnabled,
            prefix: prefix, tabViewEnabled: tabViewEnabled, cleanBackground: cleanBackground, restoreOnQuit: restoreOnQuit,
            restartIfStuck: restartIfStuck, swipeToFocus: swipeToFocus, checkForUpdates: checkForUpdates, menuBarPosition: menuBarPosition,
            newWindowPosition: newWindowPosition, keepShortHeights: keepShortHeights, windowBar: windowBar,
            windowBarEdge: windowBarEdge, customShortcuts: customShortcuts, appRules: appRules,
            excludedApps: excludedApps, floatRules: floatRules
        )
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(c)) ?? Data()
    }

    func importConfig(_ data: Data) throws {
        let c = try JSONDecoder().decode(Config.self, from: data)
        if let v = c.layout { layout = v }
        if let v = c.mainSize { mainSize = v }
        if let v = c.windowsPerScreen { windowsPerScreen = min(max(v, 1), 4) }
        if let v = c.overflow { overflow = v }
        if let v = c.moveIntoFull { moveIntoFull = v }
        if let v = c.gap { gap = min(max(v, 0), 24) }
        if let v = c.outerGap { separateOuterGap = true; outerGap = min(max(v, 0), 48) }
        if let v = c.highlight { highlight = v }
        if let v = c.borderThickness { borderThickness = min(max(v, 2), 6) }
        if let v = c.color {
            if v == "accent" { useAccentColor = true } else { useAccentColor = false; customColor = v }
        }
        if let v = c.cornerRadius { cornerRadius = min(max(v, 0), 30) }
        if let v = c.dimAmount { dimAmount = min(max(v, 0.1), 0.9) }
        if let v = c.blurOthers { blurOthers = v }
        if let v = c.quickActions { quickActions = v }
        if let v = c.hoverFocus { hoverFocus = v }
        if let v = c.mouseFollowsFocus { mouseFollowsFocus = v }
        if let v = c.shortcutsEnabled { shortcutsEnabled = v }
        if let v = c.prefix { prefix = v }
        if let v = c.tabViewEnabled { tabViewEnabled = v }
        if let v = c.cleanBackground { cleanBackground = v }
        if let v = c.restoreOnQuit { restoreOnQuit = v }
        if let v = c.restartIfStuck { restartIfStuck = v }
        if let v = c.swipeToFocus { swipeToFocus = v }
        if let v = c.checkForUpdates { checkForUpdates = v }
        if let v = c.menuBarPosition { menuBarPosition = v }
        if let v = c.newWindowPosition { newWindowPosition = v }
        if let v = c.keepShortHeights { keepShortHeights = v }
        if let v = c.windowBar { windowBar = v }
        if let v = c.windowBarEdge { windowBarEdge = v }
        if let v = c.customShortcuts { customShortcuts = v }
        if let v = c.appRules { appRules = v }
        if let v = c.excludedApps { excludedApps = v }
        if let v = c.floatRules { floatRules = v }
    }
}

/// Counts kept on this Mac only: numbers, never titles or app names.
struct Activity: Codable, Equatable {
    var weekStart = Activity.startOfWeek(Date())
    var placed = 0
    var keyboard = 0.0
    var mouse = 0.0
    var uses: [String: Int] = [:]

    static func startOfWeek(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    mutating func rollIfNeeded() {
        let now = Activity.startOfWeek(Date())
        if now > weekStart { self = Activity(weekStart: now) }
    }

    /// Rough seconds saved: dragging and sizing a window by hand takes a few seconds.
    var secondsSaved: Int { placed * 4 + Int((keyboard + mouse) * 3) }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#7AA2F7" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

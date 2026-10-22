import AppKit

/// One thing the top bar can show.
enum BarItemKind: String, CaseIterable, Identifiable {
    case desktops, app, lockIn, song, volume, battery, clock
    var id: String { rawValue }
    var title: String {
        switch self {
        case .desktops: "Desktops"
        case .app: "App in front"
        case .lockIn: "Lock-in mode"
        case .song: "Song playing"
        case .volume: "Volume"
        case .battery: "Battery"
        case .clock: "Date and time"
        }
    }
    var symbol: String {
        switch self {
        case .desktops: "square.split.2x2"
        case .app: "macwindow"
        case .lockIn: "lock.fill"
        case .song: "music.note"
        case .volume: "speaker.wave.2.fill"
        case .battery: "battery.75percent"
        case .clock: "clock"
        }
    }
}

enum BarSide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }
}

/// An item, which side of the bar it's on, and whether it's showing.
struct BarItem: Identifiable, Equatable {
    var kind: BarItemKind
    var side: BarSide
    var isOn: Bool
    var id: String { kind.rawValue }
}

/// What's behind each piece of the bar.
enum BarStyle: String, CaseIterable, Identifiable {
    case wallpaper, glass, color, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wallpaper: "Wallpaper"
        case .glass: "Glass"
        case .color: "Colour"
        case .none: "None"
        }
    }
}

enum BarSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var pillHeight: CGFloat { switch self { case .small: 22; case .medium: 26; case .large: 30 } }
    var fontSize: CGFloat { switch self { case .small: 11.5; case .medium: 13; case .large: 14.5 } }
    var iconSize: CGFloat { switch self { case .small: 14; case .medium: 17; case .large: 20 } }
}

/// How the desktops are drawn.
enum DesktopStyle: String, CaseIterable, Identifiable {
    case separate, joined, numbers, apps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .separate: "Separate"
        case .joined: "Joined"
        case .numbers: "Numbers"
        case .apps: "Apps"
        }
    }
}

/// What the bar does while a game (or another full-screen window) is in front on its screen.
enum GameMode: String, CaseIterable, Identifiable {
    case slide, line, stay
    var id: String { rawValue }
    var title: String {
        switch self {
        case .slide: "Slide away"
        case .line: "Thin line"
        case .stay: "Stay"
        }
    }
}

/// The colours a desktop can be given. The bar takes on the current desktop's colour.
enum DesktopColour: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: NSColor {
        let hex = switch self {
        case .red: "#FF5F57"
        case .orange: "#FF9F0A"
        case .yellow: "#FFD60A"
        case .green: "#32D74B"
        case .mint: "#66D4CF"
        case .teal: "#40C8E0"
        case .blue: "#0A84FF"
        case .indigo: "#5E5CE6"
        case .purple: "#BF5AF2"
        case .pink: "#FF375F"
        }
        return NSColor(hex: hex)!
    }
}

enum BarFont: String, CaseIterable, Identifiable {
    case rounded, standard, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rounded: "Rounded"
        case .standard: "Standard"
        case .mono: "Monospaced"
        }
    }
}

/// The top bar's settings, stored in Clear Dock's preferences under "bar." keys.
enum BarSettings {
    private static var defaults: UserDefaults { .standard }

    /// The top bar is off until it's switched on.
    static var enabled: Bool {
        get { defaults.bool(forKey: "bar.enabled") }
        set { defaults.set(newValue, forKey: "bar.enabled") }
    }

    static var allScreens: Bool {
        get { defaults.object(forKey: "bar.allScreens") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "bar.allScreens") }
    }

    static let defaultItems: [BarItem] = [
        BarItem(kind: .desktops, side: .left, isOn: true),
        BarItem(kind: .app, side: .left, isOn: true),
        BarItem(kind: .lockIn, side: .left, isOn: true),
        BarItem(kind: .song, side: .right, isOn: true),
        BarItem(kind: .volume, side: .right, isOn: true),
        BarItem(kind: .battery, side: .right, isOn: true),
        BarItem(kind: .clock, side: .right, isOn: true),
    ]

    /// The items in order, each saved as "kind:side:on". Items added in later versions are put at the end.
    static var items: [BarItem] {
        get {
            let saved = (defaults.stringArray(forKey: "bar.items") ?? []).compactMap { entry -> BarItem? in
                let parts = entry.split(separator: ":").map(String.init)
                guard parts.count == 3, let kind = BarItemKind(rawValue: parts[0]),
                      let side = BarSide(rawValue: parts[1]) else { return nil }
                return BarItem(kind: kind, side: side, isOn: parts[2] == "1")
            }
            let missing = defaultItems.filter { item in !saved.contains { $0.kind == item.kind } }
            return saved + missing
        }
        set { defaults.set(newValue.map { "\($0.kind.rawValue):\($0.side.rawValue):\($0.isOn ? 1 : 0)" }, forKey: "bar.items") }
    }

    static var style: BarStyle {
        get { defaults.string(forKey: "bar.style").flatMap(BarStyle.init(rawValue:)) ?? .wallpaper }
        set { defaults.set(newValue.rawValue, forKey: "bar.style") }
    }

    static var color: NSColor {
        get { defaults.string(forKey: "bar.color").flatMap(NSColor.init(hex:)) ?? NSColor(srgbRed: 0.06, green: 0.09, blue: 0.15, alpha: 1) }
        set { defaults.set(newValue.hexString, forKey: "bar.color") }
    }

    static var opacity: Double {
        get { defaults.object(forKey: "bar.opacity") == nil ? 0.62 : defaults.double(forKey: "bar.opacity") }
        set { defaults.set(newValue, forKey: "bar.opacity") }
    }

    /// Which of the wallpaper's colours highlights the current desktop and the icons:
    /// 0 is its strongest colour, and -1 means the colour chosen below.
    static var accentIndex: Int {
        get { defaults.object(forKey: "bar.accentIndex") == nil ? 0 : defaults.integer(forKey: "bar.accentIndex") }
        set { defaults.set(newValue, forKey: "bar.accentIndex") }
    }

    static var accentColor: NSColor {
        get { defaults.string(forKey: "bar.accentColor").flatMap(NSColor.init(hex:)) ?? NSColor(srgbRed: 0.48, green: 0.64, blue: 1, alpha: 1) }
        set { defaults.set(newValue.hexString, forKey: "bar.accentColor") }
    }

    static var size: BarSize {
        get { defaults.string(forKey: "bar.size").flatMap(BarSize.init(rawValue:)) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "bar.size") }
    }

    static var font: BarFont {
        get { defaults.string(forKey: "bar.font").flatMap(BarFont.init(rawValue:)) ?? .rounded }
        set { defaults.set(newValue.rawValue, forKey: "bar.font") }
    }

    static var cornerRadius: Double {
        get { defaults.object(forKey: "bar.cornerRadius") == nil ? 9 : defaults.double(forKey: "bar.cornerRadius") }
        set { defaults.set(newValue, forKey: "bar.cornerRadius") }
    }

    static var showDate: Bool {
        get { defaults.object(forKey: "bar.showDate") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "bar.showDate") }
    }

    static var use24Hour: Bool {
        get { defaults.bool(forKey: "bar.use24Hour") }
        set { defaults.set(newValue, forKey: "bar.use24Hour") }
    }

    static var desktopStyle: DesktopStyle {
        get { defaults.string(forKey: "bar.desktopStyle").flatMap(DesktopStyle.init(rawValue:)) ?? .separate }
        set { defaults.set(newValue.rawValue, forKey: "bar.desktopStyle") }
    }

    /// Number each screen's desktops from 1, instead of counting across all screens as Mission Control does.
    static var numberPerScreen: Bool {
        get { defaults.bool(forKey: "bar.numberPerScreen") }
        set { defaults.set(newValue, forKey: "bar.numberPerScreen") }
    }

    /// Colours you've given desktops, by the desktop's id.
    static var desktopColours: [String: DesktopColour] {
        get {
            (defaults.dictionary(forKey: "bar.desktopColours") as? [String: String] ?? [:])
                .compactMapValues(DesktopColour.init(rawValue:))
        }
        set { defaults.set(newValue.mapValues(\.rawValue), forKey: "bar.desktopColours") }
    }

    /// Pointing at a desktop shows a small live picture of it.
    static var peekDesktops: Bool {
        get { defaults.object(forKey: "bar.peekDesktops") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "bar.peekDesktops") }
    }

    /// The song piece takes its colours from the album cover.
    static var albumColours: Bool {
        get { defaults.object(forKey: "bar.albumColours") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "bar.albumColours") }
    }

    /// Pointing at the song shows a small player.
    static var miniPlayer: Bool {
        get { defaults.object(forKey: "bar.miniPlayer") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "bar.miniPlayer") }
    }

    /// How long to hold the pointer at the very top of the screen before the macOS menu bar
    /// shows, in seconds, while the top bar takes its place.
    static var menuBarDelay: Double {
        get { defaults.object(forKey: "bar.menuBarDelay") == nil ? 1 : min(3, max(0.2, defaults.double(forKey: "bar.menuBarDelay"))) }
        set { defaults.set(newValue, forKey: "bar.menuBarDelay") }
    }

    // MARK: Lock-in mode

    /// The two apps, left then right, by bundle identifier.
    static var lockInApps: [String] {
        get { defaults.stringArray(forKey: "lockIn.apps") ?? [] }
        set { defaults.set(newValue, forKey: "lockIn.apps") }
    }

    /// The desktop lock-in mode uses, by its id. The first time, it's the one you're on.
    static var lockInDesktop: String? {
        get { defaults.string(forKey: "lockIn.desktop") }
        set { defaults.set(newValue, forKey: "lockIn.desktop") }
    }

    /// How much of the width the left app gets.
    static var lockInSplit: Double {
        get { defaults.object(forKey: "lockIn.split") == nil ? 0.5 : min(0.8, max(0.2, defaults.double(forKey: "lockIn.split"))) }
        set { defaults.set(newValue, forKey: "lockIn.split") }
    }

    /// The gap around and between the two apps, where the wallpaper shows.
    static var lockInGap: Double {
        get { defaults.object(forKey: "lockIn.gap") == nil ? 12 : defaults.double(forKey: "lockIn.gap") }
        set { defaults.set(newValue, forKey: "lockIn.gap") }
    }

    static var lockInHideOthers: Bool {
        get { defaults.object(forKey: "lockIn.hideOthers") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "lockIn.hideOthers") }
    }

    /// A glowing edge around the one you're using.
    static var lockInBorder: Bool {
        get { defaults.object(forKey: "lockIn.border") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "lockIn.border") }
    }

    /// A picture to use as the lock-in desktop's wallpaper, or nil to leave it as it is.
    static var lockInWallpaper: String? {
        get { defaults.string(forKey: "lockIn.wallpaper") }
        set { defaults.set(newValue, forKey: "lockIn.wallpaper") }
    }

    static var gameMode: GameMode {
        get { defaults.string(forKey: "bar.gameMode").flatMap(GameMode.init(rawValue:)) ?? .slide }
        set { defaults.set(newValue.rawValue, forKey: "bar.gameMode") }
    }

    /// Names you've given desktops, by the desktop's id.
    static var desktopNames: [String: String] {
        get { defaults.dictionary(forKey: "bar.desktopNames") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "bar.desktopNames") }
    }

    /// The top bar takes the macOS menu bar's place: Clear Dock sets the menu bar to hide itself
    /// while the bar is on. Off until you switch it on.
    static var replaceMenuBar: Bool {
        get { defaults.bool(forKey: "bar.replaceMenuBar") }
        set { defaults.set(newValue, forKey: "bar.replaceMenuBar") }
    }

    /// Whether the bar needs colours taken from the wallpaper.
    static var usesWallpaper: Bool { enabled && (style == .wallpaper || accentIndex >= 0) }

    /// Whether the top bar goes along the very top of the screen, in the macOS menu bar's place,
    /// rather than under it: when Clear Dock has hidden the menu bar for it, or the menu bar
    /// hides itself anyway. Clear Dock knows straight away when it has hidden the menu bar,
    /// without waiting for macOS to finish sliding it away.
    @MainActor static var takesMenuBarsPlace: Bool {
        (enabled && replaceMenuBar && SystemMenuBar.isHiddenByClearDock) || macMenuBarHidden
    }

    /// Whether "Automatically hide and show the menu bar" is set to Always.
    @MainActor static var macMenuBarHidden: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        if (CFPreferencesCopyAppValue("_HIHideMenuBar" as CFString, kCFPreferencesAnyApplication) as? NSNumber)?.boolValue == true {
            return true
        }
        // In case macOS keeps the setting somewhere else: a screen without a notch that keeps no
        // room for the menu bar along its top means the menu bar is hiding itself.
        return NSScreen.screens.contains { $0.safeAreaInsets.top == 0 && $0.frame.maxY - $0.visibleFrame.maxY < 1 }
    }

    /// Opens the System Settings page with "Automatically hide and show the menu bar".
    static func openMenuBarSettings() {
        for page in ["x-apple.systempreferences:com.apple.ControlCenter-Settings.extension",
                     "x-apple.systempreferences:com.apple.preference.dock"] {
            if let url = URL(string: page), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Posted when a bar setting changes outside the settings window (for example from a menu).
    static let didChange = Notification.Name("ClearDockBarSettingsChanged")
}

/// Hides the macOS menu bar while the top bar takes its place, the supported way: by asking
/// System Events to turn on "Automatically hide and show the menu bar". The setting from before
/// is saved first, so `restore()` can put it back exactly. macOS asks you once to let Clear Dock
/// control System Events.
@MainActor
enum SystemMenuBar {
    private static let savedKey = "savedMenuBarAutohide"

    /// Whether Clear Dock has hidden the menu bar (and has the earlier setting saved).
    static var isHiddenByClearDock: Bool { UserDefaults.standard.object(forKey: savedKey) != nil }

    /// Returns false if macOS didn't allow it.
    @discardableResult
    static func hide() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: savedKey) == nil {
            guard let current = run("get autohide menu bar of dock preferences") else { return false }
            defaults.set(current.booleanValue, forKey: savedKey)
        }
        guard run("set autohide menu bar of dock preferences to true") != nil else {
            defaults.removeObject(forKey: savedKey)
            return false
        }
        return true
    }

    static func restore() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.object(forKey: savedKey) as? Bool else { return }
        if run("set autohide menu bar of dock preferences to \(saved)") != nil {
            defaults.removeObject(forKey: savedKey)
        }
    }

    /// Whether macOS has refused Clear Dock control of System Events.
    private(set) static var refused = false

    private static func run(_ command: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: "tell application \"System Events\" to \(command)")?.executeAndReturnError(&error)
        if let error {
            // -1743: not allowed to control System Events (Privacy & Security > Automation).
            refused = (error[NSAppleScript.errorNumber] as? Int) == -1743
            NSLog("Clear Dock: couldn't change the menu bar: \(error)")
            return nil
        }
        refused = false
        return result
    }

    static func openAutomationSettings() {
        SystemSettings.open("com.apple.preference.security?Privacy_Automation")
    }
}

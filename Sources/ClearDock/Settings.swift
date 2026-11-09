import Foundation
import ServiceManagement

enum Settings {
    private static var defaults: UserDefaults { .standard }

    /// Posted when a dock setting changes outside the settings window (from the dock's menus), so
    /// the window, if it's open, shows it, and doesn't save over it with what it showed before.
    static let changedElsewhere = Notification.Name("ClearDockSettingsChangedElsewhere")

    static func announceChangeElsewhere() {
        NotificationCenter.default.post(name: changedElsewhere, object: nil)
    }

    /// Which screen edge the dock sits on.
    static var position: DockEdge {
        get { defaults.string(forKey: "position").flatMap(DockEdge.init(rawValue:)) ?? .bottom }
        set { defaults.set(newValue.rawValue, forKey: "position") }
    }

    static var autoHide: Bool {
        get { defaults.bool(forKey: "autoHide") }
        set { defaults.set(newValue, forKey: "autoHide") }
    }

    static var showPinned: Bool {
        get { defaults.bool(forKey: "showPinned") }
        set { defaults.set(newValue, forKey: "showPinned") }
    }

    /// Apps never shown in the dock, even while they're open (like a live wallpaper app that
    /// counts as an ordinary app), by their id in the dock.
    static var hiddenApps: [String] {
        get { defaults.stringArray(forKey: "hiddenApps") ?? [] }
        set { defaults.set(newValue, forKey: "hiddenApps") }
    }

    static var showTrash: Bool {
        get { defaults.bool(forKey: "showTrash") }
        set { defaults.set(newValue, forKey: "showTrash") }
    }

    static var hideSystemDock: Bool {
        get { defaults.bool(forKey: "hideSystemDock") }
        set { defaults.set(newValue, forKey: "hideSystemDock") }
    }

    /// Clicking the icon of the app you're already in hides it.
    static var clickToHide: Bool {
        get { defaults.bool(forKey: "clickToHide") }
        set { defaults.set(newValue, forKey: "clickToHide") }
    }

    static var showPreviews: Bool {
        get { defaults.bool(forKey: "showPreviews") }
        set { defaults.set(newValue, forKey: "showPreviews") }
    }

    static var showBadges: Bool {
        get { defaults.bool(forKey: "showBadges") }
        set { defaults.set(newValue, forKey: "showBadges") }
    }

    /// Scrolling up on an icon shows that app's windows, like the macOS Dock's "scroll-to-open".
    static var scrollToOpen: Bool {
        get { defaults.bool(forKey: "scrollToOpen") }
        set { defaults.set(newValue, forKey: "scrollToOpen") }
    }

    /// Pictures you've chosen to use as app icons, by app (bundle identifier) and file path.
    static var customIcons: [String: String] {
        get { defaults.dictionary(forKey: "customIcons") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "customIcons") }
    }

    /// The order you've dragged apps into, by bundle identifier.
    static var appOrder: [String] {
        get { defaults.stringArray(forKey: "appOrder") ?? [] }
        set { defaults.set(newValue, forKey: "appOrder") }
    }

    static var iconSize: Double {
        get { min(max(defaults.double(forKey: "iconSize"), 24), 128) }
        set { defaults.set(newValue, forKey: "iconSize") }
    }

    /// The first time Clear Dock runs, start from how the macOS Dock is set up.
    static func seedFromSystemDock() {
        let id = Bundle.main.bundleIdentifier ?? "local.cleardock"
        let stored = defaults.persistentDomain(forName: id) ?? [:]
        func seed(_ key: String, _ value: @autoclosure () -> Any) {
            if stored[key] == nil { defaults.set(value(), forKey: key) }
        }
        seed("autoHide", SystemDock.original("autohide")?.boolValue ?? false)
        // "static-only" is the macOS Dock setting that shows only open apps.
        seed("showPinned", !(SystemDock.bool("static-only") ?? false))
        seed("showTrash", true)
        seed("hideSystemDock", true)
        seed("showBadges", true)
        seed("showPreviews", true)
        seed("scrollToOpen", SystemDock.bool("scroll-to-open") ?? false)
        seed("iconSize", SystemDock.original("tilesize")?.doubleValue ?? 48)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

import Foundation

/// Reads the macOS Dock's own preferences, and hides or restores the macOS Dock.
///
/// Hiding works by turning on the Dock's auto-hide with a very long reveal delay,
/// and turning off bouncing (a bouncing app would otherwise pop the hidden Dock up).
/// macOS still shows its Dock in Mission Control whatever the settings, so it is also
/// shrunk to its smallest size and moved to the left edge to keep it out of the way there.
/// The original values are saved first so `restore()` can put them back exactly.
enum SystemDock {
    private static let domain = "com.apple.dock" as CFString
    private static let savedKey = "savedSystemDockValues"
    /// Saved in place of a value to mean "this setting wasn't set before".
    private static let notSet = ""

    private struct Override {
        let key: String
        let type: String
        let value: String
    }

    private static let overrides = [
        Override(key: "autohide", type: "-bool", value: "true"),
        Override(key: "autohide-delay", type: "-float", value: "1000"),
        Override(key: "no-bouncing", type: "-bool", value: "true"),
        // Below the usual minimum of 16; macOS accepts it, leaving only a sliver in Mission Control.
        Override(key: "tilesize", type: "-int", value: "1"),
        Override(key: "orientation", type: "-string", value: "left"),
    ]

    static func value(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    static func bool(_ key: String) -> Bool? { (value(key) as? NSNumber)?.boolValue }
    static func double(_ key: String) -> Double? { (value(key) as? NSNumber)?.doubleValue }

    /// The value from before Clear Dock hid the Dock, if it has; otherwise the current value.
    static func original(_ key: String) -> NSNumber? {
        if let saved = UserDefaults.standard.dictionary(forKey: savedKey), let v = saved[key] {
            return v as? NSNumber
        }
        return value(key) as? NSNumber
    }

    static func hide() {
        // Record each setting's value before changing it, once. A setting already changed
        // but not recorded (from an older Clear Dock) can only have been unset before.
        let defaults = UserDefaults.standard
        var saved = defaults.dictionary(forKey: savedKey) ?? [:]
        for o in overrides where saved[o.key] == nil {
            saved[o.key] = isApplied(o) ? notSet : (value(o.key) ?? notSet)
        }
        defaults.set(saved, forKey: savedKey)

        var changed = false
        for o in overrides where !isApplied(o) {
            run("/usr/bin/defaults", ["write", "com.apple.dock", o.key, o.type, o.value])
            changed = true
        }
        if changed { restartDock() }
    }

    static func restore() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.dictionary(forKey: savedKey) else { return }
        for o in overrides {
            if let text = saved[o.key] as? String, text != notSet {
                run("/usr/bin/defaults", ["write", "com.apple.dock", o.key, o.type, text])
            } else if let v = saved[o.key] as? NSNumber {
                let text: String
                switch o.type {
                case "-bool": text = v.boolValue ? "true" : "false"
                case "-int": text = String(v.intValue)
                default: text = String(v.doubleValue)
                }
                run("/usr/bin/defaults", ["write", "com.apple.dock", o.key, o.type, text])
            } else {
                run("/usr/bin/defaults", ["delete", "com.apple.dock", o.key])
            }
        }
        defaults.removeObject(forKey: savedKey)
        restartDock()
    }

    /// File URLs of the apps pinned to the macOS Dock, in Dock order.
    static func pinnedApps() -> [URL] {
        guard let tiles = value("persistent-apps") as? [[String: Any]] else { return [] }
        return tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String else { return nil }
            let url = string.hasPrefix("file:") ? URL(string: string) : URL(fileURLWithPath: string)
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    private static func isApplied(_ o: Override) -> Bool {
        if o.type == "-bool" { return bool(o.key) == (o.value == "true") }
        if o.type == "-string" { return value(o.key) as? String == o.value }
        guard let current = double(o.key), let wanted = Double(o.value) else { return false }
        return abs(current - wanted) < 0.5
    }

    private static func restartDock() {
        run("/usr/bin/killall", ["Dock"])
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Clear Dock: could not run \(path): \(error)")
        }
    }
}

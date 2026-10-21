import AppKit
import ApplicationServices

/// Reads notification counts from the macOS Dock. Apps now hand their counts only to the Dock,
/// which shows them to accessibility tools, so this needs Accessibility permission.
/// It is only asked while Clear Dock is on screen.
@MainActor
enum BadgeReader {
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security > Accessibility.
    static func askForPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Notification counts keyed by app bundle path. Empty without permission.
    static func read() -> [String: String] {
        let started = CACurrentMediaTime()
        defer {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            if ms > 30 { previewLog.notice("Timing: reading badges took \(ms) ms") }
        }
        guard hasPermission,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        // Never wait long on the Dock, e.g. while it restarts.
        AXUIElementSetMessagingTimeout(dockElement, 0.25)

        var result: [String: String] = [:]
        for list in children(of: dockElement) where string(list, kAXRoleAttribute) == kAXListRole {
            for item in children(of: list) where string(item, kAXSubroleAttribute) == "AXApplicationDockItem" {
                guard let label = string(item, "AXStatusLabel"), let url = url(item) else { continue }
                result[url.path] = label
            }
        }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func url(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        return (value as? URL)?.standardizedFileURL
    }
}

/// Hands memory freed after one-off heavy work (loading icons, taking window pictures)
/// back to the system, once that work has finished and let go of it.
@MainActor
enum MemoryRelief {
    private static var scheduled = false

    static func soon() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                scheduled = false
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }
}

/// Tells real windows from "ghosts": windows an app keeps hidden in the background
/// (TradingView keeps several). A real window is placed on one of your desktops (Spaces),
/// even when that desktop isn't showing; a ghost isn't placed anywhere.
/// Uses the window server's private calls, as Vorssaint and other window tools do.
enum WindowSpaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias IsOrderedIn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Bool>) -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let anywhere = UnsafeMutableRawPointer(bitPattern: -2)  // search every loaded library
    private static let connection: Int32? = dlsym(anywhere, "CGSMainConnectionID")
        .map { unsafeBitCast($0, to: MainConnection.self)() }
    private static let isOrderedIn: IsOrderedIn? = dlsym(anywhere, "CGSWindowIsOrderedIn")
        .map { unsafeBitCast($0, to: IsOrderedIn.self) }
    private static let copySpaces: CopySpaces? = dlsym(anywhere, "CGSCopySpacesForWindows")
        .map { unsafeBitCast($0, to: CopySpaces.self) }

    /// Whether the window is placed on a desktop. If the system won't say, assume it is.
    static func isPlaced(_ windowID: CGWindowID) -> Bool {
        guard let connection, let isOrderedIn, let copySpaces else { return true }
        var orderedIn = false
        _ = isOrderedIn(connection, windowID, &orderedIn)
        guard orderedIn else { return false }
        let spaces = copySpaces(connection, 0x7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        return !(spaces ?? []).isEmpty
    }

    /// The desktops a window is placed on, by the window server's ids for them. Empty for a
    /// window that isn't placed anywhere (minimized, in a hidden app, or a ghost).
    static func spaceIDs(of windowID: CGWindowID) -> [UInt64] {
        guard let connection, let isOrderedIn, let copySpaces else { return [] }
        var orderedIn = false
        _ = isOrderedIn(connection, windowID, &orderedIn)
        guard orderedIn else { return [] }
        let spaces = copySpaces(connection, 0x7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        return (spaces ?? []).map(\.uint64Value)
    }

    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let copyDisplaySpaces: CopyDisplaySpaces? = dlsym(anywhere, "CGSCopyManagedDisplaySpaces")
        .map { unsafeBitCast($0, to: CopyDisplaySpaces.self) }

    /// Every display's desktops, as Mission Control has them: one entry per display (or a single
    /// "Main" entry when displays share desktops), with its "Spaces" and its "Current Space".
    static func displaySpaces() -> [[String: Any]] {
        guard let connection, let copyDisplaySpaces else { return [] }
        return copyDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
    }
}

/// The app's own list of its windows, through Accessibility. It includes minimized windows,
/// which aren't placed on any desktop while they're in the Dock.
enum AppWindowList {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    /// The window number of an accessibility window.
    static func windowID(of window: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(window, &id) == .success ? id : nil
    }

    /// The level a window sits at: 0 for ordinary windows, higher for things like a game's
    /// full-screen layer.
    static func layer(of windowID: CGWindowID) -> Int? {
        let info = CGWindowListCreateDescriptionFromArray([NSNumber(value: windowID)] as CFArray) as? [[String: Any]]
        return info?.first?[kCGWindowLayer as String] as? Int
    }

    static func windowIDs(of pid: pid_t) -> Set<CGWindowID> {
        guard AXIsProcessTrusted(), let getWindow else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        var ids = Set<CGWindowID>()
        for window in windows {
            var id: CGWindowID = 0
            if getWindow(window, &id) == .success { ids.insert(id) }
        }
        return ids
    }
}

/// Games, which Clear Dock leaves alone: it never moves their windows, and the top bar steps
/// aside while one is in front. An app counts as a game when it says so in its own settings.
@MainActor
enum Games {
    private static var known: [pid_t: Bool] = [:]

    static func isGame(_ pid: pid_t) -> Bool {
        if let answer = known[pid] { return answer }
        let category = NSRunningApplication(processIdentifier: pid)?.bundleURL
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
        let answer = category?.contains("games") ?? false
        known[pid] = answer
        return answer
    }
}

/// The system's private channel to the Dock, used here only to open App Exposé.
enum CoreDock {
    private typealias SendNotification = @convention(c) (CFString, Int32) -> Void

    private static let sendNotification: SendNotification? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let symbol = dlsym(handle, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(symbol, to: SendNotification.self)
    }()

    static func send(_ notification: String) {
        sendNotification?(notification as CFString, 0)
    }
}

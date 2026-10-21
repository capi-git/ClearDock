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

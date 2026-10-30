import AppKit
import Synchronization
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

    /// Notification counts keyed by app bundle path. Empty without permission. Asks the Dock
    /// through Accessibility, so it's called away from the main thread.
    nonisolated static func read() -> [String: String] {
        let started = CACurrentMediaTime()
        defer {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            if ms > 30 { previewLog.notice("Timing: reading badges took \(ms) ms") }
        }
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        // Never wait long on the Dock, e.g. while it restarts.
        AXUIElementSetMessagingTimeout(dockElement, 0.25)

        var result: [String: String] = [:]
        let wanted = [kAXSubroleAttribute, "AXStatusLabel", kAXURLAttribute] as CFArray
        for list in children(of: dockElement) where string(list, kAXRoleAttribute) == kAXListRole {
            for item in children(of: list) {
                // All three in one question to the Dock, rather than one each.
                var answers: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(item, wanted, AXCopyMultipleAttributeOptions(rawValue: 0), &answers) == .success,
                      let values = answers as? [Any], values.count == 3,
                      values[0] as? String == "AXApplicationDockItem",
                      let label = values[1] as? String, !label.isEmpty,
                      let url = (values[2] as? URL)?.standardizedFileURL else { continue }
                result[url.path] = label
            }
        }
        return result
    }

    nonisolated private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
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
            MainActor.assumeIsolated { scheduled = false }
            // It goes through all of the app's memory, so not on the main thread.
            DispatchQueue.global(qos: .utility).async { _ = malloc_zone_pressure_relief(nil, 0) }
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

    /// The desktop (or full-screen app) showing on a screen right now, by the window server's id.
    @MainActor static func currentSpaceID(on screen: NSScreen) -> UInt64? {
        let displays = displaySpaces()
        let display = displays.first { ($0["Display Identifier"] as? String) == screen.displayUUID }
            ?? displays.first { ($0["Display Identifier"] as? String) == "Main" }
        let current = display?["Current Space"] as? [String: Any]
        return ((current?["id64"] ?? current?["ManagedSpaceID"]) as? NSNumber)?.uint64Value
    }

    /// The desktop (or full-screen app) showing on each display right now, by the window server's ids.
    static func currentSpaceIDs() -> Set<UInt64> {
        Set(displaySpaces().compactMap { display in
            let current = display["Current Space"] as? [String: Any]
            return ((current?["id64"] ?? current?["ManagedSpaceID"]) as? NSNumber)?.uint64Value
        })
    }
}

/// Keeps Clear Dock's windows that belong on every desktop (the dock, its labels and previews) on
/// every desktop. macOS can tie one to a single desktop: leaving a full-screen app, it puts the
/// windows that were over it back on the desktop the app came from, and a window allowed over
/// full-screen apps, like the dock, can go with them, missing from every other desktop after that.
@MainActor
enum EveryDesktop {
    private static var pending: DispatchWorkItem?

    /// Looks a moment after the desktop changes, once any full-screen app has finished leaving.
    static func checkSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { check(repairing: true) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private static func check(repairing: Bool) {
        // Window numbers as the window server knows them (one never shown has none, a negative one).
        let numbers = NSApp.windows.filter { $0.collectionBehavior.contains(.canJoinAllSpaces) }
            .compactMap { CGWindowID(exactly: $0.windowNumber) }
        guard !numbers.isEmpty else { return }
        // The window server is asked off the main thread.
        DispatchQueue.global(qos: .utility).async {
            let desktops = Set(WindowSpaces.displaySpaces().flatMap { display in
                ((display["Spaces"] as? [[String: Any]]) ?? []).compactMap { space -> UInt64? in
                    // Ordinary desktops only, not full-screen apps.
                    guard (space["type"] as? Int) == 0 else { return nil }
                    return ((space["id64"] ?? space["ManagedSpaceID"]) as? NSNumber)?.uint64Value
                }
            })
            // One not showing, or in the top bar's own layer, isn't on any desktop: nothing to put right.
            let stuck = numbers.filter { number in
                let on = Set(WindowSpaces.spaceIDs(of: number))
                return !on.isEmpty && !desktops.isSubset(of: on)
            }
            guard !stuck.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard repairing else {
                        return dockLog.notice("Dock: \(stuck.count) windows still on only some desktops")
                    }
                    repair(stuck)
                }
            }
        }
    }

    private static func repair(_ numbers: [CGWindowID]) {
        dockLog.notice("Dock: \(numbers.count) windows were on only some desktops; putting them back on all of them")
        let wanted = Set(numbers.map { Int($0) })
        let windows = NSApp.windows.filter { wanted.contains($0.windowNumber) }
        let behaviors = windows.map(\.collectionBehavior)
        // Off every desktop but this one for a moment, then back on all: macOS adds each to every
        // desktop again.
        for (window, behavior) in zip(windows, behaviors) {
            window.collectionBehavior = behavior.subtracting(.canJoinAllSpaces).union(.moveToActiveSpace)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                for (window, behavior) in zip(windows, behaviors) { window.collectionBehavior = behavior }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated { check(repairing: false) }
                }
            }
        }
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
        // It takes the window numbers themselves in the list, not numbers wrapped as objects (with
        // those it quietly finds nothing).
        var number: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard number != nil, let list = CFArrayCreate(nil, &number, 1, nil) else { return nil }
        let info = CGWindowListCreateDescriptionFromArray(list) as? [[String: Any]]
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
enum Games {
    /// Asked from the main thread and from the window keeper's, so kept behind a lock.
    private static let known = Mutex<[pid_t: Bool]>([:])

    /// Game launchers that don't say they're games (League of Legends' says nothing, Riot Client's
    /// says developer tools), by the start of their bundle identifier.
    private static let launchers = ["com.riotgames.", "com.valvesoftware.steam", "com.blizzard.", "net.battle.",
                                    "com.epicgames.", "com.mojang."]

    static func isGame(_ pid: pid_t) -> Bool {
        if let answer = known.withLock({ $0[pid] }) { return answer }
        let app = NSRunningApplication(processIdentifier: pid)
        let category = app?.bundleURL
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
        let bundle = app?.bundleIdentifier ?? ""
        let answer = category?.contains("games") == true || launchers.contains { bundle.hasPrefix($0) }
        known.withLock { $0[pid] = answer }
        return answer
    }
}

/// A layer of the screen of Clear Dock's own, shown on every desktop, for the top bar's windows.
/// Windows in it stay still while you switch desktops, instead of sliding along with them (which
/// every window on all desktops otherwise does). Window levels still decide what's in front, so the
/// bar stays above the macOS menu bar and below notch apps' islands. Uses the window server's
/// private calls, as notch apps do.
@MainActor
enum BarSpace {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias Show = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, CFArray, CFArray) -> Void

    private static let anywhere = UnsafeMutableRawPointer(bitPattern: -2)
    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        dlsym(anywhere, name).map { unsafeBitCast($0, to: type) }
    }

    /// Made the first time it's needed; it goes away when Clear Dock quits.
    private static let space: (connection: Int32, id: UInt64)? = {
        guard let connection = symbol("CGSMainConnectionID", Connection.self)?(),
              let create = symbol("CGSSpaceCreate", Create.self),
              let setLevel = symbol("CGSSpaceSetAbsoluteLevel", SetLevel.self),
              let show = symbol("CGSShowSpaces", Show.self) else { return nil }
        let id = create(connection, 1, nil)
        guard id != 0 else { return nil }
        _ = setLevel(connection, id, 0)
        _ = show(connection, [NSNumber(value: id)] as CFArray)
        return (connection, id)
    }()

    /// Puts a window in the layer. It needs to have been shown once first.
    static func add(_ window: NSWindow) {
        guard window.windowNumber > 0, let space,
              let add = symbol("CGSAddWindowsToSpaces", AddWindows.self) else { return }
        add(space.connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space.id)] as CFArray)
    }
}

/// The windows on screen, by number only, which is several times cheaper to ask for than their details.
enum OnScreenWindows {
    private typealias ListCreate = @convention(c) (UInt32, UInt32) -> Unmanaged<CFArray>?
    /// Not offered to Swift directly, though it's public.
    private static let create: ListCreate? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreate")
        .map { unsafeBitCast($0, to: ListCreate.self) }

    /// On screen, or with `everywhere`, on every desktop too.
    static func numbers(everywhere: Bool = false) -> [UInt] {
        let option: CGWindowListOption = everywhere ? .optionAll : .optionOnScreenOnly
        guard let create, let list = create(option.rawValue, 0)?.takeRetainedValue() else { return [] }
        return (0..<CFArrayGetCount(list)).map { UInt(bitPattern: CFArrayGetValueAtIndex(list, $0)) }
    }
}

/// Mission Control and App Exposé. macOS doesn't announce either, but while one is open its
/// window manager draws a backdrop over each screen. Safe to ask from any thread.
enum MissionControl {
    /// Where its backdrops are, in the system's window coordinates; none while it's closed.
    static func backdrops() -> [CGRect] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { info in
            guard info[kCGWindowOwnerName as String] as? String == "WindowManager", info[kCGWindowLayer as String] as? Int == 19,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
    }

    /// Whether it's open on any screen right now: a backdrop covering a whole display.
    static var isShowing: Bool {
        let backdrops = backdrops()
        guard !backdrops.isEmpty else { return false }
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { display in
            let bounds = CGDisplayBounds(display)
            return backdrops.contains { $0.insetBy(dx: -2, dy: -2).contains(bounds.insetBy(dx: 2, dy: 2)) }
        }
    }
}

/// Hears the macOS Dock, which draws Mission Control and App Exposé, change what it's showing:
/// it reports its selection changing as either opens or closes (macOS announces neither). Only a
/// hint to go and look, so nothing needs checking several times a second. Follows the Dock when it
/// restarts.
@MainActor
final class DockActivityWatch {
    private let onActivity: @MainActor () -> Void
    private var observer: AXObserver?
    private var dockPID: pid_t = 0
    private var launchToken: NSObjectProtocol?

    init(onActivity: @escaping @MainActor () -> Void) {
        self.onActivity = onActivity
        launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.dock" else { return }
            MainActor.assumeIsolated { self?.attach() }
        }
        attach()
    }

    func stop() {
        detach()
        if let launchToken { NSWorkspace.shared.notificationCenter.removeObserver(launchToken) }
        launchToken = nil
    }

    private var retries = 0

    private func attach() {
        guard AXIsProcessTrusted() else { return }
        // Not listed yet, or not answering yet: Clear Dock often starts just as the Dock restarts
        // (to hide it), and a Dock that has only just started doesn't take requests for a moment.
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return retry() }
        guard dock.processIdentifier != dockPID || observer == nil else { return }
        detach()
        var created: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, { _, _, _, refcon in
            guard let refcon else { return }
            let watch = Unmanaged<DockActivityWatch>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watch.onActivity() }
        }, &created) == .success, let observer = created else { return retry() }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard AXObserverAddNotification(observer, app, kAXSelectedChildrenChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return retry() }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = observer
        dockPID = dock.processIdentifier
        retries = 0
        dockLog.notice("Mission Control: following the Dock")
    }

    private func retry() {
        guard launchToken != nil else { return }
        guard retries < 20 else {
            return dockLog.notice("Mission Control: the Dock doesn't answer; looking every second and a half instead")
        }
        retries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    private func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        dockPID = 0
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

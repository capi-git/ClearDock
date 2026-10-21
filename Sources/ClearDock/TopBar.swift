import AppKit
import SwiftUI

/// How the top bar looks right now, worked out from its settings and the wallpaper.
struct BarLook: Equatable {
    var style = BarStyle.wallpaper
    var fill = NSColor.black
    var opacity = 0.62
    var accent = NSColor.systemBlue
    var size = BarSize.medium
    var font = BarFont.rounded
    var cornerRadius: CGFloat = 9
    var showDate = true
    var use24Hour = false
    var desktopStyle = DesktopStyle.separate
    var numberPerScreen = false

    /// Dark text on a light bar, light text otherwise.
    var text: Color {
        let lightBar = (style == .color || style == .wallpaper) && opacity > 0.45 && fill.lightness > 0.6
        return lightBar ? Color.black.opacity(0.82) : Color.white.opacity(0.94)
    }
    var onAccent: Color { accent.lightness > 0.5 ? Color.black.opacity(0.8) : .white }

    func font(_ weight: Font.Weight, size points: CGFloat? = nil) -> Font {
        let points = points ?? size.fontSize
        switch font {
        case .rounded: return .system(size: points, weight: weight, design: .rounded)
        case .standard: return .system(size: points, weight: weight)
        case .mono: return .system(size: points - 0.5, weight: weight, design: .monospaced)
        }
    }
}

/// Where a screen's bar puts things: its width, and the room left in the middle for the camera
/// notch or another app's island (like Vorssaint's).
struct BarLayout: Equatable {
    var width: CGFloat = 0
    var middleGap: CGFloat = 0
    /// Which display's desktops this bar shows.
    var desktopsKey = "Main"
}

/// Everything the bar views draw from. Shared by the bars on every screen.
@MainActor
final class TopBarModel: ObservableObject {
    @Published var items: [BarItem] = []
    @Published var look = BarLook()
    @Published var layouts: [String: BarLayout] = [:]
    @Published var desktops: [String: [Desktop]] = [:]
    @Published var desktopNames: [String: String] = [:]
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var track: NowPlaying.Track?
    @Published var volume: Float?
    @Published var muted = false
    @Published var battery: Int?
    @Published var charging = false
    @Published var pluggedIn = false
    @Published var now = Date()

    /// Things the views ask the controller to do.
    var toggleMute: () -> Void = {}
    var changeVolume: (Float) -> Void = { _ in }
    var rename: (Desktop) -> Void = { _ in }
    var forget: (Desktop) -> Void = { _ in }
    var hide: (BarItemKind) -> Void = { _ in }

    private var icons: [pid_t: NSImage] = [:]

    func icon(for pid: pid_t) -> NSImage? {
        if let icon = icons[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }

    /// Forget icons of apps that have quit.
    func pruneIcons() {
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        icons = icons.filter { running.contains($0.key) }
    }
}

/// A see-through strip along the top of a screen: below the macOS menu bar (which covers it when
/// it slides down) and below notch apps like Vorssaint, so their islands draw over it. It isn't
/// shown over full-screen apps.
@MainActor
final class BarPanel: OverlayPanel {
    override init() {
        super.init()
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
    }

    /// macOS keeps windows below the menu bar's spot even while the menu bar is hidden; the
    /// bar goes exactly where it's put, so it can take that spot.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts a bar's view, and notices when the pointer reaches the very top of the screen, where
/// the macOS menu bar slides down.
@MainActor
final class BarHostingView: NSHostingView<TopBarView> {
    var onTopEdge: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.mouseMoved) }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let window, let screen = window.screen else { return }
        if NSEvent.mouseLocation.y >= screen.frame.maxY - 1.5 { onTopEdge() }
    }
}

/// Puts a bar along the top of each screen and keeps what it shows up to date. Everything is
/// driven by system events, apart from a light check of each desktop's windows every few seconds
/// (macOS doesn't announce windows opening and closing).
@MainActor
final class TopBarController {
    private let model = TopBarModel()
    private var panels: [CGDirectDisplayID: (panel: BarPanel, view: BarHostingView)] = [:]
    private let nowPlaying = NowPlaying()
    private let volume = SystemVolume()
    private let battery = BatteryStatus()
    private var running = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var clockTimer: Timer?
    private var desktopTimer: Timer?
    private var revealTimer: Timer?
    private var revealStarted = Date.distantPast
    private var pendingLayout: DispatchWorkItem?

    init() {
        nowPlaying.onChange = { [weak self] in
            guard let self else { return }
            self.model.track = self.nowPlaying.track
            // A notch app's island often grows while music plays; make room once it has.
            self.scheduleLayout(after: 1)
        }
        volume.onChange = { [weak self] in
            guard let self else { return }
            if self.model.volume != self.volume.level { self.model.volume = self.volume.level }
            if self.model.muted != self.volume.muted { self.model.muted = self.volume.muted }
        }
        battery.onChange = { [weak self] in
            guard let self else { return }
            self.model.battery = self.battery.percent
            self.model.charging = self.battery.charging
            self.model.pluggedIn = self.battery.pluggedIn
        }
        model.toggleMute = { [weak self] in self?.volume.toggleMute() }
        model.changeVolume = { [weak self] change in
            guard let self, let level = self.volume.level else { return }
            self.volume.set(level + change)
        }
        model.rename = { [weak self] desktop in self?.rename(desktop) }
        model.forget = { desktop in
            var names = BarSettings.desktopNames
            names[desktop.key] = nil
            BarSettings.desktopNames = names
            NotificationCenter.default.post(name: BarSettings.didChange, object: nil)
        }
        model.hide = { kind in
            BarSettings.items = BarSettings.items.map { $0.kind == kind ? BarItem(kind: $0.kind, side: $0.side, isOn: false) : $0 }
            NotificationCenter.default.post(name: BarSettings.didChange, object: nil)
        }

        NotificationCenter.default.addObserver(forName: BarSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        settingsChanged()
    }

    func settingsChanged() {
        applyMenuBarSetting()
        guard BarSettings.enabled else { return stop() }
        start()
        model.items = BarSettings.items
        model.desktopNames = BarSettings.desktopNames
        applyLook()
        refreshWallpaperColors()
        layout()
    }

    /// Hides the macOS menu bar while the bar replaces it, and puts it back otherwise.
    private func applyMenuBarSetting() {
        let wanted = BarSettings.enabled && BarSettings.replaceMenuBar
        if wanted {
            // Only once: other settings changes shouldn't ask System Events again.
            guard !SystemMenuBar.isHiddenByClearDock, SystemMenuBar.hide() else { return }
        } else {
            guard SystemMenuBar.isHiddenByClearDock else { return }
            SystemMenuBar.restore()
        }
        // Move the bar now, and again once the menu bar has finished sliding away or back,
        // since windows and the notch area only settle then.
        layout()
        for delay in [0.4, 1.2, 3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.layout() }
            }
        }
    }

    // MARK: Starting and stopping

    private func start() {
        guard !running else { return }
        running = true
        nowPlaying.start()
        volume.start()
        battery.start()
        model.track = nowPlaying.track

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.refreshDesktops(); $0.refreshWallpaperColors(); $0.scheduleLayout(after: 0.4) }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.refreshFrontApp(); $0.refreshDesktops() }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observe(workspace, name) { $0.refreshDesktops(); $0.model.pruneIcons() }
        }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.tick(); $0.refreshDesktops(); $0.layout() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.layout() }
        observe(.default, WallpaperPalette.didChange) { $0.applyLook() }
        observe(.default, .NSSystemTimeZoneDidChange) { $0.tick() }
        // Turning "Automatically hide and show the menu bar" on or off moves the bar.
        observe(DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceMenuBarHidingChangedNotification")) {
            $0.scheduleLayout(after: 0.5)
        }

        let desktops = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDesktops() }
        }
        desktops.tolerance = 2
        RunLoop.main.add(desktops, forMode: .common)
        desktopTimer = desktops

        tick()
        refreshFrontApp()
        refreshDesktops()
    }

    private func stop() {
        guard running else { return }
        running = false
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        nowPlaying.stop()
        volume.stop()
        battery.stop()
        clockTimer?.invalidate()
        clockTimer = nil
        desktopTimer?.invalidate()
        desktopTimer = nil
        revealTimer?.invalidate()
        revealTimer = nil
        pendingLayout?.cancel()
        for (_, entry) in panels { entry.panel.orderOut(nil) }
        panels.removeAll()
        DockSpaceKeeper.shared.reserveTop([])
        MemoryRelief.soon()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (TopBarController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                handler(self)
            }
        }
        tokens.append((center, token))
    }

    // MARK: Placing the bars

    private func scheduleLayout(after delay: TimeInterval) {
        guard running else { return }
        pendingLayout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.layout() }
        }
        pendingLayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func layout() {
        guard running else { return }
        let screens = BarSettings.allScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        let replacesMenuBar = BarSettings.takesMenuBarsPlace
        let islands = Self.islands()
        let sharedDesktops = model.desktops.keys.contains("Main")
        var layouts: [String: BarLayout] = [:]
        var reserved: [(bottom: CGFloat, screen: NSScreen)] = []
        var kept = Set<CGDirectDisplayID>()

        for screen in screens {
            guard let id = screen.displayID else { continue }
            kept.insert(id)
            let frame = barFrame(on: screen, replacesMenuBar: replacesMenuBar)
            let entry = panels[id] ?? makePanel(for: id)
            if entry.panel.frame != frame { entry.panel.setFrame(frame, display: true) }
            entry.panel.orderFrontRegardless()

            // Leave the middle clear for the notch, and for any island drawn over the bar.
            var gap: CGFloat = 0
            if frame.maxY >= screen.frame.maxY - 1, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                gap = screen.frame.width - left.width - right.width + 16
            }
            let barRect = Self.topDown(frame)
            for island in islands where island.intersects(barRect) && abs(island.midX - barRect.midX) < 40 {
                gap = max(gap, 2 * max(barRect.midX - island.minX, island.maxX - barRect.midX) + 16)
            }
            let key = sharedDesktops ? "Main" : (screen.displayUUID ?? "Main")
            layouts[String(id)] = BarLayout(width: frame.width, middleGap: gap, desktopsKey: key)
            reserved.append((frame.minY, screen))
        }
        for (id, entry) in panels where !kept.contains(id) {
            entry.panel.orderOut(nil)
            panels[id] = nil
        }
        if model.layouts != layouts { model.layouts = layouts }
        DockSpaceKeeper.shared.reserveTop(reserved)
    }

    private func makePanel(for id: CGDirectDisplayID) -> (panel: BarPanel, view: BarHostingView) {
        let panel = BarPanel()
        let view = BarHostingView(rootView: TopBarView(model: model, screenKey: String(id)))
        view.onTopEdge = { [weak self] in self?.menuBarRevealing() }
        panel.contentView = view
        panels[id] = (panel, view)
        return (panel, view)
    }

    /// Along the very top when the macOS menu bar hides itself, otherwise just under it.
    /// On a screen with a camera notch it's as tall as the notch, so everything lines up with it.
    private func barFrame(on screen: NSScreen, replacesMenuBar: Bool) -> NSRect {
        let top = replacesMenuBar ? screen.frame.maxY : min(screen.frame.maxY, screen.visibleFrame.maxY)
        var height = BarSettings.size.pillHeight + 10
        if replacesMenuBar { height = max(height, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: top - height, width: screen.frame.width, height: height)
    }

    /// Other apps' islands along the top of a screen, like Vorssaint's: small windows above the
    /// menu bar, in the system's window coordinates.
    private static func islands() -> [CGRect] {
        let me = getpid()
        let above = Int(CGWindowLevelForKey(.mainMenuWindow))
        let menus = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer > above, layer < menus,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 40, rect.width <= 900, rect.height >= 10, rect.height <= 80
            else { return nil }
            return rect
        }
    }

    private static func topDown(_ rect: NSRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: The macOS menu bar

    /// The pointer reached the top of the screen, so the macOS menu bar is about to slide down
    /// over the bar. Fade the bar out of its way, and back once the pointer leaves the menus.
    private func menuBarRevealing() {
        guard BarSettings.takesMenuBarsPlace, revealTimer == nil else { return }
        revealStarted = Date()
        setBarsVisible(false)
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMenuBarGone() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private func checkMenuBarGone() {
        let mouse = NSEvent.mouseLocation
        // Still up where the menu bar is.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           mouse.y > screen.frame.maxY - 60 { return }
        // The pointer may be down in an open menu, with the menu bar still showing. Stay out of
        // its way, but not for long, in case the menu bar can't be seen in the window list.
        if Date().timeIntervalSince(revealStarted) < 8, Self.menuBarShowing() { return }
        revealTimer?.invalidate()
        revealTimer = nil
        setBarsVisible(true)
    }

    /// Whether a macOS menu bar is down on any screen right now.
    private static func menuBarShowing() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        return windows.contains { info in
            guard info[kCGWindowLayer as String] as? Int == level,
                  info[kCGWindowOwnerName as String] as? String == "Window Server",
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return NSScreen.screens.contains { abs(topDown($0.frame).minY - rect.minY) < 1 && rect.width >= $0.frame.width - 1 }
        }
    }

    private func setBarsVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.2 : 0.1
            for (_, entry) in panels {
                entry.panel.animator().alphaValue = visible ? 1 : 0
            }
        }
        for (_, entry) in panels { entry.panel.ignoresMouseEvents = !visible }
    }

    // MARK: What it shows

    private func refreshDesktops() {
        guard running, BarSettings.items.contains(where: { $0.kind == .desktops && $0.isOn }) else { return }
        let desktops = DesktopReader.read()
        if desktops != model.desktops {
            let sharedBefore = model.desktops.keys.contains("Main")
            model.desktops = desktops
            if desktops.keys.contains("Main") != sharedBefore { layout() }
        }
    }

    private func refreshFrontApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Clear Dock comes forward for a moment when it starts or switches desktops; keep showing
        // the app you're using then. It only counts while its settings window is open.
        if app.processIdentifier == getpid(),
           !NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal }) { return }
        let name = app.localizedName ?? ""
        if model.appName != name { model.appName = name }
        model.appIcon = model.icon(for: app.processIdentifier)
    }

    /// Updates the clock, then waits for the start of the next minute.
    private func tick() {
        model.now = Date()
        clockTimer?.invalidate()
        let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    // MARK: Colours

    private func refreshWallpaperColors() {
        guard BarSettings.usesWallpaper else { return }
        WallpaperPalette.shared.refresh(for: NSScreen.screens.first)
    }

    private func applyLook() {
        let palette = WallpaperPalette.shared
        var look = BarLook()
        look.style = BarSettings.style
        // Darken the wallpaper's own colour so light text stands out against it, even on a bright wallpaper.
        let darken = max(0.35, 1 - 0.28 / max(palette.top.lightness, 0.01))
        look.fill = BarSettings.style == .color ? BarSettings.color
            : (palette.top.blended(withFraction: darken, of: .black) ?? palette.top)
        look.opacity = BarSettings.opacity
        let index = BarSettings.accentIndex
        look.accent = index >= 0 ? palette.accents[min(index, palette.accents.count - 1)] : BarSettings.accentColor
        look.size = BarSettings.size
        look.font = BarSettings.font
        look.cornerRadius = CGFloat(BarSettings.cornerRadius)
        look.showDate = BarSettings.showDate
        look.use24Hour = BarSettings.use24Hour
        look.desktopStyle = BarSettings.desktopStyle
        look.numberPerScreen = BarSettings.numberPerScreen
        if model.look != look { model.look = look }
    }

    // MARK: Naming desktops

    private func rename(_ desktop: Desktop) {
        let previous = NSWorkspace.shared.frontmostApplication
        let alert = NSAlert()
        alert.messageText = "Name Desktop \(desktop.number)"
        alert.informativeText = "The name shows in the top bar instead of the number."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = BarSettings.desktopNames[desktop.key] ?? ""
        field.placeholderString = "Desktop \(desktop.number)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        let saved = alert.runModal() == .alertFirstButtonReturn
        previous?.activate()
        guard saved else { return }
        var names = BarSettings.desktopNames
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        names[desktop.key] = name.isEmpty ? nil : name
        BarSettings.desktopNames = names
        NotificationCenter.default.post(name: BarSettings.didChange, object: nil)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The display's UUID, as Mission Control names displays.
    var displayUUID: String? {
        guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

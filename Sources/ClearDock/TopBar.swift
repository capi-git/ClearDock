import AppKit
import ScreenCaptureKit
import SwiftUI
import os

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
    var peekDesktops = true
    var albumColours = true
    var miniPlayer = true
    /// A colour the glass is tinted with, for a desktop's or an album's colour.
    var glassTint: NSColor?

    /// The look shifted towards a colour: the highlight becomes it, and the bar's own colour leans
    /// towards a dark shade of it (or of `base`, when given), so the text stays readable.
    func tinted(_ colour: NSColor, base: NSColor? = nil) -> BarLook {
        var look = self
        look.accent = colour
        let dark = (base ?? colour).blended(withFraction: base == nil ? 0.72 : 0.45, of: .black) ?? colour
        look.fill = fill.blended(withFraction: 0.6, of: dark) ?? fill
        look.glassTint = colour
        return look
    }

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

/// The top bar's look on each screen, as it is right now (with the desktop's colour), shared with the
/// dock so the two can match. Empty while the bar is off.
@MainActor
enum BarLookShare {
    private(set) static var looks: [CGDirectDisplayID: BarLook] = [:]
    static let didChange = Notification.Name("ClearDockBarLookChanged")

    static func publish(_ new: [CGDirectDisplayID: BarLook]) {
        guard new != looks else { return }
        looks = new
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The look of the bar on a screen, or else of any bar.
    static func look(for screen: NSScreen?) -> BarLook? {
        screen?.displayID.flatMap { looks[$0] } ?? looks.values.first
    }
}

/// Notes about the bar stepping aside and why, readable with:
/// log show --predicate 'subsystem == "local.cleardock" AND category == "bar"'
let barLog = Logger(subsystem: "local.cleardock", category: "bar")

/// Where the top bar sits on each screen (its bottom edge, in the usual bottom-up screen
/// coordinates) while it's on, even while it has stepped aside for a moment (a game or a full-screen
/// app in front, Mission Control): for lock-in, which keeps its windows below it, so they don't grow
/// into the bar's place and stay there when it comes back.
@MainActor
enum BarRoom {
    static var bottoms: [CGDirectDisplayID: CGFloat] = [:]
}

/// Where a screen's bar puts things: its width, and the room left in the middle for the camera
/// notch or another app's island (like Vorssaint's).
struct BarLayout: Equatable {
    var width: CGFloat = 0
    var middleGap: CGFloat = 0
    /// Which display's desktops this bar shows.
    var desktopsKey = "Main"
    /// Drawn as one solid strip, rather than pieces with the wallpaper between them: while macOS
    /// keeps its own menu bar up behind the bar (some apps, like Microsoft Teams, have it stay up
    /// while they're in front, even though it's set to hide), it would show between the pieces.
    var solidStrip = false
    /// Room kept at the right end for macOS's microphone, camera or screen recording dot, which it
    /// draws over everything in the top right corner while the menu bar is hidden.
    var rightInset: CGFloat = 0
}

/// Colours taken from an album cover.
struct ArtColours: Equatable {
    let base: NSColor
    let accent: NSColor
}

/// Everything the bar views draw from. Shared by the bars on every screen. Each piece of a bar
/// redraws only when something it shows changes, not whenever anything here does.
@MainActor
@Observable
final class TopBarModel {
    var items: [BarItem] = []
    var look = BarLook()
    var layouts: [String: BarLayout] = [:]
    var desktops: [String: [Desktop]] = [:]
    var desktopNames: [String: String] = [:]
    var appName = ""
    var appIcon: NSImage?
    var track: NowPlaying.Track?
    var volume: Float?
    var muted = false
    var battery: Int?
    var charging = false
    var pluggedIn = false
    var now = Date()
    var desktopColours: [String: DesktopColour] = [:]
    var artwork: NSImage?
    var artColours: ArtColours?
    /// Screens whose bar is a thin line while a game is in front.
    var thinScreens = Set<String>()
    /// Locked-in desktops, by the window server's id for them, and when each was locked in.
    var lockIns: [UInt64: Date] = [:]
    /// The desktop whose two windows are being chosen for lock-in mode.
    var lockInChoosing: UInt64?
    /// Lock-in mode is getting a desktop's windows ready.
    var lockInStarting = false
    /// Screens whose bar the pointer is on, so a piece's hover highlight goes once it leaves even if
    /// that piece missed hearing so.
    var pointerInBar = Set<String>()
    /// Screens whose bar is filled in behind its pieces while the pointer is at the top, so the
    /// macOS menu bar sliding down underneath doesn't show through.
    var backdropScreens = Set<String>()
    /// What's behind each screen's bar (its strip of wallpaper), used as that fill so the bar
    /// looks just as it always does.
    var backdrops: [String: CGImage] = [:]

    /// Things the views ask the controller to do.
    @ObservationIgnored var toggleMute: () -> Void = {}
    @ObservationIgnored var changeVolume: (Float) -> Void = { _ in }
    @ObservationIgnored var rename: (Desktop) -> Void = { _ in }
    @ObservationIgnored var forget: (Desktop) -> Void = { _ in }
    @ObservationIgnored var setColour: (Desktop, DesktopColour?) -> Void = { _, _ in }
    @ObservationIgnored var hide: (BarItemKind) -> Void = { _ in }
    @ObservationIgnored var playPause: () -> Void = {}
    @ObservationIgnored var nextSong: () -> Void = {}
    @ObservationIgnored var previousSong: () -> Void = {}
    @ObservationIgnored var seek: (Double) -> Void = { _ in }
    /// The pointer moved onto (or, with nil, off) a desktop or the song, for their pop-ups.
    @ObservationIgnored var hoverDesktop: (Desktop?) -> Void = { _ in }
    @ObservationIgnored var leaveDesktop: (Desktop) -> Void = { _ in }
    @ObservationIgnored var goToDesktop: (Desktop) -> Void = { _ in }
    @ObservationIgnored var hoverSong: (Bool) -> Void = { _ in }
    @ObservationIgnored var toggleLockIn: () -> Void = {}
    @ObservationIgnored var chooseLockIn: () -> Void = {}

    /// The song's look: tinted with the album cover's colours, when that's on.
    func songLook(_ base: BarLook) -> BarLook {
        guard base.albumColours, let art = artColours else { return base }
        return base.tinted(art.accent, base: art.base)
    }

    /// The look for one desktop on a screen's bar, showing or not: tinted with its colour, if it has one.
    func look(for desktopsKey: String, desktop space: UInt64) -> BarLook {
        guard let desktop = desktops[desktopsKey]?.first(where: { $0.id == space }),
              let colour = desktopColours[desktop.key] else { return look }
        return look.tinted(colour.color)
    }

    /// The look for one screen's bar: tinted with its current desktop's colour, if it has one.
    func look(for desktopsKey: String) -> BarLook {
        guard let current = desktops[desktopsKey]?.first(where: \.isCurrent),
              let colour = desktopColours[current.key] else { return look }
        return look.tinted(colour.color)
    }

    @ObservationIgnored private var icons: [pid_t: NSImage] = [:]

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

/// A see-through strip along the top of a screen: above the macOS menu bar, so it stays in front
/// when that slides down until you hold the pointer at the top, and below notch apps like
/// Vorssaint, so their islands draw over it. It isn't shown over full-screen apps.
@MainActor
final class BarPanel: OverlayPanel {
    override init() {
        super.init()
        level = .statusBar
        // On every desktop. It's also put in `BarSpace` so it stays still while you switch desktops.
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
    /// The pointer came onto the bar (true) or left it (false).
    var onPointer: (Bool) -> Void = { _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.mouseMoved) }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointer(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer(false)
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
    private var revealTimer: Timer?
    /// The screen whose bar has stepped aside for the macOS menu bar, while the pointer is up there.
    private var revealScreen: CGDirectDisplayID?
    private var revealStarted = Date.distantPast
    /// Watches the pointer while it's at the top of a screen, before the macOS menu bar shows.
    private var holdTimer: Timer?
    private var holdScreen: CGDirectDisplayID?
    private var heldSince: Date?
    private var leftTopSince: Date?
    private var backdropsTaken = Date.distantPast
    private var backdropTask: Task<Void, Never>?
    private var backdropsAtTop = false
    /// Screens where Mission Control or App Exposé is open; the bar is hidden there meanwhile.
    private var exposeScreens = Set<CGDirectDisplayID>()
    private var exposeTimer: DispatchSourceTimer?
    private var dockWatch: DockActivityWatch?
    /// Looks for Mission Control off the main thread, so the check never holds up drawing.
    private let exposeQueue = DispatchQueue(label: "ClearDock.MissionControlWatch", qos: .userInitiated)
    /// Screens showing a full-screen app; the bar steps aside there, as the menu bar does.
    private var fullScreenScreens = Set<CGDirectDisplayID>()
    /// Bars already put in `BarSpace`. A bar that's put away leaves it, and goes back in when shown.
    private var inBarSpace = Set<CGDirectDisplayID>()
    private let desktopQueue = DispatchQueue(label: "ClearDock.Desktops", qos: .userInitiated)
    /// Other apps' islands along the top of the screens, as last seen: looked for off the main
    /// thread, as listing the windows on screen can be slow while macOS is busy.
    private var islands: [CGRect] = []
    private var readingDesktops = false
    private var desktopsAgain = false
    private var pendingCoverChecks: [DispatchWorkItem] = []
    private var pendingLayout: DispatchWorkItem?
    /// Screens where a game or another full-screen window is in front; the bar steps aside there.
    private var coveredScreens = Set<CGDirectDisplayID>()
    /// Screens where macOS keeps its menu bar up behind the bar without the pointer being there
    /// (an app in front has it stay up).
    private var menuBarHeldUp = Set<CGDirectDisplayID>()
    /// How much of each screen's top right corner macOS's privacy dot takes up, while it shows.
    private var indicatorRoom: [CGDirectDisplayID: CGFloat] = [:]
    /// Bars sliding away from a game right now.
    private var leaving = Set<CGDirectDisplayID>()
    private let popover = BarPopover()
    private let lockIn = LockIn()
    private let lockInPicker = LockInPicker()
    private let lockInNote = BarNote()

    init() {
        nowPlaying.onChange = { [weak self] in
            guard let self else { return }
            let songChanged = !(self.nowPlaying.track?.isSameSong(as: self.model.track) ?? (self.model.track == nil))
            if self.model.track != self.nowPlaying.track { self.model.track = self.nowPlaying.track }
            if self.model.artwork !== self.nowPlaying.artwork {
                self.model.artwork = self.nowPlaying.artwork
                self.model.artColours = self.nowPlaying.artwork.flatMap(Self.colours(of:))
            }
            if self.model.track == nil, self.popover.showing == "song" { self.popover.hide() }
            // A notch app's island often grows while music plays; make room once it has.
            if songChanged { self.scheduleLayout(after: 1) }
        }
        volume.onChange = { [weak self] in
            guard let self else { return }
            if self.model.volume != self.volume.level { self.model.volume = self.volume.level }
            if self.model.muted != self.volume.muted { self.model.muted = self.volume.muted }
        }
        battery.onChange = { [weak self] in
            guard let self else { return }
            if self.model.battery != self.battery.percent { self.model.battery = self.battery.percent }
            if self.model.charging != self.battery.charging { self.model.charging = self.battery.charging }
            if self.model.pluggedIn != self.battery.pluggedIn { self.model.pluggedIn = self.battery.pluggedIn }
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
        model.setColour = { desktop, colour in
            var colours = BarSettings.desktopColours
            colours[desktop.key] = colour
            BarSettings.desktopColours = colours
            NotificationCenter.default.post(name: BarSettings.didChange, object: nil)
        }
        model.playPause = { [weak self] in self?.nowPlaying.playPause() }
        model.nextSong = { [weak self] in self?.nowPlaying.next() }
        model.previousSong = { [weak self] in self?.nowPlaying.previous() }
        model.seek = { [weak self] seconds in self?.nowPlaying.seek(to: seconds) }
        model.hoverDesktop = { [weak self] desktop in self?.hoverDesktop(desktop) }
        model.leaveDesktop = { [weak self] desktop in self?.hoverDesktop(nil, leaving: desktop) }
        model.goToDesktop = { [weak self] desktop in
            self?.popover.hide()
            DesktopSwitcher.go(to: desktop)
        }
        lockIn.onChange = { [weak self] in
            guard let self else { return }
            let lockIns = self.lockIn.lockedIn
            if self.model.lockIns != lockIns { self.model.lockIns = lockIns }
            if self.model.lockInChoosing != self.lockIn.choosing { self.model.lockInChoosing = self.lockIn.choosing }
            if self.model.lockInStarting != self.lockIn.starting { self.model.lockInStarting = self.lockIn.starting }
        }
        lockIn.accent = { [weak self] screen, space in
            guard let self else { return .systemPurple }
            let key = self.model.desktops.keys.contains("Main") ? "Main" : (screen.displayUUID ?? "Main")
            // By the locked-in desktop itself: which desktop is showing may not be read yet just
            // after a switch.
            return self.model.look(for: key, desktop: space).accent
        }
        lockIn.choose = { [weak self] choices, title, screen, done in
            guard let self else { return done(nil) }
            self.popover.hide()
            let bottom = screen.displayID.flatMap { self.panels[$0]?.panel.frame.minY } ?? screen.visibleFrame.maxY
            let key = self.model.desktops.keys.contains("Main") ? "Main" : (screen.displayUUID ?? "Main")
            self.lockInPicker.show(choices, title: title, look: self.model.look(for: key), below: bottom, on: screen, done: done)
        }
        lockIn.dismissChooser = { [weak self] in self?.lockInPicker.close() }
        lockIn.notice = { [weak self] screen, text, icon, keep in
            guard let self, let id = screen.displayID, let bar = self.panels[id]?.panel, bar.isVisible else { return }
            let key = self.model.desktops.keys.contains("Main") ? "Main" : (screen.displayUUID ?? "Main")
            self.lockInNote.show(text, icon: icon, look: self.model.look(for: key), below: bar.frame.minY, on: screen, keep: keep)
        }
        model.toggleLockIn = { [weak self] in self?.lockIn.toggle() }
        model.chooseLockIn = { [weak self] in self?.lockIn.toggle(choosing: true) }
        model.hoverSong = { [weak self] inside in self?.hoverSong(inside) }
        model.hide = { kind in
            BarSettings.items = BarSettings.items.map { $0.kind == kind ? BarItem(kind: $0.kind, side: $0.side, isOn: false) : $0 }
            NotificationCenter.default.post(name: BarSettings.didChange, object: nil)
        }

        NotificationCenter.default.addObserver(forName: BarSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        // For checking how the lock-in chooser looks (only with the debug.snapshots setting on).
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.cleardock.debug.picker"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPickerForChecking() }
        }
        // For checking lock-in itself: locks in the windows of the app named, takes a picture, unlocks.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.cleardock.debug.lockin"), object: nil, queue: .main) { [weak self] note in
            let pid = (note.object as? String).flatMap { pid_t($0) }
            MainActor.assumeIsolated { if let pid { self?.lockInForChecking(pid) } }
        }
        // For measuring what each heavy job costs: runs the one named, keeping nothing on disk.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.cleardock.debug.exercise"), object: nil, queue: .main) { [weak self] note in
            let what = note.object as? String
            MainActor.assumeIsolated { if let what { self?.exercise(what) } }
        }
        settingsChanged()
    }

    private func exercise(_ what: String) {
        guard UserDefaults.standard.bool(forKey: "debug.snapshots") else { return }
        switch what {
        case "backdrops": refreshBackdrops(after: 0)
        case "palette": WallpaperPalette.shared.refresh(for: NSScreen.screens.first)
        case "peek":
            guard let screen = NSScreen.main else { return }
            let scale = 380 / screen.frame.width * screen.backingScaleFactor
            let desktops = model.desktops.values.joined()
            Task { @MainActor in
                for desktop in desktops {
                    let shots = PeekShots(screen: screen, windows: desktop.windows)
                    await shots.loadWallpaper(of: screen, size: CGSize(width: 380, height: 160))
                    await shots.load(desktop.windows, scale: scale)
                }
                PeekShots.forgetSoon()
            }
        case "previews":
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
            Task { for pid in apps { _ = await WindowCapture.shots(of: pid, scale: 2) } }
        case "dock": SettingsWindowController.shared.onChange(.dock)
        case _ where what.hasPrefix("settings"):
            SettingsWindowController.shared.measureOffScreen(tab: SettingsTab(rawValue: what.replacingOccurrences(of: "settings:", with: "")))
        default: break
        }
    }

    private func lockInForChecking(_ pid: pid_t) {
        guard UserDefaults.standard.bool(forKey: "debug.snapshots"), lockIn.lockForChecking(pid: pid) else { return }
        // Locked in for `debug.lockinSeconds` (2.5 unless set), with a picture taken 2.5 seconds in
        // unless `debug.lockinNoPicture` is set.
        let seconds = max(2.5, UserDefaults.standard.double(forKey: "debug.lockinSeconds"))
        if !UserDefaults.standard.bool(forKey: "debug.lockinNoPicture") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                Task { @MainActor in await DebugSnapshot.captureScreen(name: "lockin") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.lockIn.unlockForChecking() }
        }
    }

    /// Opens the lock-in chooser for the desktop showing, saves a picture of it, and closes it again
    /// without locking anything in.
    private func showPickerForChecking() {
        guard UserDefaults.standard.bool(forKey: "debug.snapshots"), let screen = NSScreen.main,
              let found = lockIn.choicesForChecking(on: screen), !found.choices.isEmpty else { return }
        let bottom = screen.displayID.flatMap { panels[$0]?.panel.frame.minY } ?? screen.visibleFrame.maxY
        let key = model.desktops.keys.contains("Main") ? "Main" : (screen.displayUUID ?? "Main")
        lockInPicker.show(found.choices, title: found.title, look: model.look(for: key), below: bottom, on: screen) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let number = self.lockInPicker.windowNumber
                Task { @MainActor in
                    if !UserDefaults.standard.bool(forKey: "debug.lockinNoPicture") {
                        await DebugSnapshot.capture(window: number, name: "picker")
                    }
                    self.lockInPicker.close()
                }
            }
        }
    }

    /// Clear Dock is quitting: put back the windows lock-in mode tucked away. Says whether there
    /// were any, which take a moment to get back.
    func prepareForQuit() -> Bool {
        lockIn.endAll(quitting: true)
    }

    func settingsChanged() {
        applyMenuBarSetting()
        guard BarSettings.enabled else { return stop() }
        start()
        let items = BarSettings.items, names = BarSettings.desktopNames, colours = BarSettings.desktopColours
        if model.items != items { model.items = items }
        if model.desktopNames != names { model.desktopNames = names }
        if model.desktopColours != colours { model.desktopColours = colours }
        // Without its piece in the bar there'd be no way to unlock.
        if !BarSettings.items.contains(where: { $0.kind == .lockIn && $0.isOn }) { lockIn.endAll() }
        lockIn.settingsChanged()
        applyLook()
        refreshWallpaperColors(unlessRecent: true)
        layout()
    }

    /// Hides the macOS menu bar while the bar replaces it, and puts it back otherwise.
    private func applyMenuBarSetting() {
        let wanted = BarSettings.enabled && BarSettings.replaceMenuBar
        // Still putting it back from a moment ago: once that's done, this runs again.
        guard !SystemMenuBar.restoring else { return }
        if wanted {
            // Only once: other settings changes shouldn't ask System Events again.
            guard !SystemMenuBar.isHiddenByClearDock else { return }
            SystemMenuBar.hide { [weak self] hidden in
                if hidden { self?.menuBarChanged() }
            }
        } else {
            guard SystemMenuBar.isHiddenByClearDock else { return }
            SystemMenuBar.restore { [weak self] _ in
                self?.menuBarChanged()
                // Turned back on meanwhile: hide it again.
                self?.applyMenuBarSetting()
            }
        }
    }

    /// Moves the bar now, and again once the menu bar has finished sliding away or back, since
    /// windows and the notch area only settle then.
    private func menuBarChanged() {
        layout()
        refreshIslands()
        for delay in [0.4, 1.2, 3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.layout()
                    self?.refreshIslands()
                }
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
        if model.track != nowPlaying.track { model.track = nowPlaying.track }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) {
            if $0.popover.wanted?.hasPrefix("desktop-") == true { $0.popover.hide() }
            $0.refreshDesktops()
            $0.refreshWallpaperColors()
            $0.checkFullScreen()
            $0.scheduleLayout(after: 0.4)
            // Each desktop can have its own wallpaper: the strip is taken again when it's next needed.
            $0.backdropsTaken = .distantPast
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) {
            $0.refreshFrontApp()
            $0.refreshDesktops()
            $0.checkCovered()
            // Games often go full screen a moment after they come forward.
            $0.scheduleCoverCheck()
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observe(workspace, name) { $0.refreshDesktops(); $0.model.pruneIcons() }
        }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.tick(); $0.refreshDesktops(); $0.layout(); $0.refreshIslands() }
        // Nothing to keep up with while the displays sleep.
        observe(workspace, NSWorkspace.screensDidSleepNotification) {
            $0.exposeTimer?.cancel()
            $0.exposeTimer = nil
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.startWindowWatch() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) {
            BarSettings.forgetMenuBarHidden()
            $0.scheduleScreenLayout()
            // Other apps' islands move with the screens.
            $0.refreshIslands()
        }
        observe(.default, WallpaperPalette.didChange) { $0.applyLook(); $0.backdropsTaken = .distantPast }
        observe(.default, .NSSystemTimeZoneDidChange) { $0.tick() }
        // A right-click menu opening closes any pop-up, so the two don't overlap.
        observe(.default, NSMenu.didBeginTrackingNotification) { $0.popover.hide() }
        // Turning "Automatically hide and show the menu bar" on or off moves the bar.
        observe(DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceMenuBarHidingChangedNotification")) {
            BarSettings.forgetMenuBarHidden()
            $0.scheduleLayout(after: 0.5)
        }

        tick()
        refreshFrontApp()
        refreshDesktops()
        refreshIslands()
        checkCovered()
        checkFullScreen()
        startExposeWatch()
        refreshBackdrops(after: 1)
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
        pendingCoverChecks.forEach { $0.cancel() }
        pendingCoverChecks.removeAll()
        revealTimer?.invalidate()
        revealTimer = nil
        revealScreen = nil
        endHold()
        lockIn.endAll()
        lockInPicker.close()
        exposeTimer?.cancel()
        exposeTimer = nil
        dockWatch?.stop()
        dockWatch = nil
        exposeScreens.removeAll()
        fullScreenScreens.removeAll()
        inBarSpace.removeAll()
        backdropTask?.cancel()
        backdropTask = nil
        model.backdrops = [:]
        pendingLayout?.cancel()
        popover.hide()
        model.thinScreens = []
        leaving.removeAll()
        for (_, entry) in panels { entry.panel.orderOut(nil) }
        panels.removeAll()
        DockSpaceKeeper.shared.reserveTop([])
        BarRoom.bottoms = [:]
        islands = []
        BarLookShare.publish([:])
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

    private var pendingScreenLayout: DispatchWorkItem?

    /// Screen changes come in bursts: one layout once they've stopped, without putting off a
    /// layout already waiting for something else to settle.
    private func scheduleScreenLayout() {
        pendingScreenLayout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.layout() }
        }
        pendingScreenLayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func layout() {
        guard running else { return }
        let screens = BarSettings.allScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        let replacesMenuBar = BarSettings.takesMenuBarsPlace
        let sharedDesktops = model.desktops.keys.contains("Main")
        var layouts: [String: BarLayout] = [:]
        var reserved: [(bottom: CGFloat, screen: NSScreen)] = []
        var kept = Set<CGDirectDisplayID>()
        var room: [CGDirectDisplayID: CGFloat] = [:]
        var thin = Set<String>()
        let gameMode = BarSettings.gameMode

        for screen in screens {
            guard let id = screen.displayID else { continue }
            kept.insert(id)
            let frame = barFrame(on: screen, replacesMenuBar: replacesMenuBar)
            room[id] = frame.minY
            let isNew = panels[id] == nil
            let entry = panels[id] ?? makePanel(for: id)
            let panel = entry.panel
            let wasAway = isNew || !panel.isVisible || leaving.contains(id) || model.thinScreens.contains(String(id))

            // Out of the way of a game (or a full-screen app), keeping no room for the bar on that screen.
            let fullScreen = fullScreenScreens.contains(id)
            if fullScreen || (coveredScreens.contains(id) && gameMode != .stay) {
                if gameMode == .line && !fullScreen {
                    // A thin line in the highlight colour along the very top.
                    thin.insert(String(id))
                    leaving.remove(id)
                    let line = NSRect(x: frame.minX, y: frame.maxY - 3, width: frame.width, height: 3)
                    panel.ignoresMouseEvents = true
                    if !panel.isVisible {
                        panel.setFrame(line.offsetBy(dx: 0, dy: 3), display: false)
                        panel.orderFrontRegardless()
                        inBarSpace.remove(id)
                    }
                    if panel.frame != line { Self.animate(panel, to: line, alpha: 1) }
                } else if panel.isVisible, !leaving.contains(id) {
                    // Slide up off the top of the screen.
                    leaving.insert(id)
                    Self.animate(panel, to: frame.offsetBy(dx: 0, dy: frame.height), alpha: 0) { [weak self] in
                        guard let self, self.leaving.contains(id) else { return }
                        self.leaving.remove(id)
                        panel.orderOut(nil)
                        self.inBarSpace.remove(id)
                    }
                }
                continue
            }

            // Only the bar that's stepped aside (for the macOS menu bar, or for Mission Control) stays
            // out of the way; the others carry on as usual.
            let away = revealScreen == id || exposeScreens.contains(id)
            panel.ignoresMouseEvents = away
            if wasAway {
                // Slide back down from the top.
                leaving.remove(id)
                if !panel.isVisible || isNew {
                    panel.setFrame(frame.offsetBy(dx: 0, dy: frame.height), display: false)
                    panel.alphaValue = 0
                    panel.orderFrontRegardless()
                    inBarSpace.remove(id)
                }
                Self.animate(panel, to: frame, alpha: away ? 0 : 1)
            } else {
                if panel.frame != frame { panel.setFrame(frame, display: true) }
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                    inBarSpace.remove(id)
                }
            }

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
            layouts[String(id)] = BarLayout(width: frame.width, middleGap: gap, desktopsKey: key,
                                            solidStrip: replacesMenuBar && menuBarHeldUp.contains(id),
                                            rightInset: frame.maxY >= screen.frame.maxY - 1 ? indicatorRoom[id] ?? 0 : 0)
            reserved.append((frame.minY, screen))
        }
        for (id, entry) in panels where !kept.contains(id) {
            entry.panel.orderOut(nil)
            panels[id] = nil
        }
        // Into Clear Dock's own layer once shown, so the bars stay still while switching desktops.
        for (id, entry) in panels where !inBarSpace.contains(id) && entry.panel.windowNumber > 0 {
            BarSpace.add(entry.panel)
            inBarSpace.insert(id)
        }
        inBarSpace.formIntersection(kept)
        if model.layouts != layouts {
            // The bars moved or changed size, so the strips behind them need taking again when next needed.
            if model.layouts.mapValues(\.width) != layouts.mapValues(\.width) || replacesMenuBar != backdropsAtTop {
                backdropsTaken = .distantPast
            }
            model.layouts = layouts
        }
        backdropsAtTop = replacesMenuBar
        if model.thinScreens != thin { model.thinScreens = thin }
        BarRoom.bottoms = room
        DockSpaceKeeper.shared.reserveTop(reserved)
    }

    /// Watches for Mission Control or App Exposé opening. macOS doesn't announce either, but the
    /// Dock (which draws them) reports a change as they open and close: that's when it looks, at
    /// once and as the animation settles.
    private func startExposeWatch() {
        dockWatch?.stop()
        dockWatch = DockActivityWatch { [weak self] in self?.lookForMissionControl() }
        startWindowWatch()
    }

    /// One look every few seconds is the safety net for what nothing announces: Mission Control
    /// opening without the Dock saying so, and windows opening, closing or moving to another
    /// desktop. The looking is done on its own queue, and only when the windows have changed does
    /// it look closer. It stops while the displays are asleep.
    private func startWindowWatch() {
        exposeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: exposeQueue)
        timer.schedule(deadline: .now(), repeating: 3, leeway: .seconds(1))
        var seen: [UInt] = []
        var seenSet = Set<UInt>()
        var seenEverywhere: [UInt] = []
        timer.setEventHandler { [weak self] in
            let everywhere = OnScreenWindows.numbers(everywhere: true).sorted()
            if everywhere != seenEverywhere {
                seenEverywhere = everywhere
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.running else { return }
                        self.refreshDesktops()
                        self.checkCovered()
                    }
                }
            }
            let numbers = OnScreenWindows.numbers()
            guard numbers != seen || numbers.isEmpty else { return }
            seen = numbers
            // A window appeared or went (not just a change of order): macOS's own menu bar or its
            // privacy dot may have come or gone too, which nothing announces.
            let set = Set(numbers)
            let appeared = set != seenSet
            seenSet = set
            let backdrops = MissionControl.backdrops()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.checkExpose(backdrops)
                    if appeared {
                        self?.checkCoveredSoon()
                        self?.refreshIslands()
                    }
                }
            }
        }
        timer.resume()
        exposeTimer = timer
    }

    /// The Dock changed what it shows: look for Mission Control now, and again as it finishes
    /// opening or closing.
    private func lookForMissionControl() {
        for delay in [0.0, 0.25, 0.6] {
            exposeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                let backdrops = MissionControl.backdrops()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.checkExpose(backdrops) }
                }
            }
        }
    }

    private func checkExpose(_ backdrops: [CGRect]) {
        guard running else { return }
        var open = Set<CGDirectDisplayID>()
        for rect in backdrops {
            for screen in NSScreen.screens where Self.topDown(screen.frame).insetBy(dx: 2, dy: 2).intersects(rect) && rect.width >= screen.frame.width - 2 {
                if let id = screen.displayID { open.insert(id) }
            }
        }
        guard open != exposeScreens else { return }
        let opened = open.subtracting(exposeScreens), closed = exposeScreens.subtracting(open)
        exposeScreens = open
        barLog.notice("Bar: Mission Control \(open.isEmpty ? "closed" : "open", privacy: .public)")
        lockIn.missionControl(open: !open.isEmpty)
        if !opened.isEmpty { popover.hide() }
        for id in opened { exposeChanged(on: id, open: true) }
        for id in closed { exposeChanged(on: id, open: false) }
    }

    /// Mission Control or App Exposé opened or closed on a screen: hide that screen's bar while it's
    /// open (its strip of desktops and buttons go where the bar is), and bring it back afterwards.
    private func exposeChanged(on id: CGDirectDisplayID, open: Bool) {
        guard running, let panel = panels[id]?.panel else { return }
        if open {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            clearPointer(on: [id])
        } else if !coveredScreens.contains(id), !fullScreenScreens.contains(id), revealScreen != id {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
            panel.ignoresMouseEvents = false
        }
    }

    /// Notices a display switching to or from a full-screen app.
    private func checkFullScreen() {
        let displays = DesktopReader.fullScreenDisplays()
        var screens = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            if displays.contains("Main") || displays.contains(screen.displayUUID ?? "") { screens.insert(id) }
        }
        guard screens != fullScreenScreens else { return }
        barLog.notice("Bar: full-screen app on \(screens.count) screens (was \(self.fullScreenScreens.count))")
        fullScreenScreens = screens
        layout()
    }

    private static func animate(_ panel: NSPanel, to frame: NSRect, alpha: CGFloat, then done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { done?() }
        })
    }

    private func makePanel(for id: CGDirectDisplayID) -> (panel: BarPanel, view: BarHostingView) {
        let panel = BarPanel()
        let view = BarHostingView(rootView: TopBarView(model: model, screenKey: String(id)))
        // The bar's frame is set here; its view needn't work out sizes for the window on each change.
        view.sizingOptions = []
        view.onTopEdge = { [weak self] in self?.pointerAtTop(of: id) }
        view.onPointer = { [weak self] inside in
            guard let self else { return }
            if inside {
                if !self.model.pointerInBar.contains(String(id)) { self.model.pointerInBar.insert(String(id)) }
            } else {
                if self.model.pointerInBar.contains(String(id)) { self.model.pointerInBar.remove(String(id)) }
                // Off the bar and not onto its pop-up: the pop-up can go.
                self.popover.release()
            }
        }
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
    nonisolated private static func findIslands() -> [CGRect] {
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

    /// Looks for islands again, and makes room for them if they've changed.
    private func refreshIslands() {
        desktopQueue.async { [weak self] in
            let found = Self.findIslands()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running, found != self.islands else { return }
                    self.islands = found
                    self.layout()
                }
            }
        }
    }

    private static func topDown(_ rect: NSRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: The macOS menu bar

    /// The pointer reached the very top of a screen. macOS starts sliding its menu bar down there,
    /// underneath the bar. The bar fills in so the menu bar doesn't show through, and only steps
    /// aside once the pointer has been held at the top for a moment.
    private func pointerAtTop(of id: CGDirectDisplayID) {
        // Already watching the pointer up here: it carries on following it.
        guard holdScreen != id || holdTimer == nil else { return }
        guard BarSettings.takesMenuBarsPlace, revealTimer == nil, !coveredScreens.contains(id) else { return }
        // Fairly fresh: a live wallpaper (like Wallspace's) moves, and an old picture of it would
        // show as a seam along the bar.
        if Date().timeIntervalSince(backdropsTaken) > 20, backdropTask == nil { refreshBackdrops(after: 0) }
        if holdScreen != id { heldSince = Date() }
        holdScreen = id
        leftTopSince = nil
        if model.backdropScreens != [String(id)] { model.backdropScreens = [String(id)] }
        guard holdTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHold() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func checkHold() {
        guard let id = holdScreen, let screen = NSScreen.screens.first(where: { $0.displayID == id }),
              let bar = panels[id]?.panel else { return endHold() }
        let mouse = NSEvent.mouseLocation
        let onScreen = NSMouseInRect(mouse, screen.frame, false)
        if onScreen && mouse.y >= screen.frame.maxY - 3 {
            // Still at the very top: show the macOS menu bar once it's been held there long enough.
            leftTopSince = nil
            if heldSince == nil { heldSince = Date() }
            if let since = heldSince, Date().timeIntervalSince(since) >= BarSettings.menuBarDelay {
                endHold(keepBackdrop: true)
                menuBarRevealing(on: id)
            }
            return
        }
        // Moved down off the edge: start counting again next time it touches the top.
        heldSince = nil
        // Keep the fill while the pointer is on the bar (the menu bar may still be down underneath),
        // and a moment after it leaves, while the menu bar slides away.
        if onScreen && mouse.y >= bar.frame.minY - 4 { leftTopSince = nil; return }
        if leftTopSince == nil { leftTopSince = Date() }
        if let since = leftTopSince, Date().timeIntervalSince(since) > 0.35 { endHold() }
    }

    private func endHold(keepBackdrop: Bool = false) {
        holdTimer?.invalidate()
        holdTimer = nil
        holdScreen = nil
        heldSince = nil
        leftTopSince = nil
        if !keepBackdrop, !model.backdropScreens.isEmpty { model.backdropScreens = [] }
    }

    /// Takes a picture of the wallpaper behind each bar (leaving out every window, the macOS menu
    /// bar and the bar itself), for filling the bar in while the pointer is at the top. Taken once
    /// at the start and then only when the pointer gets there and it's out of date, rather than at
    /// every change of desktop. Needs Screen Recording permission; without it the bar isn't filled in.
    private func refreshBackdrops(after delay: TimeInterval) {
        guard running, BarSettings.takesMenuBarsPlace, CGPreflightScreenCaptureAccess() else { return }
        backdropTask?.cancel()
        let bars = panels.compactMap { id, entry -> (key: String, id: CGDirectDisplayID, frame: NSRect, scale: CGFloat)? in
            guard !coveredScreens.contains(id), let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return nil }
            // The bar's place on its screen, measured from the screen's top-left corner.
            let frame = barFrame(on: screen, replacesMenuBar: true)
            let local = NSRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            return (String(id), id, local, screen.backingScaleFactor)
        }
        backdropTask = Task { @MainActor [weak self] in
            defer { if !Task.isCancelled { self?.backdropTask = nil } }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            var images: [String: CGImage] = [:]
            for bar in bars {
                guard !Task.isCancelled else { return }
                guard let display = content.displays.first(where: { $0.displayID == bar.id }) else { continue }
                let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.windowLayer >= 0 })
                let config = SCStreamConfiguration()
                config.sourceRect = bar.frame
                config.width = Int(bar.frame.width * bar.scale)
                config.height = Int(bar.frame.height * bar.scale)
                config.showsCursor = false
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    images[bar.key] = image
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.model.backdrops = images
            self.backdropsTaken = Date()
        }
    }

    /// The pointer was held at the top, so step out of the way of the macOS menu bar, and come back
    /// once the pointer leaves the menus.
    private func menuBarRevealing(on id: CGDirectDisplayID) {
        guard revealTimer == nil else { return }
        revealStarted = Date()
        revealScreen = id
        setBarsVisible(false, only: id)
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMenuBarGone() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    /// Whether a look at the windows on screen is under way for `checkMenuBarGone`.
    private var lookingForMenus = false

    private func checkMenuBarGone() {
        guard !pointerAtTop() else { return }
        // Stay out of the way for as long as the macOS menu bar is down or one of its menus is open,
        // however long you take. (Five minutes at most, in case macOS ever stops showing either.)
        guard Date().timeIntervalSince(revealStarted) < 300 else { return menuBarGone() }
        // The windows are looked at off the main thread, as that's done several times a second.
        guard !lookingForMenus else { return }
        lookingForMenus = true
        let heldUp = revealScreen.map(menuBarHeldUp.contains) == true
        let screens = NSScreen.screens.map { Self.topDown($0.frame) }
        let started = revealStarted
        desktopQueue.async { [weak self] in
            let showing = Self.menuBarOrMenuShowing(countingMenuBar: !heldUp, screens: screens)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lookingForMenus = false
                    // Back up at the top meanwhile, or already gone (and maybe shown again since).
                    guard !showing, self.revealTimer != nil, self.revealStarted == started, !self.pointerAtTop() else { return }
                    self.menuBarGone()
                }
            }
        }
    }

    /// Still up where the menu bar is.
    private func pointerAtTop() -> Bool {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return false }
        return mouse.y > screen.frame.maxY - 60
    }

    private func menuBarGone() {
        revealTimer?.invalidate()
        revealTimer = nil
        revealScreen = nil
        if !model.backdropScreens.isEmpty { model.backdropScreens = [] }
        setBarsVisible(true)
    }

    /// Whether a macOS menu bar is down on any of `screens` (unless `countingMenuBar` is off: an app
    /// holds it up, and it won't go), or a menu (from the menu bar or a right-click) is open in any
    /// app, from one look at the windows on screen.
    nonisolated private static func menuBarOrMenuShowing(countingMenuBar: Bool, screens: [CGRect]) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let menuBar = Int(CGWindowLevelForKey(.mainMenuWindow))
        let menu = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windows.contains { info in
            let layer = info[kCGWindowLayer as String] as? Int
            if layer == menu { return (info[kCGWindowAlpha as String] as? Double ?? 0) > 0.5 }
            guard countingMenuBar, layer == menuBar, info[kCGWindowOwnerName as String] as? String == "Window Server",
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return screens.contains { abs($0.minY - rect.minY) < 1 && rect.width >= $0.width - 1 }
        }
    }

    private func setBarsVisible(_ visible: Bool, only id: CGDirectDisplayID? = nil) {
        // Bars stepping aside for a game are left as they are, and none comes back over Mission
        // Control or a full-screen app.
        let bars = panels.filter { key, _ in
            !coveredScreens.contains(key) && (id == nil || key == id)
                && !(visible && (exposeScreens.contains(key) || fullScreenScreens.contains(key)))
        }
        let panelsShown = bars.map(\.value.panel)
        if !visible {
            popover.hide()
            clearPointer(on: bars.map(\.key))
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.2 : 0.1
            for panel in panelsShown { panel.animator().alphaValue = visible ? 1 : 0 }
        }
        for panel in panelsShown { panel.ignoresMouseEvents = !visible }
    }

    private func clearPointer(on ids: [CGDirectDisplayID]) {
        let keys = Set(ids.map(String.init))
        if !model.pointerInBar.isDisjoint(with: keys) { model.pointerInBar.subtract(keys) }
    }

    // MARK: What it shows

    /// Reads the desktops on their own queue, since that asks the window server about every
    /// window; a request while one is being read is answered by one more read once it's done.
    private func refreshDesktops() {
        // Even without the desktops in the bar: their colours, and lock-in mode, follow the desktop you're on.
        guard running else { return }
        guard !readingDesktops else { return desktopsAgain = true }
        readingDesktops = true
        desktopQueue.async { [weak self] in
            let desktops = DesktopReader.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.readingDesktops = false
                    if self.desktopsAgain {
                        self.desktopsAgain = false
                        self.refreshDesktops()
                    }
                    self.show(desktops)
                }
            }
        }
    }

    private func show(_ desktops: [String: [Desktop]]) {
        guard running else { return }
        if desktops != model.desktops {
            let sharedBefore = model.desktops.keys.contains("Main")
            model.desktops = desktops
            // The desktop showing may have its own colour.
            shareLook()
            if desktops.keys.contains("Main") != sharedBefore { layout() }
        }
    }

    /// Notices when the app in front fills a screen with a game or another full-screen window,
    /// so the bar steps aside there, and comes back once it doesn't.
    private func checkCovered() {
        // Clear Dock itself coming forward for a moment (an alert, its settings) changes nothing:
        // the bar shouldn't drop back over a game for it.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { return }
        // Nor does macOS itself coming forward (the lock screen, a password prompt, the screen saver):
        // the bar would slide away when the Mac locks and back again when you unlock it.
        if let front = NSWorkspace.shared.frontmostApplication, front.activationPolicy != .regular { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screens = NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, Self.topDown(screen.frame)) } }
        // How far down each screen the bar reaches.
        let replacesMenuBar = BarSettings.takesMenuBarsPlace
        let barBottoms = Dictionary(NSScreen.screens.compactMap { screen in
            screen.displayID.map { ($0, screen.frame.maxY - barFrame(on: screen, replacesMenuBar: replacesMenuBar).minY) }
        }, uniquingKeysWith: { first, _ in first })
        // The windows on screen are looked at off the main thread: macOS can be slow to list them
        // while it's busy (opening Mission Control, say), and nothing should wait on that.
        desktopQueue.async { [weak self] in
            var covered = Set<CGDirectDisplayID>()
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            // macOS's privacy dot (microphone, camera, screen recording) in a screen's top right corner.
            var indicators: [CGDirectDisplayID: CGFloat] = [:]
            for info in windows where info[kCGWindowOwnerName as String] as? String == "Window Server"
                && info[kCGWindowName as String] as? String == "StatusIndicator" {
                guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds), rect.width < 80 else { continue }
                for (id, area) in screens where area.intersects(rect) && rect.minY < area.minY + 12 && rect.midX > area.midX {
                    indicators[id] = max(indicators[id] ?? 0, (area.maxX - rect.minX + 2).rounded())
                }
            }
            // macOS's own menu bar, up along the top of a screen.
            var held = Set<CGDirectDisplayID>()
            let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
            for info in windows where info[kCGWindowLayer as String] as? Int == menuLevel
                && info[kCGWindowOwnerName as String] as? String == "Window Server" {
                guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
                for (id, area) in screens where abs(area.minY - rect.minY) < 1 && rect.width >= area.width - 1 { held.insert(id) }
            }
            if let pid {
                let game = Games.isGame(pid)
                for info in windows where info[kCGWindowOwnerPID as String] as? pid_t == pid {
                    guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                          let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
                    let layer = info[kCGWindowLayer as String] as? Int ?? 0
                    for (id, area) in screens {
                        let overlap = rect.intersection(area)
                        guard !overlap.isNull else { continue }
                        let share = overlap.width * overlap.height / (area.width * area.height)
                        // A game covering most of a screen, or a special window covering all of it.
                        // An ordinary window made as big as the screen still gets room made for the bar.
                        // So does a game's window that starts below the bar (Riot Client's fills most of
                        // a laptop's screen): stepping aside for it would only leave an empty strip.
                        let reachesBar = rect.minY < area.minY + (barBottoms[id] ?? 0) - 1
                        if (game && share > 0.8 && reachesBar) || (layer > 0 && share > 0.97) { covered.insert(id) }
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    // Up because you're reaching for it (the pointer at the top) doesn't count.
                    let reaching = self.holdTimer != nil || self.revealTimer != nil
                    let heldChanged = !reaching && held != self.menuBarHeldUp
                    if heldChanged { self.menuBarHeldUp = held }
                    let indicatorsChanged = indicators != self.indicatorRoom
                    if indicatorsChanged { self.indicatorRoom = indicators }
                    guard covered != self.coveredScreens || heldChanged || indicatorsChanged else { return }
                    if covered != self.coveredScreens {
                        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                        barLog.notice("Bar: covered screens \(covered.count) (was \(self.coveredScreens.count)), with \(front, privacy: .public) in front")
                    }
                    if heldChanged { barLog.notice("Bar: macOS menu bar held up on \(held.count) screens") }
                    self.coveredScreens = covered
                    self.layout()
                }
            }
        }
    }

    private var pendingCoverLook: DispatchWorkItem?

    /// A look a moment from now, after a run of windows coming and going has settled.
    private func checkCoveredSoon() {
        pendingCoverLook?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkCovered() }
        }
        pendingCoverLook = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func scheduleCoverCheck() {
        pendingCoverChecks.forEach { $0.cancel() }
        pendingCoverChecks = [1.0, 3.0].map { delay in
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.checkCovered() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func refreshFrontApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Clear Dock comes forward for a moment when it starts or switches desktops; keep showing
        // the app you're using then. It only counts while its settings window is open.
        if app.processIdentifier == getpid() {
            guard NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal }) else { return }
        } else if app.activationPolicy != .regular {
            // macOS's own helpers come forward for a moment too (a password or Touch ID prompt is
            // "SecurityAgentHelper"): keep showing the app you're using.
            return
        }
        let name = app.localizedName ?? ""
        if model.appName != name { model.appName = name }
        let icon = model.icon(for: app.processIdentifier)
        if model.appIcon !== icon { model.appIcon = icon }
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

    private func refreshWallpaperColors(unlessRecent: Bool = false) {
        guard BarSettings.usesWallpaper else { return }
        WallpaperPalette.shared.refresh(for: NSScreen.screens.first, unlessRecent: unlessRecent)
    }

    private func applyLook() {
        let palette = WallpaperPalette.shared
        var look = BarLook()
        look.style = BarSettings.style
        // Darken the wallpaper's own colour so light text stands out against it, even on a bright wallpaper.
        let darken = max(0.35, 1 - 0.28 / max(palette.top.lightness, 0.01))
        look.fill = BarSettings.style == .color ? BarSettings.color
            : (palette.top.blended(withFraction: darken, of: .black) ?? palette.top)
        // Solid colours: see-through pieces would have to blur whatever's behind them again at every
        // frame of a moving wallpaper.
        look.opacity = 1
        let index = BarSettings.accentIndex
        look.accent = index >= 0 ? palette.accents[min(index, palette.accents.count - 1)] : BarSettings.accentColor
        look.size = BarSettings.size
        look.font = BarSettings.font
        look.cornerRadius = CGFloat(BarSettings.cornerRadius)
        look.showDate = BarSettings.showDate
        look.use24Hour = BarSettings.use24Hour
        look.desktopStyle = BarSettings.desktopStyle
        look.peekDesktops = BarSettings.peekDesktops
        look.albumColours = BarSettings.albumColours
        look.miniPlayer = BarSettings.miniPlayer
        if model.look != look { model.look = look }
        shareLook()
    }

    /// Tells the dock how each screen's bar looks now, so it can match.
    private func shareLook() {
        let shared = model.desktops.keys.contains("Main")
        var looks: [CGDirectDisplayID: BarLook] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            looks[id] = model.look(for: shared ? "Main" : (screen.displayUUID ?? "Main"))
        }
        BarLookShare.publish(looks)
    }

    /// A calm colour and the strongest colour of an album cover.
    private static func colours(of image: NSImage) -> ArtColours? {
        var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let colours = WallpaperPalette.colors(in: cg) else { return nil }
        let base = colours.base.blended(withFraction: 0.5, of: colours.top) ?? colours.base
        return ArtColours(base: base, accent: colours.accents.first ?? base)
    }

    // MARK: Pop-ups

    /// The screen under the pointer, and the bottom edge of its bar, for placing a pop-up. Nil while
    /// that bar is out of the way (for the macOS menu bar, Mission Control or a game), so moving
    /// across where it was doesn't open anything.
    private func barUnderPointer() -> (screen: NSScreen, bottom: CGFloat)? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let id = screen.displayID, revealScreen != id, let panel = panels[id]?.panel, panel.isVisible, panel.alphaValue > 0.5,
              !exposeScreens.contains(id), !coveredScreens.contains(id) else { return nil }
        return (screen, panel.frame.minY)
    }

    private func hoverDesktop(_ desktop: Desktop?, leaving left: Desktop? = nil) {
        guard let desktop, model.look.peekDesktops, !desktop.isCurrent, let bar = barUnderPointer() else {
            // The pointer may already be on the next desktop, whose pop-up is on its way.
            if let left, popover.wanted != nil, popover.wanted != "desktop-\(left.id)" { return }
            return popover.release()
        }
        let look = model.look
        popover.request("desktop-\(desktop.id)", below: bar.bottom, on: bar.screen) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(DesktopPeekView(model: self.model, desktop: desktop, screen: bar.screen, look: look) { [weak self] in
                self?.popover.hide()
            })
        }
    }

    private func hoverSong(_ inside: Bool) {
        guard inside, model.look.miniPlayer, model.track != nil, let bar = barUnderPointer() else {
            return popover.release()
        }
        popover.request("song", below: bar.bottom, on: bar.screen) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            self.nowPlaying.refreshPosition()
            return AnyView(MiniPlayerView(model: self.model))
        }
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

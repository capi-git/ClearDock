import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens and closes the settings window. While it's open Clear Dock behaves like a normal app
/// (it appears in ⌘-Tab), and the dock stays on screen so changes show up as you make them.
/// The window is let go of when closed, so it uses no memory the rest of the time.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Called when settings change, with which part of Clear Dock they're for, so only that part redraws.
    var onChange: (SettingsArea) -> Void = { _ in }
    /// Called with true when the window opens and false when it closes.
    var onOpenChanged: (Bool) -> Void = { _ in }

    private var window: NSWindow?
    private var store: SettingsStore?

    /// For measuring what the settings window costs: makes it away from every screen, without
    /// bringing Clear Dock forward, and closes it a few seconds later.
    func measureOffScreen(tab: SettingsTab? = nil) {
        let store = SettingsStore(onChange: { _ in })
        if let tab { store.tab = tab }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 620, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            window.orderOut(nil)
            window.contentViewController = nil
            _ = store
        }
    }

    func show(tab: SettingsTab? = nil) {
        if window == nil {
            let store = SettingsStore(onChange: { [weak self] area in self?.onChange(area) })
            self.store = store
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Clear Dock"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
            window.center()
            window.delegate = self
            self.window = window
            onOpenChanged(true)
        }
        if let tab { store?.tab = tab }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        // In front even if macOS doesn't make Clear Dock the active app straight away.
        window?.orderFrontRegardless()
        NSApp.activate()
        // Becoming a normal app (with a Dock icon and a menu bar) takes effect a moment later, and
        // macOS may only let it come forward then: ask again once it has.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let window = self?.window else { return }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // A change made just before closing still reaches the dock or the bar.
        store?.applyPending()
        window?.delegate = nil
        window = nil
        store = nil
        NSApp.setActivationPolicy(.accessory)
        onOpenChanged(false)
    }
}

/// Which part of Clear Dock a setting is for.
enum SettingsArea: Hashable {
    case dock, bar
}

enum SettingsTab: String, Hashable {
    case dock = "behaviour", look, topBar, desktops, general = "permissions"
}

/// The settings, as the window shows and edits them.
@MainActor
final class SettingsStore: ObservableObject {
    private let changed: (SettingsArea) -> Void
    private var pending: DispatchWorkItem?
    private var pendingAreas = Set<SettingsArea>()
    /// Set while values are being loaded, so loading doesn't count as an edit.
    private var loading = true

    init(onChange: @escaping (SettingsArea) -> Void) {
        changed = onChange
        reload()
    }

    /// The window opens on the tab you last used.
    @Published var tab = UserDefaults.standard.string(forKey: "settingsTab").flatMap(SettingsTab.init(rawValue:)) ?? .dock {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
    }

    // Dock look
    @Published var theme: String?
    @Published var themes: [DockTheme] = []
    @Published var matchesBar = false { didSet { edit { Appearance.matchesBar = matchesBar } } }
    @Published var background = DockBackground.none { didSet { edit { Appearance.background = background } } }
    @Published var backgroundColor = Color.black { didSet { edit { Appearance.backgroundColor = NSColor(backgroundColor) } } }
    @Published var backgroundOpacity = 0.5 { didSet { edit { Appearance.backgroundOpacity = backgroundOpacity } } }
    @Published var cornerRadius = 18.0 { didSet { edit { Appearance.cornerRadius = cornerRadius } } }
    @Published var finish = BarFinish.flat { didSet { edit { Appearance.finish = finish } } }
    /// The outline round the dock's background: none, a soft automatic one, or a colour of your choosing.
    @Published var outline = OutlineChoice.automatic {
        didSet {
            edit {
                Appearance.outline = outline != .none
                Appearance.outlineColor = outline == .colour ? NSColor(outlineColor) : nil
            }
        }
    }
    @Published var outlineColor = Color.white {
        didSet { edit { if outline == .colour { Appearance.outlineColor = NSColor(outlineColor) } } }
    }
    @Published var iconStyle = IconStyle.original { didSet { edit { Appearance.iconStyle = iconStyle } } }
    @Published var iconShape = IconShape.original { didSet { edit { Appearance.iconShape = iconShape } } }
    @Published var markerStyle = MarkerStyle.dot { didSet { edit { Appearance.markerStyle = markerStyle } } }
    @Published var markerColor = MarkerColor.white { didSet { edit { Appearance.markerColor = markerColor } } }
    @Published var markerCustomColor = Color.white { didSet { edit { Appearance.markerCustomColor = NSColor(markerCustomColor) } } }
    @Published var shadows = true { didSet { edit { Appearance.shadows = shadows } } }
    @Published var hoverEffect = HoverEffect.none { didSet { edit { Appearance.hoverEffect = hoverEffect } } }
    @Published var magnifyScale = 1.6 { didSet { edit { Appearance.magnifyScale = magnifyScale } } }
    @Published var useGradient = false {
        didSet { edit { Appearance.gradientColor = useGradient ? NSColor(gradientColor) : nil } }
    }
    @Published var gradientColor = Color.cyan {
        didSet { edit { if useGradient { Appearance.gradientColor = NSColor(gradientColor) } } }
    }
    @Published var position = DockEdge.bottom { didSet { edit(keepsTheme: true) { Settings.position = position } } }
    @Published var edgeGap = 0.0 { didSet { edit(keepsTheme: true) { Appearance.edgeGap = edgeGap } } }
    @Published var spacing = 1.0 { didSet { edit(keepsTheme: true) { Appearance.spacing = spacing } } }
    @Published var iconSize = 40.0 { didSet { edit(keepsTheme: true) { Settings.iconSize = iconSize } } }

    // Dock
    @Published var autoHide = true { didSet { edit(keepsTheme: true) { Settings.autoHide = autoHide } } }
    @Published var showPinned = false { didSet { edit(keepsTheme: true) { Settings.showPinned = showPinned } } }
    @Published var hiddenApps: [String] = [] { didSet { edit(keepsTheme: true) { Settings.hiddenApps = hiddenApps } } }
    @Published var showTrash = true { didSet { edit(keepsTheme: true) { Settings.showTrash = showTrash } } }
    @Published var showBadges = true {
        didSet {
            edit(keepsTheme: true) { Settings.showBadges = showBadges }
            // Counts come from the macOS Dock, which only shares them with apps allowed under
            // Privacy & Security > Accessibility.
            if showBadges, !loading, !BadgeReader.hasPermission { BadgeReader.askForPermission() }
        }
    }
    @Published var showPreviews = true {
        didSet {
            edit(keepsTheme: true) { Settings.showPreviews = showPreviews }
            // Thumbnails need Privacy & Security > Screen & System Audio Recording.
            if showPreviews, !loading, !WindowCapture.hasPermission {
                WindowCapture.askForPermission()
                WindowCapture.openPermissionSettings()
            }
        }
    }
    @Published var scrollToOpen = true { didSet { edit(keepsTheme: true) { Settings.scrollToOpen = scrollToOpen } } }
    @Published var clickToHide = false { didSet { edit(keepsTheme: true) { Settings.clickToHide = clickToHide } } }
    @Published var hideSystemDock = true {
        didSet {
            edit(keepsTheme: true) {
                Settings.hideSystemDock = hideSystemDock
                if hideSystemDock { SystemDock.hide() } else { SystemDock.restore(waiting: false) }
            }
        }
    }
    @Published var openAtLogin = false {
        didSet {
            guard !loading, openAtLogin != LoginItem.isEnabled else { return }
            do {
                try LoginItem.set(openAtLogin)
            } catch {
                loading = true
                openAtLogin = LoginItem.isEnabled
                loading = false
            }
        }
    }

    // Top bar
    @Published var barEnabled = false { didSet { barEdit { BarSettings.enabled = barEnabled } } }
    @Published var barAllScreens = true { didSet { barEdit { BarSettings.allScreens = barAllScreens } } }
    @Published var barReplacesMenuBar = false {
        didSet {
            barEdit { BarSettings.replaceMenuBar = barReplacesMenuBar }
            // Show whether macOS allowed it once the change has been made.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.refreshStatus() }
            }
        }
    }
    @Published var menuBarRefused = false
    @Published var barItems: [BarItem] = [] { didSet { barEdit { BarSettings.items = barItems } } }
    @Published var barStyle = BarStyle.wallpaper { didSet { barEdit { BarSettings.style = barStyle } } }
    @Published var barColor = Color.black { didSet { barEdit { BarSettings.color = NSColor(barColor) } } }
    @Published var barOpacity = 0.62 { didSet { barEdit { BarSettings.opacity = barOpacity } } }
    @Published var barAccentIndex = 0 { didSet { barEdit { BarSettings.accentIndex = barAccentIndex } } }
    @Published var barAccentColor = Color.blue { didSet { barEdit { BarSettings.accentColor = NSColor(barAccentColor) } } }
    @Published var barSize = BarSize.medium { didSet { barEdit { BarSettings.size = barSize } } }
    @Published var barFont = BarFont.rounded { didSet { barEdit { BarSettings.font = barFont } } }
    @Published var barCornerRadius = 9.0 { didSet { barEdit { BarSettings.cornerRadius = barCornerRadius } } }
    @Published var barShowDate = true { didSet { barEdit { BarSettings.showDate = barShowDate } } }
    @Published var barUse24Hour = false { didSet { barEdit { BarSettings.use24Hour = barUse24Hour } } }
    @Published var desktopStyle = DesktopStyle.separate { didSet { barEdit { BarSettings.desktopStyle = desktopStyle } } }
    @Published var peekDesktops = true { didSet { barEdit { BarSettings.peekDesktops = peekDesktops } } }
    @Published var albumColours = true { didSet { barEdit { BarSettings.albumColours = albumColours } } }
    @Published var miniPlayer = true { didSet { barEdit { BarSettings.miniPlayer = miniPlayer } } }
    @Published var gameMode = GameMode.slide { didSet { barEdit { BarSettings.gameMode = gameMode } } }
    @Published var menuBarDelay = 1.0 { didSet { barEdit { BarSettings.menuBarDelay = menuBarDelay } } }

    // Lock-in mode
    @Published var lockInHideOthers = true { didSet { barEdit { BarSettings.lockInHideOthers = lockInHideOthers } } }
    @Published var lockInLayout = 2 { didSet { barEdit { BarSettings.lockInLayout = lockInLayout } } }
    @Published var lockInCalmBackdrop = true { didSet { barEdit { BarSettings.lockInCalmBackdrop = lockInCalmBackdrop } } }
    @Published var lockInBorder = true { didSet { barEdit { BarSettings.lockInBorder = lockInBorder } } }
    @Published var lockInGap = 12.0 { didSet { barEdit { BarSettings.lockInGap = lockInGap } } }
    @Published var lockInFrostedCovers = false { didSet { barEdit { BarSettings.lockInFrostedCovers = lockInFrostedCovers } } }
    /// Apps lock-in mode leaves alone, by bundle identifier.
    @Published var lockInAllowedApps: [String] = [] { didSet { barEdit { BarSettings.lockInAllowedApps = lockInAllowedApps } } }

    /// The apps open now that could be added to those lock-in leaves alone.
    var appsToAllow: [(bundle: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !lockInAllowedApps.contains($0.bundle) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Looked up once each: these ask Launch Services, and a settings page is drawn again at every
    /// step of a slider.
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage?] = [:]

    static func appName(_ bundle: String) -> String {
        if let name = names[bundle] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
        names[bundle] = name
        return name
    }

    static func appIcon(_ bundle: String) -> NSImage? {
        if let icon = icons[bundle] { return icon }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { AppIcon.ofApp(at: $0, id: bundle) }
        icons[bundle] = icon
        return icon
    }

    static func fileIcon(_ path: String) -> NSImage {
        if let icon = icons[path], let icon { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// Your desktops, for naming and colouring them. Read when the Desktops tab is shown.
    struct DesktopRow: Identifiable {
        let id: String
        let number: Int
        var name: String
        var colour: DesktopColour?
    }
    @Published var desktopRows: [DesktopRow] = []

    func setDesktopName(_ key: String, _ name: String) {
        var names = BarSettings.desktopNames
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard names[key] != (trimmed.isEmpty ? nil : trimmed) else { return }
        names[key] = trimmed.isEmpty ? nil : trimmed
        BarSettings.desktopNames = names
        if let index = desktopRows.firstIndex(where: { $0.id == key }) { desktopRows[index].name = trimmed }
        barEdit {}
    }

    func setDesktopColour(_ key: String, _ colour: DesktopColour?) {
        var colours = BarSettings.desktopColours
        colours[key] = colour
        BarSettings.desktopColours = colours
        if let index = desktopRows.firstIndex(where: { $0.id == key }) { desktopRows[index].colour = colour }
        barEdit {}
    }

    func loadDesktops() {
        let names = BarSettings.desktopNames
        let colours = BarSettings.desktopColours
        desktopRows = DesktopReader.read(regular: DesktopReader.regularApps()).values.flatMap { $0 }.sorted { $0.number < $1.number }.map {
            DesktopRow(id: $0.key, number: $0.number, name: names[$0.key] ?? "", colour: colours[$0.key])
        }
    }
    @Published var menuBarHidden = false
    @Published var desktopShortcutsOn = true
    @Published var wallpaperAccents: [Color] = []

    func moveBarItem(_ item: BarItem, by offset: Int) {
        // Moves among the items on the same side, which is the order you see in the bar.
        let sameSide = barItems.indices.filter { barItems[$0].side == item.side }
        guard let position = sameSide.firstIndex(where: { barItems[$0].id == item.id }),
              sameSide.indices.contains(position + offset) else { return }
        barItems.swapAt(sameSide[position], sameSide[position + offset])
    }

    func setBarItem(_ item: BarItem) {
        guard let index = barItems.firstIndex(where: { $0.id == item.id }) else { return }
        barItems[index] = item
    }

    func resetBarItems() {
        barItems = BarSettings.defaultItems
    }

    /// Apps you've given your own icon: (app id, app name, picture path).
    @Published var customIcons: [CustomIcon] = []

    struct CustomIcon: Identifiable {
        let id: String
        let name: String
        let path: String
    }

    func resetIcon(_ id: String) {
        var icons = Settings.customIcons
        icons[id] = nil
        Settings.customIcons = icons
        loadCustomIcons()
        changed(.dock)
    }

    private func loadCustomIcons() {
        customIcons = Settings.customIcons.map { id, path in
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            return CustomIcon(id: id, name: name, path: path)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // Permissions and wallpaper colours, refreshed when the window comes forward.
    @Published var hasAccessibility = false
    @Published var hasScreenRecording = false
    @Published var wallpaperBase = Color.gray
    @Published var wallpaperAccent = Color.blue

    func reload() {
        loading = true
        Appearance.reload()
        theme = Appearance.theme
        themes = DockTheme.all
        matchesBar = Appearance.matchesBar
        background = Appearance.background
        backgroundColor = Color(nsColor: Appearance.backgroundColor)
        backgroundOpacity = Appearance.backgroundOpacity
        cornerRadius = Appearance.cornerRadius
        finish = Appearance.finish
        outline = !Appearance.outline ? .none : Appearance.outlineColor == nil ? .automatic : .colour
        outlineColor = Color(nsColor: Appearance.outlineColor ?? .white)
        iconStyle = Appearance.iconStyle
        iconShape = Appearance.iconShape
        markerStyle = Appearance.markerStyle
        markerColor = Appearance.markerColor
        markerCustomColor = Color(nsColor: Appearance.markerCustomColor)
        shadows = Appearance.shadows
        hoverEffect = Appearance.hoverEffect
        magnifyScale = Appearance.magnifyScale
        useGradient = Appearance.gradientColor != nil
        gradientColor = Color(nsColor: Appearance.gradientColor ?? .cyan)
        position = Settings.position
        edgeGap = Appearance.edgeGap
        spacing = Appearance.spacing
        iconSize = Settings.iconSize
        autoHide = Settings.autoHide
        showPinned = Settings.showPinned
        hiddenApps = Settings.hiddenApps
        showTrash = Settings.showTrash
        showBadges = Settings.showBadges
        showPreviews = Settings.showPreviews
        scrollToOpen = Settings.scrollToOpen
        clickToHide = Settings.clickToHide
        hideSystemDock = Settings.hideSystemDock
        openAtLogin = LoginItem.isEnabled
        loadCustomIcons()
        loading = false
        reloadBar()
        refreshStatus()
    }

    /// Just the top bar's settings: they also change from the bar's own menus.
    func reloadBar() {
        loading = true
        barEnabled = BarSettings.enabled
        barAllScreens = BarSettings.allScreens
        barReplacesMenuBar = BarSettings.replaceMenuBar
        barItems = BarSettings.items
        barStyle = BarSettings.style
        barColor = Color(nsColor: BarSettings.color)
        barOpacity = BarSettings.opacity
        barAccentIndex = BarSettings.accentIndex
        barAccentColor = Color(nsColor: BarSettings.accentColor)
        barSize = BarSettings.size
        barFont = BarSettings.font
        barCornerRadius = BarSettings.cornerRadius
        barShowDate = BarSettings.showDate
        barUse24Hour = BarSettings.use24Hour
        desktopStyle = BarSettings.desktopStyle
        peekDesktops = BarSettings.peekDesktops
        albumColours = BarSettings.albumColours
        miniPlayer = BarSettings.miniPlayer
        gameMode = BarSettings.gameMode
        menuBarDelay = BarSettings.menuBarDelay
        lockInHideOthers = BarSettings.lockInHideOthers
        lockInLayout = BarSettings.lockInLayout
        lockInCalmBackdrop = BarSettings.lockInCalmBackdrop
        lockInBorder = BarSettings.lockInBorder
        lockInGap = BarSettings.lockInGap
        lockInFrostedCovers = BarSettings.lockInFrostedCovers
        lockInAllowedApps = BarSettings.lockInAllowedApps
        if !desktopRows.isEmpty { loadDesktops() }
        loading = false
    }

    func refreshStatus() {
        hasAccessibility = AXIsProcessTrusted()
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        wallpaperBase = Color(nsColor: WallpaperPalette.shared.base)
        wallpaperAccent = Color(nsColor: WallpaperPalette.shared.accent)
        wallpaperAccents = WallpaperPalette.shared.accents.map { Color(nsColor: $0) }
        menuBarHidden = BarSettings.macMenuBarHidden
        menuBarRefused = SystemMenuBar.refused
        desktopShortcutsOn = DesktopSwitcher.canSwitch
    }

    func apply(_ theme: DockTheme) {
        // A theme is a look of the dock's own.
        Appearance.matchesBar = false
        theme.apply()
        reload()
        changed(.dock)
    }

    func saveTheme(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        DockTheme.saveCurrent(named: trimmed.isEmpty ? "My Theme" : trimmed)
        reload()
    }

    func deleteTheme(_ id: String) {
        DockTheme.deleteCustom(id)
        reload()
    }

    private var themeFileType: UTType { UTType(filenameExtension: DockTheme.fileExtension) ?? .propertyList }

    /// Saves the current look to a file you can keep or share.
    func exportTheme() {
        let current = themes.first { $0.id == theme }
        let panel = NSSavePanel()
        panel.title = "Export Theme"
        panel.allowedContentTypes = [themeFileType]
        panel.nameFieldStringValue = (current?.name ?? "My Dock Theme") + "." + DockTheme.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let named = DockTheme(id: "export", name: current?.name ?? url.deletingPathExtension().lastPathComponent,
                              summary: "", look: .current)
        try? named.export(to: url)
    }

    /// Adds a theme from a file and switches to it.
    func importTheme() {
        let panel = NSOpenPanel()
        panel.title = "Import Theme"
        panel.allowedContentTypes = [themeFileType, .propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DockTheme.importTheme(from: url)
            reload()
            changed(.dock)
        } catch {
            let alert = NSAlert()
            alert.messageText = "That file isn't a Clear Dock theme."
            alert.runModal()
        }
    }

    /// Saves a change to the dock and redraws it shortly after; sliders send many small changes,
    /// so they're gathered into one redraw.
    private func edit(keepsTheme: Bool = false, _ save: () -> Void) {
        guard !loading else { return }
        save()
        if !keepsTheme {
            Appearance.theme = nil
            if theme != nil { theme = nil }
        }
        schedule(.dock)
    }

    /// The same for the top bar (and lock-in mode), which redraws on its own.
    private func barEdit(_ save: () -> Void) {
        guard !loading else { return }
        save()
        schedule(.bar)
    }

    /// Passes on changes still waiting to be passed on, straight away.
    func applyPending() {
        guard let pending else { return }
        pending.cancel()
        self.pending = nil
        let areas = pendingAreas
        pendingAreas.removeAll()
        areas.forEach(changed)
    }

    private func schedule(_ area: SettingsArea) {
        pendingAreas.insert(area)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let areas = self.pendingAreas
                self.pendingAreas.removeAll()
                areas.forEach(self.changed)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

enum OutlineChoice: String, CaseIterable, Identifiable {
    case none, automatic, colour
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .automatic: "Soft"
        case .colour: "Colour"
        }
    }
}

// MARK: - Window content

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        TabView(selection: $store.tab) {
            DockTab(store: store)
                .tabItem { Label("Dock", systemImage: "dock.rectangle") }
                .tag(SettingsTab.dock)
            LookTab(store: store)
                .tabItem { Label("Dock Look", systemImage: "paintpalette") }
                .tag(SettingsTab.look)
            TopBarTab(store: store)
                .tabItem { Label("Top Bar", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.topBar)
            DesktopsTab(store: store)
                .tabItem { Label("Desktops", systemImage: "square.split.2x2") }
                .tag(SettingsTab.desktops)
            GeneralTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .frame(width: 620, height: 600)
        // Rather than switches: see `PlainSlider`.
        .toggleStyle(.checkbox)
        // These change what's shown, so they wait until the window has finished drawing: changing
        // it while SwiftUI is in the middle of drawing it can go wrong.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            DispatchQueue.main.async { store.refreshStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: WallpaperPalette.didChange)) { _ in
            DispatchQueue.main.async { store.refreshStatus() }
        }
        // The top bar's own menus change its settings too; show those changes here.
        .onReceive(NotificationCenter.default.publisher(for: BarSettings.didChange)) { _ in
            DispatchQueue.main.async { store.reloadBar() }
        }
        // And the dock's menus change the dock's.
        .onReceive(NotificationCenter.default.publisher(for: Settings.changedElsewhere)) { _ in
            DispatchQueue.main.async { store.reload() }
        }
    }
}

/// A slider drawn from plain shapes. macOS's own sliders and switches give their glass knobs a large
/// graphics buffer, over 130 MB for a moment whenever a window showing one opens, so the settings
/// window uses this and checkboxes instead.
private struct PlainSlider: View {
    private let title: String?
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double?

    private static let knob: CGFloat = 16

    init(_ title: String? = nil, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        if let title {
            LabeledContent(title) { track.frame(width: 240) }
        } else {
            track
        }
    }

    private var fraction: Double {
        (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private var track: some View {
        GeometryReader { geometry in
            let usable = max(geometry.size.width - Self.knob, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: Self.knob / 2 + usable * fraction, height: 4)
                Circle().fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
                    .frame(width: Self.knob, height: Self.knob)
                    .offset(x: usable * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                set(fraction: (drag.location.x - Self.knob / 2) / usable)
            })
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel(title ?? "")
        .accessibilityValue(String(format: "%.1f", value))
        .accessibilityAdjustableAction { direction in
            let change = step ?? (range.upperBound - range.lowerBound) / 20
            set(value: value + (direction == .increment ? change : -change))
        }
    }

    private func set(fraction: Double) {
        set(value: range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound))
    }

    private func set(value new: Double) {
        var new = new
        if let step { new = (new / step).rounded() * step }
        new = min(max(new, range.lowerBound), range.upperBound)
        if new != value { value = new }
    }
}

/// A short note under a section.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

private struct DockTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Where it sits") {
                Picker("Position", selection: $store.position) {
                    ForEach(DockEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Hide until the pointer reaches the edge", isOn: $store.autoHide)
                Toggle("Hide the macOS Dock", isOn: $store.hideSystemDock)
            }
            Section {
                Toggle("Apps pinned in the macOS Dock", isOn: $store.showPinned)
                Toggle("Trash", isOn: $store.showTrash)
                Toggle("Notification badges", isOn: $store.showBadges)
                ForEach(store.hiddenApps, id: \.self) { app in
                    HStack(spacing: 8) {
                        if let icon = SettingsStore.appIcon(app) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        Text(SettingsStore.appName(app))
                        Spacer()
                        Button("Show in Dock") { store.hiddenApps.removeAll { $0 == app } }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("What it shows")
            } footer: {
                Note("Right-click an app in the dock and choose Hide from Dock to keep it out, even while it's open.")
            }
            Section {
                Toggle("Window previews when pointing at an app", isOn: $store.showPreviews)
                Toggle("Scroll up on an icon to show its windows", isOn: $store.scrollToOpen)
                Toggle("Click the app you're using to hide it", isOn: $store.clickToHide)
            } header: {
                Text("Pointing and clicking")
            } footer: {
                Note("⌘-click shows an app in Finder, ⌥-click switches and hides the app you were using, and dragging an icon sideways moves it.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct LookTab: View {
    @ObservedObject var store: SettingsStore
    @State private var naming = false
    @State private var newName = ""

    private let columns = Array(repeating: GridItem(.fixed(104), spacing: 8), count: 5)

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
                    ForEach(store.themes) { theme in
                        ThemeCard(theme: theme, selected: store.theme == theme.id,
                                  accent: store.wallpaperAccent, base: store.wallpaperBase) {
                            store.apply(theme)
                        }
                        .contextMenu {
                            if theme.isCustom {
                                Button("Delete \(theme.name)", role: .destructive) { store.deleteTheme(theme.id) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                HStack {
                    Text("Themes")
                    Spacer()
                    Menu("More") {
                        Button("Save Current Look as Theme…") {
                            newName = ""
                            naming = true
                        }
                        Button("Import Theme…") { store.importTheme() }
                        Button("Export Theme…") { store.exportTheme() }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            Section("Icons") {
                Picker("Style", selection: $store.iconStyle) {
                    ForEach(IconStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Shape", selection: $store.iconShape) {
                    ForEach(IconShape.allCases) { Text($0.title).tag($0) }
                }
                PlainSlider("Size", value: $store.iconSize, in: 24...96, step: 1)
                PlainSlider("Spacing", value: $store.spacing, in: 0.3...2.5)
                Picker("When pointed at", selection: $store.hoverEffect) {
                    ForEach(HoverEffect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.hoverEffect == .magnify {
                    PlainSlider("Magnification", value: $store.magnifyScale, in: 1.2...2.2)
                }
                Toggle("Shadows", isOn: $store.shadows)
                PlainSlider("Distance from the edge", value: $store.edgeGap, in: 0...40, step: 1)
            }

            Section("Background") {
                Toggle("Match the top bar", isOn: $store.matchesBar)
                if store.matchesBar {
                    Note(store.barEnabled
                         ? "The dock takes the top bar's glass or colour, rounding and highlight, and changes with it, desktop by desktop."
                         : "The dock takes the top bar's look while the top bar is on.")
                } else {
                    backgroundChoices
                }
            }

            Section("Open apps") {
                Picker("Mark", selection: $store.markerStyle) {
                    ForEach(MarkerStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.markerStyle != .none && !store.matchesBar {
                    Picker("Colour", selection: $store.markerColor) {
                        ForEach(MarkerColor.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if store.markerColor == .custom {
                        ColorPicker("Mark colour", selection: $store.markerCustomColor, supportsOpacity: false)
                    }
                }
            }

            Section {
                if store.customIcons.isEmpty {
                    Note("Right-click an app in the dock and choose Change Icon… to use your own picture.")
                } else {
                    ForEach(store.customIcons) { icon in
                        HStack {
                            Image(nsImage: SettingsStore.fileIcon(icon.path))
                                .resizable().frame(width: 22, height: 22)
                            Text(icon.name)
                            Spacer()
                            Button("Use Original") { store.resetIcon(icon.id) }
                        }
                    }
                }
            } header: {
                Text("Your own icons")
            }
        }
        .formStyle(.grouped)
        .alert("Name this theme", isPresented: $naming) {
            TextField("Theme name", text: $newName)
            Button("Save") { store.saveTheme(named: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It saves the current background, icon style, shape and marks.")
        }
    }

    /// The dock's own background, when it isn't matching the top bar.
    @ViewBuilder private var backgroundChoices: some View {
        Picker("Behind the icons", selection: $store.background) {
            ForEach(DockBackground.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if store.background == .color {
            ColorPicker("Colour", selection: $store.backgroundColor, supportsOpacity: false)
            Toggle("Fade into a second colour", isOn: $store.useGradient)
            if store.useGradient {
                ColorPicker("Second colour", selection: $store.gradientColor, supportsOpacity: false)
            }
        }
        if store.background == .wallpaper {
            LabeledContent("Colours from your wallpaper") {
                HStack(spacing: 6) {
                    Swatch(color: store.wallpaperBase)
                    Swatch(color: store.wallpaperAccent)
                }
            }
        }
        if store.background == .color || store.background == .wallpaper {
            PlainSlider("Strength", value: $store.backgroundOpacity, in: 0.15...1)
            Picker("Finish", selection: $store.finish) {
                ForEach(BarFinish.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Outline", selection: $store.outline) {
                ForEach(OutlineChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if store.outline == .colour {
                ColorPicker("Outline colour", selection: $store.outlineColor, supportsOpacity: false)
            }
        }
        if store.background != .none {
            PlainSlider("Corner rounding", value: $store.cornerRadius, in: 0...30)
        }
    }
}

private struct TopBarTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Show the top bar", isOn: $store.barEnabled)
                Toggle("On every screen", isOn: $store.barAllScreens)
                    .disabled(!store.barEnabled)
                Toggle("Replace the macOS menu bar", isOn: $store.barReplacesMenuBar)
                    .disabled(!store.barEnabled)
                if store.barReplacesMenuBar {
                    LabeledContent("Hold at the top for macOS menus") {
                        HStack {
                            PlainSlider(value: $store.menuBarDelay, in: 0.2...3, step: 0.1).frame(width: 160)
                            Text(String(format: "%.1f s", store.menuBarDelay)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                if store.menuBarRefused {
                    LabeledContent("macOS didn't allow it") {
                        Button("Open Automation Settings…") { SystemMenuBar.openAutomationSettings() }
                    }
                }
            } footer: {
                Note("The macOS menu bar comes back when the top bar is off or Clear Dock quits.")
            }

            Section {
                ForEach(BarSide.allCases) { side in
                    let items = store.barItems.filter { $0.side == side }
                    ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                        BarItemRow(item: item, first: position == 0, last: position == items.count - 1, store: store)
                    }
                }
            } header: {
                HStack {
                    Text("What's in it")
                    Spacer()
                    Button("Reset") { store.resetBarItems() }.controlSize(.small)
                }
            } footer: {
                Note("Right-click anything in the bar to hide it or change it.")
            }

            Section("Look") {
                Picker("Background", selection: $store.barStyle) {
                    ForEach(BarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.barStyle == .color {
                    ColorPicker("Colour", selection: $store.barColor, supportsOpacity: false)
                }
                LabeledContent("Highlight") {
                    HStack(spacing: 8) {
                        ForEach(Array(store.wallpaperAccents.enumerated()), id: \.offset) { index, color in
                            Button { store.barAccentIndex = index } label: {
                                Swatch(color: color)
                                    .overlay(RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(Color.accentColor, lineWidth: store.barAccentIndex == index ? 2.5 : 0))
                            }
                            .buttonStyle(.plain)
                            .help("A colour from your wallpaper")
                        }
                        Divider().frame(height: 18)
                        Button { store.barAccentIndex = -1 } label: {
                            Text("Own colour")
                                .foregroundStyle(store.barAccentIndex == -1 ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                        if store.barAccentIndex == -1 {
                            ColorPicker("", selection: $store.barAccentColor, supportsOpacity: false).labelsHidden()
                        }
                    }
                }
                Picker("Size", selection: $store.barSize) {
                    ForEach(BarSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Font", selection: $store.barFont) {
                    ForEach(BarFont.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                PlainSlider("Corner rounding", value: $store.barCornerRadius, in: 0...15)
            }

            Section("Song playing") {
                Toggle("Colours from the album cover", isOn: $store.albumColours)
                Toggle("Small player when pointing at the song", isOn: $store.miniPlayer)
            }

            Section("Date and time") {
                Toggle("Show the date", isOn: $store.barShowDate)
                Toggle("24-hour clock", isOn: $store.barUse24Hour)
            }

            Section {
                Picker("When a game is in front", selection: $store.gameMode) {
                    ForEach(GameMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Note("Also for anything else filling the screen.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DesktopsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Show desktops as", selection: $store.desktopStyle) {
                    ForEach(DesktopStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Picture of a desktop when pointing at it", isOn: $store.peekDesktops)
                ForEach(store.desktopRows) { row in
                    HStack(spacing: 10) {
                        Text("Desktop \(row.number)").frame(width: 80, alignment: .leading)
                        DesktopNameField(name: row.name) { store.setDesktopName(row.id, $0) }
                        Picker("", selection: Binding(get: { row.colour }, set: { store.setDesktopColour(row.id, $0) })) {
                            Text("No colour").tag(DesktopColour?.none)
                            ForEach(DesktopColour.allCases) { colour in
                                Label { Text(colour.title) } icon: { Image(nsImage: Swatches.image(colour.color)) }
                                    .tag(DesktopColour?.some(colour))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
                if !store.desktopShortcutsOn {
                    LabeledContent("Switching desktops needs macOS's shortcuts") {
                        Button("Open Keyboard Shortcuts…") { DesktopSwitcher.openShortcutSettings() }
                    }
                }
            } header: {
                Text("Desktops")
            } footer: {
                Note("The bar takes on the colour of the desktop you're on. Right-click a desktop in the bar to name or colour it there.")
            }

            Section {
                PlainSlider("Gap around the apps", value: $store.lockInGap, in: 0...40, step: 1)
                Picker("Layout", selection: $store.lockInLayout) {
                    Text("One app").tag(1)
                    Text("Two side by side").tag(2)
                    Text("Three, two stacked").tag(3)
                }
                Toggle("Calm backdrop behind the windows", isOn: $store.lockInCalmBackdrop)
                Toggle("Tuck away the other windows", isOn: $store.lockInHideOthers)
                Toggle("Glowing edge around both apps", isOn: $store.lockInBorder)
                LabeledContent("Apps left alone") {
                    Menu("Add") {
                        ForEach(store.appsToAllow, id: \.bundle) { app in
                            Button(app.name) { store.lockInAllowedApps.append(app.bundle) }
                        }
                    }
                    .fixedSize()
                }
                ForEach(store.lockInAllowedApps, id: \.self) { bundle in
                    HStack(spacing: 8) {
                        if let icon = SettingsStore.appIcon(bundle) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        Text(SettingsStore.appName(bundle))
                        Spacer()
                        Button("Remove") { store.lockInAllowedApps.removeAll { $0 == bundle } }
                            .controlSize(.small)
                    }
                }
                Picker("While dragging the edge", selection: $store.lockInFrostedCovers) {
                    Text("Plain").tag(false)
                    Text("Frosted").tag(true)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Lock-in mode")
            } footer: {
                Note("Lock In puts two apps side by side on the desktop you're on. Everything else there is tucked away until you unlock, and anything new that opens there moves to a desktop that isn't locked in. Apps left alone (like Spotify) open and stay there as usual.")
            }
        }
        .formStyle(.grouped)
        .onAppear { DispatchQueue.main.async { store.loadDesktops() } }
    }
}

/// A desktop's name, saved when you press Return or click away rather than at every key.
private struct DesktopNameField: View {
    let name: String
    let save: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text("Name"))
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { text = name }
            // Renamed from the bar meanwhile: show it, unless you're typing here.
            .onChange(of: name) { _, renamed in
                if !focused { text = renamed }
            }
            .onSubmit { save(text) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { save(text) }
            }
    }
}

/// One item in the top bar's list: whether it shows, which side it's on, and moving it along.
private struct BarItemRow: View {
    let item: BarItem
    let first: Bool
    let last: Bool
    @ObservedObject var store: SettingsStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol)
                .frame(width: 20)
                .foregroundStyle(item.isOn ? Color.accentColor : .secondary)
            Toggle(item.kind.title, isOn: Binding(
                get: { item.isOn },
                set: { var changed = item; changed.isOn = $0; store.setBarItem(changed) }))
            Spacer()
            Picker("", selection: Binding(
                get: { item.side },
                set: { var changed = item; changed.side = $0; store.setBarItem(changed) })) {
                ForEach(BarSide.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            // Each side reads left to right, so these move the item along the bar.
            Button { store.moveBarItem(item, by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(first)
                .help("Move left")
            Button { store.moveBarItem(item, by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(last)
                .help("Move right")
        }
    }
}

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $store.openAtLogin)
            }
            Section {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Badges, previews, keeping windows clear of the dock and the bar, switching desktops, music controls and lock-in mode.",
                    granted: store.hasAccessibility,
                    settingsPage: "Privacy_Accessibility")
                PermissionRow(
                    title: "Screen & System Audio Recording",
                    detail: "Window previews, and your wallpaper's colours.",
                    granted: store.hasScreenRecording,
                    settingsPage: "Privacy_ScreenCapture")
            } header: {
                Text("Permissions")
            } footer: {
                Note("Clear Dock never records or keeps what's on your screen.")
            }
            Section {
                HStack {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading) {
                        Text("Clear Dock").font(.headline)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Quit Clear Dock") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let settingsPage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPage)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct Swatch: View {
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(color)
            .frame(width: 22, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.15)))
    }
}

/// A small picture of a theme: a little dock over a sky-and-sand scene, like a wallpaper.
private struct ThemeCard: View {
    let theme: DockTheme
    let selected: Bool
    let accent: Color
    let base: Color
    let action: () -> Void

    private var look: Look { theme.look }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Color(red: 0.52, green: 0.78, blue: 0.96), Color(red: 0.93, green: 0.86, blue: 0.70)],
                                   startPoint: .top, endPoint: .bottom)
                    miniDock.padding(.bottom, 6)
                }
                .frame(width: 104, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
                )
                Text(theme.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(theme.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 108)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tileShape: AnyShape {
        switch look.iconShape {
        case .circle: AnyShape(Circle())
        case .square: AnyShape(Rectangle())
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: 2))
        default:
            switch look.iconStyle {
            case .pixel, .classic, .gameboy: AnyShape(Rectangle())
            default: AnyShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            }
        }
    }

    private var miniDock: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { i in
                VStack(spacing: 2) {
                    tileShape.fill(tileColor(i)).frame(width: 13, height: 13)
                        .overlay(tileShape.stroke(look.iconStyle == .sticker ? Color.white : look.iconStyle == .synthwave ? Color.cyan : .clear,
                                                  lineWidth: 1.2))
                        .overlay(alignment: .top) {
                            if look.iconStyle == .aqua {
                                tileShape.fill(LinearGradient(colors: [.white.opacity(0.7), .clear], startPoint: .top, endPoint: .center))
                                    .frame(width: 13, height: 13)
                            }
                        }
                        .shadow(color: .black.opacity(look.shadows ? 0.25 : 0), radius: 1, y: 0.5)
                    marker.opacity(i < 3 ? 1 : 0)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background { backgroundShape }
    }

    @ViewBuilder private var marker: some View {
        let color: Color = switch look.markerColor {
        case .white: .white
        case .black: .black
        case .wallpaper: accent
        case .custom: Color(nsColor: NSColor(hex: look.markerCustomColor) ?? .white)
        }
        switch look.markerStyle {
        case .dot: Circle().fill(color).frame(width: 2.5, height: 2.5)
        case .line: Capsule().fill(color).frame(width: 6, height: 1.5)
        case .square: Rectangle().fill(color).frame(width: 3, height: 3)
        case .none: Color.clear.frame(width: 2.5, height: 2.5)
        }
    }

    @ViewBuilder private var backgroundShape: some View {
        let shape = RoundedRectangle(cornerRadius: min(look.cornerRadius / 3, 8))
        let outline = look.outline ? (NSColor(hex: look.outlineColor).map { Color(nsColor: $0) } ?? Color.black.opacity(0.25)) : .clear
        switch look.background {
        case .none: Color.clear
        case .glass: shape.fill(.ultraThinMaterial)
        case .color, .wallpaper:
            let fill: Color = look.background == .color ? Color(nsColor: NSColor(hex: look.backgroundColor) ?? .black) : base
            let second = look.background == .color ? NSColor(hex: look.gradientColor).map { Color(nsColor: $0) } : nil
            shape.fill(LinearGradient(colors: [fill, second ?? fill], startPoint: .top, endPoint: .bottom)
                .opacity(look.backgroundOpacity))
                .overlay {
                    if look.finish == .gloss {
                        shape.fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08), .clear],
                                                  startPoint: .top, endPoint: .center))
                    }
                }
                .overlay(shape.strokeBorder(outline, lineWidth: look.finish == .bevel ? 1 : 0.6))
        }
    }

    private func tileColor(_ i: Int) -> Color {
        let originals: [Color] = [.blue, .green, .orange, .pink]
        switch look.iconStyle {
        case .original, .aqua, .sticker: return originals[i]
        case .soft: return originals[i].opacity(0.7)
        case .vintage: return [Color(red: 0.72, green: 0.58, blue: 0.42), Color(red: 0.63, green: 0.60, blue: 0.45),
                               Color(red: 0.78, green: 0.62, blue: 0.45), Color(red: 0.60, green: 0.50, blue: 0.40)][i]
        case .mono: return Color(white: [0.35, 0.55, 0.7, 0.45][i])
        case .tinted: return accent.opacity([1, 0.75, 0.55, 0.85][i])
        case .pixel: return [Color(red: 0.2, green: 0.4, blue: 1), Color(red: 0.2, green: 0.8, blue: 0.2),
                             Color(red: 1, green: 0.6, blue: 0), Color(red: 1, green: 0.2, blue: 0.4)][i]
        case .classic: return i % 2 == 0 ? .white : .black
        case .gameboy: return [Color(red: 0.06, green: 0.22, blue: 0.06), Color(red: 0.19, green: 0.38, blue: 0.19),
                               Color(red: 0.55, green: 0.67, blue: 0.06), Color(red: 0.19, green: 0.38, blue: 0.19)][i]
        case .synthwave: return [Color(red: 1, green: 0.18, blue: 0.59), Color(red: 0.55, green: 0.05, blue: 0.55),
                                 Color(red: 0.24, green: 0.95, blue: 1), Color(red: 1, green: 0.18, blue: 0.59)][i]
        case .phosphor: return [Color(red: 0.1, green: 1, blue: 0.45), Color(red: 0, green: 0.35, blue: 0.12),
                                Color(red: 0.1, green: 0.8, blue: 0.35), Color(red: 0, green: 0.5, blue: 0.2)][i]
        case .ink: return i % 2 == 0 ? Color(red: 0.96, green: 0.94, blue: 0.89) : Color(white: 0.1)
        case .pastel: return [Color(red: 0.75, green: 0.85, blue: 1), Color(red: 0.8, green: 0.95, blue: 0.82),
                              Color(red: 1, green: 0.88, blue: 0.75), Color(red: 1, green: 0.8, blue: 0.88)][i]
        case .blueprint: return Color(red: 0.12, green: 0.31, blue: 0.62)
        }
    }
}

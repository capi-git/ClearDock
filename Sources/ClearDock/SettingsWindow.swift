import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens and closes the settings window. While it's open Clear Dock behaves like a normal app
/// (it appears in ⌘-Tab), and the dock stays on screen so changes show up as you make them.
/// The window is let go of when closed, so it uses no memory the rest of the time.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Called whenever a setting changes, so the dock can redraw.
    var onChange: () -> Void = {}
    /// Called with true when the window opens and false when it closes.
    var onOpenChanged: (Bool) -> Void = { _ in }

    private var window: NSWindow?
    private var store: SettingsStore?

    func show(tab: SettingsTab? = nil) {
        if window == nil {
            let store = SettingsStore(onChange: { [weak self] in self?.onChange() })
            self.store = store
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
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
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        store = nil
        NSApp.setActivationPolicy(.accessory)
        onOpenChanged(false)
        MemoryRelief.soon()
    }
}

enum SettingsTab: String, Hashable {
    case look, topBar, behaviour, permissions, about
}

/// The settings, as the window shows and edits them.
@MainActor
final class SettingsStore: ObservableObject {
    private let changed: () -> Void
    private var pending: DispatchWorkItem?
    /// Set while values are being loaded, so loading doesn't count as an edit.
    private var loading = true

    init(onChange: @escaping () -> Void) {
        changed = onChange
        reload()
    }

    /// The window opens on the tab you last used.
    @Published var tab = UserDefaults.standard.string(forKey: "settingsTab").flatMap(SettingsTab.init(rawValue:)) ?? .look {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
    }

    // Look
    @Published var theme: String?
    @Published var themes: [DockTheme] = []
    @Published var background = DockBackground.none { didSet { edit { Appearance.background = background } } }
    @Published var backgroundColor = Color.black { didSet { edit { Appearance.backgroundColor = NSColor(backgroundColor) } } }
    @Published var backgroundOpacity = 0.5 { didSet { edit { Appearance.backgroundOpacity = backgroundOpacity } } }
    @Published var cornerRadius = 18.0 { didSet { edit { Appearance.cornerRadius = cornerRadius } } }
    @Published var finish = BarFinish.flat { didSet { edit { Appearance.finish = finish } } }
    @Published var outline = true { didSet { edit { Appearance.outline = outline } } }
    @Published var customOutline = false {
        didSet { edit { Appearance.outlineColor = customOutline ? NSColor(outlineColor) : nil } }
    }
    @Published var outlineColor = Color.white {
        didSet { edit { if customOutline { Appearance.outlineColor = NSColor(outlineColor) } } }
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

    // Behaviour
    @Published var autoHide = true { didSet { edit(keepsTheme: true) { Settings.autoHide = autoHide } } }
    @Published var showPinned = false { didSet { edit(keepsTheme: true) { Settings.showPinned = showPinned } } }
    @Published var showTrash = true { didSet { edit(keepsTheme: true) { Settings.showTrash = showTrash } } }
    @Published var showBadges = true { didSet { edit(keepsTheme: true) { Settings.showBadges = showBadges } } }
    @Published var showPreviews = true { didSet { edit(keepsTheme: true) { Settings.showPreviews = showPreviews } } }
    @Published var scrollToOpen = true { didSet { edit(keepsTheme: true) { Settings.scrollToOpen = scrollToOpen } } }
    @Published var clickToHide = false { didSet { edit(keepsTheme: true) { Settings.clickToHide = clickToHide } } }
    @Published var hideSystemDock = true {
        didSet {
            edit(keepsTheme: true) {
                Settings.hideSystemDock = hideSystemDock
                if hideSystemDock { SystemDock.hide() } else { SystemDock.restore() }
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
    @Published var barEnabled = false { didSet { edit(keepsTheme: true) { BarSettings.enabled = barEnabled } } }
    @Published var barAllScreens = true { didSet { edit(keepsTheme: true) { BarSettings.allScreens = barAllScreens } } }
    @Published var barItems: [BarItem] = [] { didSet { edit(keepsTheme: true) { BarSettings.items = barItems } } }
    @Published var barStyle = BarStyle.wallpaper { didSet { edit(keepsTheme: true) { BarSettings.style = barStyle } } }
    @Published var barColor = Color.black { didSet { edit(keepsTheme: true) { BarSettings.color = NSColor(barColor) } } }
    @Published var barOpacity = 0.62 { didSet { edit(keepsTheme: true) { BarSettings.opacity = barOpacity } } }
    @Published var barAccentIndex = 0 { didSet { edit(keepsTheme: true) { BarSettings.accentIndex = barAccentIndex } } }
    @Published var barAccentColor = Color.blue {
        didSet { edit(keepsTheme: true) { BarSettings.accentColor = NSColor(barAccentColor) } }
    }
    @Published var barSize = BarSize.medium { didSet { edit(keepsTheme: true) { BarSettings.size = barSize } } }
    @Published var barFont = BarFont.rounded { didSet { edit(keepsTheme: true) { BarSettings.font = barFont } } }
    @Published var barCornerRadius = 9.0 { didSet { edit(keepsTheme: true) { BarSettings.cornerRadius = barCornerRadius } } }
    @Published var barShowDate = true { didSet { edit(keepsTheme: true) { BarSettings.showDate = barShowDate } } }
    @Published var barUse24Hour = false { didSet { edit(keepsTheme: true) { BarSettings.use24Hour = barUse24Hour } } }
    @Published var menuBarHidden = false
    @Published var desktopShortcutsOn = false
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
        changed()
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
        background = Appearance.background
        backgroundColor = Color(nsColor: Appearance.backgroundColor)
        backgroundOpacity = Appearance.backgroundOpacity
        cornerRadius = Appearance.cornerRadius
        finish = Appearance.finish
        outline = Appearance.outline
        customOutline = Appearance.outlineColor != nil
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
        showTrash = Settings.showTrash
        showBadges = Settings.showBadges
        showPreviews = Settings.showPreviews
        scrollToOpen = Settings.scrollToOpen
        clickToHide = Settings.clickToHide
        hideSystemDock = Settings.hideSystemDock
        openAtLogin = LoginItem.isEnabled
        barEnabled = BarSettings.enabled
        barAllScreens = BarSettings.allScreens
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
        loadCustomIcons()
        refreshStatus()
        loading = false
    }

    func refreshStatus() {
        loadCustomIcons()
        hasAccessibility = AXIsProcessTrusted()
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        wallpaperBase = Color(nsColor: WallpaperPalette.shared.base)
        wallpaperAccent = Color(nsColor: WallpaperPalette.shared.accent)
        wallpaperAccents = WallpaperPalette.shared.accents.map { Color(nsColor: $0) }
        menuBarHidden = BarSettings.macMenuBarHidden
        desktopShortcutsOn = DesktopSwitcher.shortcutsOn
    }

    func apply(_ theme: DockTheme) {
        theme.apply()
        reload()
        changed()
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
            changed()
        } catch {
            let alert = NSAlert()
            alert.messageText = "That file isn't a Clear Dock theme."
            alert.runModal()
        }
    }

    /// Saves a change and redraws the dock shortly after; sliders send many small changes,
    /// so they're gathered into one redraw.
    private func edit(keepsTheme: Bool = false, _ save: () -> Void) {
        guard !loading else { return }
        save()
        if !keepsTheme {
            Appearance.theme = nil
            theme = nil
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

// MARK: - Window content

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        TabView(selection: $store.tab) {
            LookTab(store: store)
                .tabItem { Label("Look", systemImage: "paintpalette") }
                .tag(SettingsTab.look)
            TopBarTab(store: store)
                .tabItem { Label("Top Bar", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.topBar)
            BehaviourTab(store: store)
                .tabItem { Label("Behaviour", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.behaviour)
            PermissionsTab(store: store)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 640, height: 620)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: WallpaperPalette.didChange)) { _ in
            store.refreshStatus()
        }
    }
}

private struct LookTab: View {
    @ObservedObject var store: SettingsStore
    @State private var naming = false
    @State private var newName = ""

    private let columns = Array(repeating: GridItem(.fixed(108), spacing: 8), count: 5)

    var body: some View {
        Form {
            Section("Themes") {
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
                HStack {
                    Button("Import…") { store.importTheme() }
                    Button("Export…") { store.exportTheme() }
                    Spacer()
                    Button("Save Current Look as Theme…") {
                        newName = ""
                        naming = true
                    }
                }
                Text("Right-click one of your own themes to delete it. Exported themes are small files you can share.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Icons") {
                Picker("Theme", selection: $store.iconStyle) {
                    ForEach(IconStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Shape", selection: $store.iconShape) {
                    ForEach(IconShape.allCases) { Text($0.title).tag($0) }
                }
                Slider(value: $store.iconSize, in: 24...96, step: 1) { Text("Size") } minimumValueLabel: {
                    Image(systemName: "app").imageScale(.small)
                } maximumValueLabel: {
                    Image(systemName: "app").imageScale(.large)
                }
                Slider(value: $store.spacing, in: 0.3...2.5) { Text("Spacing") }
                Picker("When pointed at", selection: $store.hoverEffect) {
                    ForEach(HoverEffect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.hoverEffect == .magnify {
                    Slider(value: $store.magnifyScale, in: 1.2...2.2) { Text("Magnification") }
                }
                Toggle("Shadows", isOn: $store.shadows)
                Slider(value: $store.edgeGap, in: 0...40, step: 1) { Text("Distance from edge") }
            }

            Section("Background") {
                Picker("Behind the icons", selection: $store.background) {
                    ForEach(DockBackground.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.background == .color {
                    ColorPicker("Colour", selection: $store.backgroundColor, supportsOpacity: false)
                    Toggle("Gradient", isOn: $store.useGradient)
                    if store.useGradient {
                        ColorPicker("Fades into", selection: $store.gradientColor, supportsOpacity: false)
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
                    Slider(value: $store.backgroundOpacity, in: 0.15...1) { Text("Strength") }
                    Picker("Finish", selection: $store.finish) {
                        ForEach(BarFinish.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Outline", isOn: $store.outline)
                    if store.outline {
                        Toggle("Choose outline colour", isOn: $store.customOutline)
                        if store.customOutline {
                            ColorPicker("Outline colour", selection: $store.outlineColor, supportsOpacity: false)
                        }
                    }
                }
                if store.background != .none {
                    Slider(value: $store.cornerRadius, in: 0...30) { Text("Corner rounding") }
                }
                if store.background == .glass {
                    Text("Glass blurs what's behind the dock, which uses a little graphics power while the dock is showing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Your app icons") {
                if store.customIcons.isEmpty {
                    Text("Right-click any app in the dock and choose Change Icon… to use your own picture. Your icon theme is still applied on top.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(store.customIcons) { icon in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: icon.path))
                                .resizable().frame(width: 22, height: 22)
                            Text(icon.name)
                            Spacer()
                            Button("Use Original") { store.resetIcon(icon.id) }
                        }
                    }
                }
            }

            Section("Open apps") {
                Picker("Mark", selection: $store.markerStyle) {
                    ForEach(MarkerStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Colour", selection: $store.markerColor) {
                    ForEach(MarkerColor.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(store.markerStyle == .none)
                if store.markerColor == .custom && store.markerStyle != .none {
                    ColorPicker("Mark colour", selection: $store.markerCustomColor, supportsOpacity: false)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Name this theme", isPresented: $naming) {
            TextField("Theme name", text: $newName)
            Button("Save") { store.saveTheme(named: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It saves the current background, icon theme, shape and marks.")
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
                LabeledContent("macOS menu bar") {
                    HStack {
                        Text(store.menuBarHidden ? "Hidden: the top bar takes its place" : "Showing: the top bar sits under it")
                            .foregroundStyle(.secondary)
                        Button("Change…") { BarSettings.openMenuBarSettings() }
                    }
                }
            } footer: {
                Text("For the top bar to replace the macOS menu bar, set \"Automatically hide and show the menu bar\" to Always. Push the pointer to the very top of the screen to get the macOS menus back. The bar leaves room for the camera notch and for notch apps like Vorssaint.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("Each side reads left to right in this order. Right-click anything in the bar to hide it or change it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Look") {
                Picker("Background", selection: $store.barStyle) {
                    ForEach(BarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.barStyle == .color {
                    ColorPicker("Colour", selection: $store.barColor, supportsOpacity: false)
                }
                if store.barStyle == .color || store.barStyle == .wallpaper {
                    Slider(value: $store.barOpacity, in: 0.15...1) { Text("Strength") }
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
                Slider(value: $store.barCornerRadius, in: 0...15) { Text("Corner rounding") }
            }

            Section("Date and time") {
                Toggle("Show the date", isOn: $store.barShowDate)
                Toggle("24-hour clock", isOn: $store.barUse24Hour)
            }

            Section {
                LabeledContent("Desktop shortcuts") {
                    HStack {
                        Text(store.desktopShortcutsOn ? "On" : "Off").foregroundStyle(.secondary)
                        Button("Open Keyboard Shortcuts…") { DesktopSwitcher.openShortcutSettings() }
                    }
                }
            } header: {
                Text("Desktops")
            } footer: {
                Text("The desktops match Mission Control, numbered across your screens. Click one to go there. To put an app on a desktop, go to it and open the app, or drag a window onto it in Mission Control. Right-click a desktop to give it a name. Going to an empty desktop needs \"Switch to Desktop\" turned on under Keyboard Shortcuts > Mission Control.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

private struct BehaviourTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Showing and hiding") {
                Picker("Position on screen", selection: $store.position) {
                    ForEach(DockEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Hide automatically, show at the screen edge", isOn: $store.autoHide)
                Toggle("Hide the macOS Dock", isOn: $store.hideSystemDock)
                Toggle("Open at login", isOn: $store.openAtLogin)
            }
            Section("What's in the dock") {
                Toggle("Pinned apps from the macOS Dock", isOn: $store.showPinned)
                Toggle("Trash", isOn: $store.showTrash)
                Toggle("Notification badges", isOn: $store.showBadges)
            }
            Section("Clicking and pointing") {
                Toggle("Window previews when pointing at an app", isOn: $store.showPreviews)
                Toggle("Scroll up on an icon to show its windows", isOn: $store.scrollToOpen)
                Toggle("Click the app you're using to hide it", isOn: $store.clickToHide)
            }
            Section {
                Text("⌘-click an icon to show the app in Finder. ⌥-click to switch to it and hide the app you were using. Drag icons sideways to reorder them. Right-click a divider line for quick settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Notification badges, bringing forward the exact window you click in a preview, closing windows from a preview, keeping windows out from under the dock and the top bar, and switching desktops and controlling music from the top bar.",
                    granted: store.hasAccessibility,
                    settingsPage: "Privacy_Accessibility")
                PermissionRow(
                    title: "Screen & System Audio Recording",
                    detail: "Window previews, and reading your wallpaper's colours.",
                    granted: store.hasScreenRecording,
                    settingsPage: "Privacy_ScreenCapture")
            } footer: {
                Text("Clear Dock never records or keeps what's on your screen. Pictures for previews are dropped as soon as the preview closes.")
                    .font(.caption).foregroundStyle(.secondary)
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

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Clear Dock").font(.title.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("Your apps, without the Dock's background.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit Clear Dock") { NSApp.terminate(nil) }
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
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

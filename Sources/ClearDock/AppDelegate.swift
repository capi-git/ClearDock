import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: DockController?
    private var topBar: TopBarController?
    private var statusItem: NSStatusItem?
    private var poweringOff = false
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        StallWatch.start()
        // Every call into another app through Accessibility gives up after half a second, rather
        // than the system's six, so an app that's busy or stuck can't freeze Clear Dock with it.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        DebugSnapshot.start()
        Settings.seedFromSystemDock()
        // With hiding turned off, put back anything left hidden when Clear Dock last stopped.
        if Settings.hideSystemDock { SystemDock.hide() } else { SystemDock.restore(waiting: false) }
        controller = DockController()
        topBar = TopBarController()
        SettingsWindowController.shared.onChange = { [weak self] area in
            switch area {
            case .dock: self?.controller?.settingsChanged()
            case .bar: self?.topBar?.settingsChanged()
            }
        }
        SettingsWindowController.shared.onOpenChanged = { [weak self] open in self?.controller?.keepVisible = open }
        NSApp.mainMenu = Self.makeMainMenu()
        askForPermissionsOnce()
        previewLog.notice("Clear Dock started; accessibility: \(AXIsProcessTrusted()); screen recording: \(CGPreflightScreenCaptureAccess())")
        setUpStatusItem()

        // Quit cleanly (and bring the macOS Dock back) if asked to stop from outside.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignal = source
    }

    /// Window previews and notification badges each need a macOS permission. Ask once, the first
    /// time this version runs; after that they can be turned on from the menu.
    private func askForPermissionsOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "askedForPermissions") else { return }
        defaults.set(true, forKey: "askedForPermissions")
        if Settings.showPreviews && !WindowCapture.hasPermission { WindowCapture.askForPermission() }
        if Settings.showBadges && !BadgeReader.hasPermission { BadgeReader.askForPermission() }
    }

    /// Opening Clear Dock again (from Applications, Spotlight or Launchpad) shows its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    /// The menu bar shown while the settings window is open.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Clear Dock", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(ActionMenuItem("Settings…", key: ",") { SettingsWindowController.shared.show() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clear Dock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }

    /// Notes whether this quit is part of shutting down, restarting or logging out. macOS says so in
    /// the request to quit itself, so a shutdown that another app called off earlier (to save a
    /// document, say) doesn't count when you quit Clear Dock later.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        let poweringOffReasons = [kAEShutDown, kAERestart, kAELogOut, kAEReallyLogOut].map { OSType($0) }
        poweringOff = reason.map { poweringOffReasons.contains($0.typeCodeValue) || poweringOffReasons.contains($0.enumCodeValue) } ?? false
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clear Dock sees to the Dock and menu bar itself from here.
        CrashGuard.standDown()
        // Windows lock-in puts back are still on their way (out of the Dock, say) for a moment;
        // restarting the macOS Dock below would stop them where they are.
        if topBar?.prepareForQuit() == true { Thread.sleep(forTimeInterval: 0.7) }
        // Across a restart, keep the macOS Dock hidden only if Clear Dock will reopen at login.
        if poweringOff && LoginItem.isEnabled { return }
        SystemDock.restore()
        SystemMenuBar.restore()
    }

    // MARK: Menu bar item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Clear Dock")
            ?? NSImage(systemSymbolName: "rectangle.bottomhalf.filled", accessibilityDescription: "Clear Dock")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        SettingsMenu.add(to: menu) { [weak self] in self?.controller?.settingsChanged() }
    }
}

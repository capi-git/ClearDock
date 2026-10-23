import AppKit

/// The settings shown both in the menu bar menu and when you right-click a divider line in the dock.
@MainActor
enum SettingsMenu {
    static func add(to menu: NSMenu, changed: @escaping @MainActor () -> Void) {
        menu.autoenablesItems = false

        menu.addItem(ActionMenuItem("Clear Dock Settings…", key: ",") { SettingsWindowController.shared.show() })
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem(Settings.autoHide ? "Turn Hiding Off" : "Turn Hiding On") {
            Settings.autoHide.toggle()
            changed()
        })
        menu.addItem(ActionMenuItem("Show pinned apps", checked: Settings.showPinned) {
            Settings.showPinned.toggle()
            changed()
        })
        menu.addItem(ActionMenuItem("Show Trash", checked: Settings.showTrash) {
            Settings.showTrash.toggle()
            changed()
        })
        let badgesOn = Settings.showBadges && BadgeReader.hasPermission
        menu.addItem(ActionMenuItem(BadgeReader.hasPermission ? "Show notification badges" : "Show notification badges…", checked: badgesOn) {
            if BadgeReader.hasPermission {
                Settings.showBadges.toggle()
            } else {
                // Counts come from the macOS Dock, which only shares them with apps allowed
                // under Privacy & Security > Accessibility.
                Settings.showBadges = true
                BadgeReader.askForPermission()
            }
            changed()
        })
        let previewsOn = Settings.showPreviews && WindowCapture.hasPermission
        menu.addItem(ActionMenuItem(WindowCapture.hasPermission ? "Show window previews" : "Show window previews…", checked: previewsOn) {
            if WindowCapture.hasPermission {
                Settings.showPreviews.toggle()
            } else {
                // Thumbnails need Privacy & Security > Screen & System Audio Recording.
                Settings.showPreviews = true
                WindowCapture.askForPermission()
                WindowCapture.openPermissionSettings()
            }
        })
        menu.addItem(ActionMenuItem("Scroll up on an icon to show its windows", checked: Settings.scrollToOpen) {
            Settings.scrollToOpen.toggle()
        })
        menu.addItem(ActionMenuItem("Click the front app to hide it", checked: Settings.clickToHide) {
            Settings.clickToHide.toggle()
        })

        let positionItem = NSMenuItem(title: "Position on Screen", action: nil, keyEquivalent: "")
        let positionMenu = NSMenu()
        for edge in DockEdge.allCases {
            positionMenu.addItem(ActionMenuItem(edge.title, checked: Settings.position == edge) {
                Settings.position = edge
                changed()
            })
        }
        positionItem.submenu = positionMenu
        menu.addItem(positionItem)

        let sizeItem = NSMenuItem(title: "Icon size", action: nil, keyEquivalent: "")
        let sizes: [(String, Double)] = [("Small", 32), ("Medium", 40), ("Large", 52), ("Extra large", 64)]
        let current = Settings.iconSize
        let closest = sizes.min { abs($0.1 - current) < abs($1.1 - current) }?.1
        let sizeMenu = NSMenu()
        for (title, size) in sizes {
            sizeMenu.addItem(ActionMenuItem(title, checked: size == closest) {
                Settings.iconSize = size
                changed()
            })
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Show the top bar", checked: BarSettings.enabled) {
            BarSettings.enabled.toggle()
            NotificationCenter.default.post(name: BarSettings.didChange, object: nil)
        })
        let replaceItem = ActionMenuItem("Top bar replaces the macOS menu bar", checked: BarSettings.replaceMenuBar) {
            BarSettings.replaceMenuBar.toggle()
            NotificationCenter.default.post(name: BarSettings.didChange, object: nil)
        }
        replaceItem.isEnabled = BarSettings.enabled
        menu.addItem(replaceItem)
        menu.addItem(ActionMenuItem("Hide the macOS Dock", checked: Settings.hideSystemDock) {
            Settings.hideSystemDock.toggle()
            if Settings.hideSystemDock { SystemDock.hide() } else { SystemDock.restore(waiting: false) }
            // The macOS Dock takes a moment to restart; then make room for it, or reclaim the space.
            changed()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { changed() }
            }
        })
        menu.addItem(ActionMenuItem("Open at login", checked: LoginItem.isEnabled) {
            do {
                try LoginItem.set(!LoginItem.isEnabled)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't change Open at login"
                alert.informativeText = error.localizedDescription
                NSApp.activate()
                alert.runModal()
            }
        })

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Quit Clear Dock", key: "q") {
            NSApp.terminate(nil)
        })
    }
}

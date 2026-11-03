import AppKit

/// The few everyday settings, shown both in the menu bar menu and when you right-click a divider
/// line in the dock, like the macOS Dock's own menu. The rest are in the settings window.
@MainActor
enum SettingsMenu {
    static func add(to menu: NSMenu, changed: @escaping @MainActor () -> Void) {
        menu.autoenablesItems = false

        menu.addItem(ActionMenuItem(Settings.autoHide ? "Turn Hiding Off" : "Turn Hiding On") {
            Settings.autoHide.toggle()
            changed()
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

        let sizeItem = NSMenuItem(title: "Icon Size", action: nil, keyEquivalent: "")
        let sizes: [(String, Double)] = [("Small", 32), ("Medium", 40), ("Large", 52), ("Extra Large", 64)]
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
        menu.addItem(ActionMenuItem("Clear Dock Settings…", key: ",") { SettingsWindowController.shared.show() })
        menu.addItem(ActionMenuItem("Quit Clear Dock", key: "q") {
            NSApp.terminate(nil)
        })
    }
}

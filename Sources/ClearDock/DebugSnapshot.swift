import AppKit
import ScreenCaptureKit

/// For checking how the bar and the dock look over the real desktop: with the `debug.snapshots`
/// setting on, the notification below makes Clear Dock save a picture of the strip along the top
/// and along the bottom of each screen (everything on screen there) to its temporary folder.
/// Nothing happens while the setting is off.
///
///     defaults write local.cleardock debug.snapshots -bool true
///     (post "local.cleardock.debug.snapshot" through the distributed notification center)
@MainActor
enum DebugSnapshot {
    static let request = Notification.Name("local.cleardock.debug.snapshot")

    static func start() {
        DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard UserDefaults.standard.bool(forKey: "debug.snapshots"), CGPreflightScreenCaptureAccess() else { return }
                Task { await take() }
            }
        }
    }

    /// A picture of the whole main screen, at half size, saved as `cleardock-<name>.png`.
    static func captureScreen(name: String) async {
        guard UserDefaults.standard.bool(forKey: "debug.snapshots"), let screen = NSScreen.main, let id = screen.displayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { return }
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width / 2)
        config.height = Int(screen.frame.height / 2)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cleardock-\(name).png"))
    }

    /// A picture of one of Clear Dock's own windows, saved as `cleardock-<name>.png`.
    static func capture(window number: Int, name: String) async {
        guard UserDefaults.standard.bool(forKey: "debug.snapshots"),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == CGWindowID(number) }) else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
        config.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cleardock-\(name).png"))
    }

    private static func take() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let strips = [("top", CGRect(x: 0, y: 0, width: screen.frame.width, height: 70)),
                          ("bottom", CGRect(x: 0, y: screen.frame.height - 140, width: screen.frame.width, height: 140))]
            for (name, rect) in strips {
                let config = SCStreamConfiguration()
                config.sourceRect = rect
                config.width = Int(rect.width * screen.backingScaleFactor)
                config.height = Int(rect.height * screen.backingScaleFactor)
                config.showsCursor = false
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
                try? data.write(to: folder.appendingPathComponent("cleardock-\(id)-\(name).png"))
            }
        }
    }
}

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

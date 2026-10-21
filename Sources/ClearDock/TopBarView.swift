import AppKit
import SwiftUI

/// One screen's bar: the left items, room in the middle for the notch or an island, and the
/// right items. Right-click anywhere on it for its settings.
struct TopBarView: View {
    @ObservedObject var model: TopBarModel
    let screenKey: String

    var body: some View {
        let layout = model.layouts[screenKey] ?? BarLayout()
        let side = max(0, (layout.width - 16 - layout.middleGap) / 2)
        HStack(spacing: 0) {
            row(.left, layout).frame(width: side, alignment: .leading)
            Spacer(minLength: 0)
            row(.right, layout).frame(width: side, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu { BarSettingsButton() }
    }

    private func row(_ side: BarSide, _ layout: BarLayout) -> some View {
        HStack(spacing: 6) {
            ForEach(model.items.filter { $0.side == side && $0.isOn }) { item in
                BarItemView(model: model, kind: item.kind, desktopsKey: layout.desktopsKey)
            }
        }
    }
}

private struct BarItemView: View {
    @ObservedObject var model: TopBarModel
    let kind: BarItemKind
    let desktopsKey: String

    var body: some View {
        switch kind {
        case .desktops: DesktopPills(model: model, key: desktopsKey)
        case .app: AppPill(model: model)
        case .song: if let track = model.track { SongPill(model: model, track: track) }
        case .volume: VolumePill(model: model)
        case .battery: if let percent = model.battery { BatteryPill(model: model, percent: percent) }
        case .clock: ClockPill(model: model)
        }
    }
}

// MARK: - Pieces

private struct DesktopPills: View {
    @ObservedObject var model: TopBarModel
    let key: String

    var body: some View {
        let look = model.look
        HStack(spacing: 6) {
            ForEach(model.desktops[key] ?? []) { desktop in
                let name = model.desktopNames[desktop.key]
                Pill(look: look, highlighted: desktop.isCurrent, action: { DesktopSwitcher.go(to: desktop) }) {
                    Text(name ?? "\(desktop.number)").font(look.font(.bold))
                    if desktop.apps.isEmpty {
                        if name == nil { Text("–").opacity(0.45) }
                    } else {
                        ForEach(desktop.apps.prefix(4), id: \.self) { pid in
                            if let icon = model.icon(for: pid) {
                                Image(nsImage: icon).resizable().frame(width: look.size.iconSize, height: look.size.iconSize)
                            }
                        }
                        if desktop.apps.count > 4 { Text("+\(desktop.apps.count - 4)").opacity(0.7) }
                    }
                }
                .contextMenu {
                    Button("Name Desktop \(desktop.number)…") { model.rename(desktop) }
                    if name != nil { Button("Show the Number Instead") { model.forget(desktop) } }
                    Divider()
                    Button("Hide Desktops") { model.hide(.desktops) }
                    BarSettingsButton()
                }
            }
        }
    }
}

private struct AppPill: View {
    @ObservedObject var model: TopBarModel

    var body: some View {
        let look = model.look
        // Clicking shows all of the app's windows (App Exposé).
        Pill(look: look, action: { CoreDock.send("com.apple.expose.front.awake") }) {
            if let icon = model.appIcon {
                Image(nsImage: icon).resizable().frame(width: look.size.iconSize, height: look.size.iconSize)
            }
            Text(model.appName)
        }
        .contextMenu {
            Button("Hide App in Front") { model.hide(.app) }
            BarSettingsButton()
        }
    }
}

private struct SongPill: View {
    @ObservedObject var model: TopBarModel
    let track: NowPlaying.Track

    var body: some View {
        let look = model.look
        Pill(look: look, action: { NowPlaying.playPause() }) {
            BarSymbol(name: track.isPlaying ? "music.note" : "pause.fill", look: look)
            Text(Self.shortened(track.title, to: 34))
            if !track.artist.isEmpty {
                Text(Self.shortened(track.artist, to: 22)).opacity(0.55)
            }
        }
        .opacity(track.isPlaying ? 1 : 0.8)
        .contextMenu {
            Button(track.isPlaying ? "Pause" : "Play") { NowPlaying.playPause() }
            Button("Next Song") { NowPlaying.next() }
            Button("Previous Song") { NowPlaying.previous() }
            Divider()
            Button(track.player == "com.spotify.client" ? "Open Spotify" : "Open Music") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: track.player) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            Divider()
            Button("Hide Song Playing") { model.hide(.song) }
            BarSettingsButton()
        }
    }

    /// Long titles are cut short so the song doesn't crowd out the rest of the bar.
    private static func shortened(_ text: String, to length: Int) -> String {
        text.count > length ? text.prefix(length - 1).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}

private struct VolumePill: View {
    @ObservedObject var model: TopBarModel

    var body: some View {
        let look = model.look
        let level = model.volume
        let symbol: String = if model.muted || level == 0 {
            "speaker.slash.fill"
        } else if let level {
            level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        } else {
            "speaker.wave.2.fill"
        }
        // Click to mute; scroll over it to change the volume.
        Pill(look: look, action: model.toggleMute) {
            BarSymbol(name: symbol, look: look, width: look.size.fontSize * 1.45)
            if let level {
                Text("\(Int((level * 100).rounded()))%").monospacedDigit().opacity(model.muted ? 0.5 : 1)
            }
        }
        .overlay { ScrollCatcher { model.changeVolume($0) } }
        .contextMenu {
            Button(model.muted ? "Unmute" : "Mute") { model.toggleMute() }
            Button("Sound Settings…") { SystemSettings.open("com.apple.Sound-Settings.extension") }
            Divider()
            Button("Hide Volume") { model.hide(.volume) }
            BarSettingsButton()
        }
    }
}

private struct BatteryPill: View {
    @ObservedObject var model: TopBarModel
    let percent: Int

    var body: some View {
        let look = model.look
        let symbol = model.charging ? "battery.100percent.bolt"
            : percent >= 88 ? "battery.100percent" : percent >= 63 ? "battery.75percent"
            : percent >= 38 ? "battery.50percent" : percent >= 13 ? "battery.25percent" : "battery.0percent"
        let low = percent < 20 && !model.pluggedIn
        Pill(look: look, action: { SystemSettings.open("com.apple.Battery-Settings.extension") }) {
            BarSymbol(name: symbol, look: look, color: low ? NSColor.systemRed : nil)
            Text("\(percent)%").monospacedDigit()
        }
        .contextMenu {
            Button("Hide Battery") { model.hide(.battery) }
            BarSettingsButton()
        }
    }
}

private struct ClockPill: View {
    @ObservedObject var model: TopBarModel

    var body: some View {
        let look = model.look
        Pill(look: look, action: {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }) {
            BarSymbol(name: "calendar", look: look)
            if look.showDate { Text(BarClock.date(model.now)) }
            Text(BarClock.time(model.now, twentyFourHour: look.use24Hour)).font(look.font(.bold)).monospacedDigit()
        }
        .contextMenu {
            Button("Hide Date and Time") { model.hide(.clock) }
            BarSettingsButton()
        }
    }
}

// MARK: - Building blocks

/// A rounded piece of the bar. Its background follows the bar's style; the current desktop is
/// filled with the highlight colour.
struct Pill<Content: View>: View {
    let look: BarLook
    var highlighted = false
    var action: (() -> Void)?
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous)
        let label = HStack(spacing: 5) { content }
            .font(look.font(.semibold))
            .foregroundStyle(highlighted ? look.onAccent : look.text)
            .lineLimit(1)
            .padding(.horizontal, (look.size.pillHeight * 0.4).rounded())
            .frame(height: look.size.pillHeight)
        Group {
            if look.style == .glass && !highlighted {
                label.glassEffect(.regular, in: shape)
            } else {
                label.background { PillBackground(look: look, highlighted: highlighted, shape: shape) }
            }
        }
        .overlay {
            if hovering && action != nil {
                shape.fill(Color.white.opacity(highlighted ? 0.14 : 0.08)).allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(look.style == .none ? 0.65 : 0.22), radius: look.style == .none ? 2 : 4, y: 1)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
    }
}

private struct PillBackground: View {
    let look: BarLook
    let highlighted: Bool
    let shape: RoundedRectangle

    var body: some View {
        if highlighted {
            shape.fill(Color(nsColor: look.accent).opacity(0.92))
                .overlay(shape.strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        } else if look.style == .none {
            Color.clear
        } else {
            // The wallpaper blurred, tinted with the bar's colour, like frosted glass.
            ZStack {
                BehindWindowBlur().clipShape(shape)
                shape.fill(Color(nsColor: look.fill).opacity(look.opacity))
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        }
    }
}

/// A symbol in the highlight colour, a little smaller than the text.
private struct BarSymbol: View {
    let name: String
    let look: BarLook
    var width: CGFloat?
    var color: NSColor?

    var body: some View {
        Image(systemName: name)
            .font(look.font(.bold, size: look.size.fontSize - 1))
            .foregroundStyle(Color(nsColor: color ?? look.accent))
            .frame(width: width)
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Catches scrolling over a piece of the bar, and lets clicks through to it.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (Float) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((Float) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) {
            // Up (as your fingers or the wheel move) is louder, whichever way scrolling is set.
            let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            guard delta != 0 else { return }
            let step: Float = event.hasPreciseScrollingDeltas ? Float(delta) * 0.004 : (delta > 0 ? 1 : -1) / 16
            onScroll?(step)
        }
    }
}

struct BarSettingsButton: View {
    var body: some View {
        Button("Top Bar Settings…") { SettingsWindowController.shared.show(tab: .topBar) }
    }
}

enum BarClock {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return formatter
    }()
    private static let twelveHour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
    private static let twentyFourHour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func date(_ date: Date) -> String { dateFormatter.string(from: date) }
    static func time(_ date: Date, twentyFourHour use24: Bool) -> String {
        (use24 ? twentyFourHour : twelveHour).string(from: date)
    }
}

enum SystemSettings {
    /// Opens a System Settings page by its identifier.
    static func open(_ page: String) {
        if let url = URL(string: "x-apple.systempreferences:\(page)") { NSWorkspace.shared.open(url) }
    }
}

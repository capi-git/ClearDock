import AppKit
import CoreAudio
import AudioToolbox
import IOKit.ps

// What the top bar shows, and where it comes from. Each source tells the bar when something
// changes; nothing here runs while the top bar is switched off.

// MARK: - Desktops

/// One desktop (Space) as Mission Control has it.
struct Desktop: Identifiable, Equatable {
    /// The window server's id for it.
    let id: UInt64
    /// Its number in Mission Control, counted across all displays (as the "Switch to Desktop"
    /// shortcuts count them).
    let number: Int
    /// Stays the same across restarts, so a name you give it sticks.
    let key: String
    let isCurrent: Bool
    /// How many places it is to the right of the desktop showing on its display (negative for
    /// left), counting full-screen apps, which sit between desktops. Nil when that's unknown.
    let stepsFromCurrent: Int?
    /// Apps with windows on it, front-most first.
    let apps: [pid_t]
    /// Its front-most window, which can be brought forward to go there.
    let frontWindow: CGWindowID?
    let frontApp: pid_t?
    /// Its windows, front-most first, for drawing a small picture of it.
    var windows: [DesktopWindow] = []
}

/// A window on a desktop, and where it is (in the system's window coordinates, measured from the
/// top-left of the main screen).
struct DesktopWindow: Identifiable, Equatable {
    let id: CGWindowID
    let app: pid_t
    let frame: CGRect
}

enum DesktopReader {
    /// The desktops on each display, keyed by the display's UUID, or "Main" when all displays
    /// share the same desktops.
    static func read() -> [String: [Desktop]] {
        let displays = WindowSpaces.displaySpaces()
        guard !displays.isEmpty else { return [:] }

        // Which desktop each app window is on. The list runs front to back.
        let me = getpid()
        let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var onDesktop: [UInt64: [DesktopWindow]] = [:]
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me, regular.contains(pid),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 80, rect.height >= 60
            else { continue }
            // Skip windows on every desktop, and ones that aren't on any.
            let spaces = WindowSpaces.spaceIDs(of: id)
            guard spaces.count == 1 else { continue }
            onDesktop[spaces[0], default: []].append(DesktopWindow(id: id, app: pid, frame: rect))
        }

        var number = 0
        var result: [String: [Desktop]] = [:]
        for display in displays {
            let displayID = display["Display Identifier"] as? String ?? "Main"
            let current = Self.id(display["Current Space"] as? [String: Any])
            let spaces = (display["Spaces"] as? [[String: Any]]) ?? []
            let currentPlace = spaces.firstIndex { Self.id($0) == current }
            var desktops: [Desktop] = []
            for (index, space) in spaces.enumerated() {
                // Type 0 is an ordinary desktop; full-screen apps have their own type.
                guard (space["type"] as? Int ?? 0) == 0, let id = Self.id(space) else { continue }
                number += 1
                let windows = onDesktop[id] ?? []
                var apps: [pid_t] = []
                for window in windows where !apps.contains(window.app) { apps.append(window.app) }
                let uuid = space["uuid"] as? String ?? ""
                desktops.append(Desktop(id: id, number: number, key: uuid.isEmpty ? "\(displayID)#\(index)" : uuid,
                                        isCurrent: id == current, stepsFromCurrent: currentPlace.map { index - $0 }, apps: apps,
                                        frontWindow: windows.first?.id, frontApp: windows.first?.app, windows: windows))
            }
            result[displayID] = desktops
        }
        return result
    }

    /// Displays showing a full-screen app right now, by UUID (or "Main" when displays share desktops).
    static func fullScreenDisplays() -> Set<String> {
        var result = Set<String>()
        for display in WindowSpaces.displaySpaces() {
            guard let current = display["Current Space"] as? [String: Any], (current["type"] as? Int ?? 0) != 0 else { continue }
            result.insert(display["Display Identifier"] as? String ?? "Main")
        }
        return result
    }

    private static func id(_ space: [String: Any]?) -> UInt64? {
        guard let space else { return nil }
        return ((space["id64"] ?? space["ManagedSpaceID"]) as? NSNumber)?.uint64Value
    }
}

/// Goes to a desktop. macOS has no way for apps to do this directly, so it presses macOS's own
/// keyboard shortcuts: "Switch to Desktop" when that's turned on, or otherwise "Move left a space"
/// or "Move right a space" (on unless you've turned them off) as many times as it takes. These act
/// on the display under the pointer, which is the one whose bar you clicked.
@MainActor
enum DesktopSwitcher {
    private typealias Shortcut = (key: CGKeyCode, flags: CGEventFlags)

    /// The shortcut with this hot key number, if it's on. `standard` is its usual keys, used when
    /// it has never been changed.
    private static func hotKey(_ id: Int, standard: Shortcut? = nil) -> Shortcut? {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
        guard let entry = all?[String(id)] as? [String: Any] else { return standard }
        guard (entry["enabled"] as? NSNumber)?.boolValue == true else { return nil }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { return standard }
        return (CGKeyCode(parameters[1].intValue), CGEventFlags(rawValue: UInt64(parameters[2].intValue)))
    }

    /// "Move left a space" (hot key 79) or "Move right a space" (81): Control and an arrow key.
    private static func moveShortcut(right: Bool) -> Shortcut? {
        let arrow: CGKeyCode = right ? 124 : 123
        guard let shortcut = hotKey(right ? 81 : 79, standard: (arrow, [.maskControl, .maskSecondaryFn])) else { return nil }
        // Arrow keys always carry these flags when pressed on a keyboard.
        return (shortcut.key, shortcut.flags.union([.maskSecondaryFn, .maskNumericPad]))
    }

    /// Presses a shortcut the way your hands would: holds its modifier keys, presses the key, and
    /// lets go of everything. Sending only the key with modifier flags attached leaves macOS
    /// thinking Control (or another modifier) is still held, which turns every click into a
    /// Control-click until you press it yourself.
    private static func press(_ shortcut: Shortcut) {
        let source = CGEventSource(stateID: .hidSystemState)
        let modifierKeys: [(key: CGKeyCode, flag: CGEventFlags)] = [
            (59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand),
        ].filter { shortcut.flags.contains($0.flag) }
        func modifiers(_ flags: CGEventFlags, _ key: CGKeyCode) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
            event?.type = .flagsChanged
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        var held: CGEventFlags = []
        for modifier in modifierKeys {
            held.insert(modifier.flag)
            modifiers(held, modifier.key)
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: down)
            event?.flags = shortcut.flags
            event?.post(tap: .cghidEventTap)
        }
        for modifier in modifierKeys.reversed() {
            held.remove(modifier.flag)
            modifiers(held, modifier.key)
        }
        // Arrow keys carry the Fn and keypad flags too; make sure nothing is left held.
        modifiers([], 63)
    }

    /// The "Switch to Desktop N" shortcut, if it's turned on in Keyboard Shortcuts > Mission Control.
    /// They're off unless you turn them on. Desktops 1 to 16 are hot keys 118 to 133.
    private static func shortcut(for number: Int) -> Shortcut? {
        guard (1...16).contains(number) else { return nil }
        return hotKey(117 + number)
    }

    /// Whether the bar can switch desktops at all.
    static var canSwitch: Bool { shortcut(for: 1) != nil || moveShortcut(right: true) != nil }

    static func go(to desktop: Desktop) {
        guard !desktop.isCurrent else { return }
        if switchTo(desktop) { return }
        if let window = desktop.frontWindow, let app = desktop.frontApp {
            WindowFocus.raise(window, of: app)
            return
        }
        if explained {
            NSSound.beep()
        } else {
            explained = true
            explainShortcuts()
        }
    }

    /// Presses macOS's shortcut for going to the desktop. False when none of them is on, or
    /// Accessibility (which pressing them needs) isn't allowed.
    @discardableResult
    static func switchTo(_ desktop: Desktop) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if let shortcut = shortcut(for: desktop.number) {
            press(shortcut)
            return true
        }
        guard let steps = desktop.stepsFromCurrent, steps != 0, let move = moveShortcut(right: steps > 0) else { return false }
        // A short pause between presses lets macOS take each one.
        for step in 0..<abs(steps) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(step)) {
                MainActor.assumeIsolated { press(move) }
            }
        }
        return true
    }

    /// The explanation shows once each time Clear Dock opens; after that a click just beeps.
    private static var explained = false

    static func openShortcutSettings() {
        for page in ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts",
                     "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"] {
            if let url = URL(string: page), NSWorkspace.shared.open(url) { return }
        }
    }

    private static func explainShortcuts() {
        let previous = NSWorkspace.shared.frontmostApplication
        let alert = NSAlert()
        alert.messageText = "Turn on the desktop shortcuts to switch desktops from the bar"
        alert.informativeText = """
            macOS only lets other apps switch desktops through its own keyboard shortcuts, and they're \
            turned off. In System Settings, open Keyboard > Keyboard Shortcuts > Mission Control and turn on \
            "Move left a space" and "Move right a space", or "Switch to Desktop 1", "Switch to Desktop 2" \
            and so on.
            """
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            openShortcutSettings()
        } else {
            previous?.activate()
        }
    }
}

// MARK: - Song playing

/// The song playing in Spotify or Apple Music. Both announce every change to any app that
/// listens, which needs no permission. Asking for the album cover and the playing position, and
/// controlling the player, goes through AppleScript; macOS asks you once to allow that.
@MainActor
final class NowPlaying {
    struct Track: Equatable {
        var title: String
        var artist: String
        var album = ""
        var isPlaying: Bool
        /// The player's bundle identifier.
        var player: String
        /// The song's length, and how far in it was at `positionDate`, in seconds.
        var duration: Double?
        var position: Double?
        var positionDate = Date()

        /// Seconds into the song now.
        var elapsed: Double? {
            guard let position else { return nil }
            let played = position + (isPlaying ? Date().timeIntervalSince(positionDate) : 0)
            return duration.map { min(played, $0) } ?? played
        }

        /// The same song, whatever its state.
        func isSameSong(as other: Track?) -> Bool {
            other?.title == title && other?.artist == artist && other?.player == player
        }
    }

    private(set) var track: Track?
    /// The current song's album cover, once it has loaded.
    private(set) var artwork: NSImage?
    var onChange: () -> Void = {}
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var artworkFor: Track?

    private static let players = [
        ("com.spotify.client.PlaybackStateChanged", "com.spotify.client"),
        ("com.apple.Music.playerInfo", "com.apple.Music"),
    ]

    func start() {
        guard tokens.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        for (name, player) in Self.players {
            let token = distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                let state = info["Player State"] as? String ?? ""
                var track = Track(title: info["Name"] as? String ?? "", artist: info["Artist"] as? String ?? "",
                                  album: info["Album"] as? String ?? "", isPlaying: state == "Playing", player: player)
                // Spotify gives the length in milliseconds and the position in seconds; Music the length only.
                let length = (info["Duration"] ?? info["Total Time"]) as? NSNumber
                track.duration = length.map { $0.doubleValue / 1000 }
                track.position = (info["Playback Position"] as? NSNumber)?.doubleValue
                MainActor.assumeIsolated { self?.update(state: state, track: track) }
            }
            tokens.append((distributed, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let quit = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, self.track?.player == id else { return }
                self.track = nil
                self.artwork = nil
                self.onChange()
            }
        }
        tokens.append((workspace, quit))
        askPlayers()
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        track = nil
        artwork = nil
        artworkFor = nil
    }

    /// Spotify and Music only announce changes, so when the bar starts, ask whichever is open
    /// what it's playing now.
    private func askPlayers() {
        for (_, player) in Self.players where Self.isOpen(player) {
            let script = """
                tell application id "\(player)"
                    set playerState to player state as text
                    if playerState is "stopped" then return playerState
                    return playerState & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & (album of current track)
                end tell
                """
            Self.run(script) { [weak self] text in
                let lines = (text ?? "").components(separatedBy: "\n")
                // Don't override a change the player announced in the meantime.
                guard let self, self.track == nil, lines.count >= 2 else { return }
                let state = lines[0] == "playing" ? "Playing" : lines[0] == "paused" ? "Paused" : "Stopped"
                let track = Track(title: lines[1], artist: lines.count > 2 ? lines[2] : "", album: lines.count > 3 ? lines[3] : "",
                                  isPlaying: state == "Playing", player: player)
                self.update(state: state, track: track)
                self.refreshPosition()
            }
        }
    }

    private func update(state: String, track new: Track) {
        let next = state == "Stopped" || new.title.isEmpty ? nil : new
        // A player that pauses or stops shouldn't replace a different one that's still playing.
        if let current = track, current.player != new.player, current.isPlaying, next?.isPlaying != true { return }
        var merged = next
        // Keep what's known about the song (its length and position) when an update leaves it out.
        if var song = merged, let current = track, song.isSameSong(as: current) {
            song.duration = song.duration ?? current.duration
            if song.position == nil, let elapsed = current.elapsed { song.position = elapsed }
            merged = song
        }
        guard merged != track else { return }
        track = merged
        if let song = merged, !song.isSameSong(as: artworkFor) {
            artworkFor = song
            artwork = nil
            loadArtwork(for: song)
        } else if merged == nil {
            artwork = nil
            artworkFor = nil
        }
        onChange()
    }

    /// Whether the player is open. Asking a player that isn't would open it.
    private static func isOpen(_ player: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player).isEmpty
    }

    /// Asks the player how far into the song it is, for the progress bar.
    func refreshPosition() {
        guard let song = track, Self.isOpen(song.player) else { return }
        // Spotify gives the length in milliseconds, Music in seconds.
        let length = song.player == "com.spotify.client" ? "(duration of current track) / 1000" : "duration of current track"
        let script = """
            tell application id "\(song.player)" to return (player position as text) & linefeed & ((\(length)) as text)
            """
        Self.run(script) { [weak self] text in
            let parts = (text ?? "").components(separatedBy: "\n").map { Double($0.replacingOccurrences(of: ",", with: ".")) }
            guard let self, var current = self.track, current.isSameSong(as: song), let position = parts.first ?? nil else { return }
            current.position = position
            current.positionDate = Date()
            if parts.count > 1, let length = parts[1] { current.duration = length }
            self.track = current
            self.onChange()
        }
    }

    /// Loads the album cover: Spotify gives a web address for it, Music the picture itself.
    private func loadArtwork(for song: Track) {
        guard BarSettings.albumColours || BarSettings.miniPlayer, Self.isOpen(song.player) else { return }
        if song.player == "com.spotify.client" {
            Self.run("tell application id \"com.spotify.client\" to return artwork url of current track") { [weak self] text in
                guard let text, let url = URL(string: text), url.scheme == "https" else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.setArtwork(NSImage(data: data), for: song) }
                    }
                }.resume()
            }
        } else {
            // A file of its own each time, so covers asked for close together can't mix.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("cleardock-artwork-\(UUID().uuidString)").path
            let script = """
                tell application id "com.apple.Music" to set picture to raw data of artwork 1 of current track
                set output to open for access (POSIX file "\(file)") with write permission
                set eof output to 0
                write picture to output
                close access output
                return "\(file)"
                """
            Self.run(script) { [weak self] text in
                defer { try? FileManager.default.removeItem(atPath: file) }
                guard let text else { return }
                self?.setArtwork(NSImage(contentsOfFile: text), for: song)
            }
        }
    }

    private func setArtwork(_ image: NSImage?, for song: Track) {
        guard let image, song.isSameSong(as: track) else { return }
        artwork = image
        onChange()
    }

    // MARK: Controlling the player

    /// Play or pause, the next song, the previous song. Sent to Spotify or Music directly
    /// (which works even while a game has the keyboard), or as a media key otherwise.
    func playPause() { send("playpause", mediaKey: 16) }
    func next() { send("next track", mediaKey: 17) }
    func previous() { send("previous track", mediaKey: 18) }

    /// Jumps to a point in the song, in seconds.
    func seek(to seconds: Double) {
        guard var song = track, Self.isOpen(song.player) else { return }
        Self.run("tell application id \"\(song.player)\" to set player position to \(seconds)") { _ in }
        song.position = seconds
        song.positionDate = Date()
        track = song
        onChange()
    }

    private func send(_ command: String, mediaKey: Int) {
        guard let player = track?.player, Self.isOpen(player) else { return Self.mediaKey(mediaKey) }
        Self.run("tell application id \"\(player)\" to \(command)") { _ in }
    }

    /// Presses one of the keyboard's media keys.
    private static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data = (key << 16) | ((down ? 0xA : 0xB) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Runs an AppleScript separately, so the bar keeps working while it runs (or while macOS asks
    /// for permission), and hands back what it returned, or nil if it failed.
    private static func run(_ script: String, then handler: @escaping @MainActor (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = finished.terminationStatus == 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler(ok ? text : nil) }
            }
        }
        do { try process.run() } catch { handler(nil) }
    }
}

// MARK: - Volume

/// The volume of the sound output in use, kept up to date as it changes or you switch outputs.
@MainActor
final class SystemVolume {
    /// From 0 to 1, or nil when the output's volume can't be set (some displays and HDMI outputs).
    private(set) var level: Float?
    private(set) var muted = false
    var onChange: () -> Void = {}

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var running = false
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var valueListener: AudioObjectPropertyListenerBlock?

    private static let outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static let watched = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute]

    func start() {
        guard !running else { return }
        running = true
        let deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attach() }
        }
        self.deviceListener = deviceListener
        var address = Self.outputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
        valueListener = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.read() }
        }
        attach()
    }

    func stop() {
        guard running else { return }
        running = false
        detach()
        if let deviceListener {
            var address = Self.outputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
        }
        deviceListener = nil
        valueListener = nil
    }

    /// Follows the output in use, listening for its volume and mute changes.
    private func attach() {
        detach()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.outputAddress
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        device = id
        if let valueListener, device != kAudioObjectUnknown {
            for selector in Self.watched {
                var address = Self.address(selector)
                if AudioObjectHasProperty(device, &address) {
                    AudioObjectAddPropertyListenerBlock(device, &address, .main, valueListener)
                }
            }
        }
        read()
    }

    private func detach() {
        guard device != kAudioObjectUnknown, let valueListener else { return }
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, valueListener)
        }
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func read() {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        if device != kAudioObjectUnknown, AudioObjectHasProperty(device, &address),
           AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue {
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            level = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
        } else {
            level = nil
        }
        var muteAddress = Self.address(kAudioDevicePropertyMute)
        var mute = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        muted = device != kAudioObjectUnknown && AudioObjectHasProperty(device, &muteAddress)
            && AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &mute) == noErr && mute != 0
        onChange()
    }

    /// Sets the volume (0 to 1), turning mute off when it goes up.
    func set(_ value: Float) {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard level != nil else { return }
        var volume = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        if muted && volume > 0 { setMuted(false) }
    }

    func toggleMute() { setMuted(!muted) }

    private func setMuted(_ on: Bool) {
        var address = Self.address(kAudioDevicePropertyMute)
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &address) else { return }
        var value = UInt32(on ? 1 : 0)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// MARK: - Battery

/// The built-in battery's charge. The system says when it changes; Macs without a battery show nothing.
@MainActor
final class BatteryStatus {
    private(set) var percent: Int?
    private(set) var charging = false
    private(set) var pluggedIn = false
    var onChange: () -> Void = {}
    private var source: CFRunLoopSource?

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let status = Unmanaged<BatteryStatus>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { status.read() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        read()
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    private func read() {
        defer { onChange() }
        percent = nil
        charging = false
        pluggedIn = false
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = details[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = details[kIOPSMaxCapacityKey] as? Int ?? 100
            percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : nil
            charging = details[kIOPSIsChargingKey] as? Bool ?? false
            pluggedIn = details[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return
        }
    }
}

import Foundation
import Darwin
import Synchronization
import os

/// Notes about moments Clear Dock was too busy to draw, readable with:
/// log show --predicate 'subsystem == "local.cleardock" AND category == "timing"'
let timingLog = Logger(subsystem: "local.cleardock", category: "timing")

/// Watches for the main thread staying busy long enough to drop frames (a stall), and notes how
/// long it lasted and what it was doing then, so a stutter can be traced to its cause. It costs
/// nothing while Clear Dock is idle: the watcher only wakes while the main thread is working.
enum StallWatch {
    /// Busy this long without a break counts as a stall: about three frames.
    private static let threshold: UInt64 = 50_000_000
    /// When the main thread's current stretch of work began, in nanoseconds of uptime, or 0
    /// while it waits for something to do.
    private static let workStarted = Atomic<UInt64>(0)
    /// Whether the watcher is already watching this stretch of work.
    private static let armed = Atomic<Bool>(false)
    private static let wake = DispatchSemaphore(value: 0)
    /// What the main thread was seen doing, and during which stretch of work.
    private static let seen = Mutex<(started: UInt64, text: String)?>(nil)
    nonisolated(unsafe) private static var mainThread: thread_act_t = 0

    static func start() {
        mainThread = mach_thread_self()
        // Touched here first, so the watcher never sets them up while the main thread is paused.
        _ = workStarted.load(ordering: .relaxed)
        _ = armed.load(ordering: .relaxed)
        _ = seen.withLock { $0 }
        _ = demangle

        // Every step of the main run loop marks progress; a long gap between two is a stall.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, activity in
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let started = workStarted.load(ordering: .relaxed)
            if started != 0, now - started > threshold { report((now - started) / 1_000_000, started: started) }
            if activity == .beforeWaiting {
                workStarted.store(0, ordering: .relaxed)
            } else {
                workStarted.store(now, ordering: .relaxed)
                if activity == .afterWaiting, !armed.exchange(true, ordering: .relaxed) { wake.signal() }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)

        let watcher = Thread { watch() }
        watcher.name = "Clear Dock stall watch"
        // Lower priorities let macOS put off its short sleeps, so it would only look once a stall is over.
        watcher.qualityOfService = .userInteractive
        watcher.start()
    }

    private static func report(_ milliseconds: UInt64, started: UInt64) {
        let doing = seen.withLock { value -> String? in
            defer { value = nil }
            return value?.started == started ? value?.text : nil
        }
        timingLog.notice("Stall: busy \(milliseconds) ms; doing: \(doing ?? "not caught", privacy: .public)")
    }

    // MARK: The watcher

    private static func watch() {
        let capacity = 64
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
        var caught: UInt64 = 0
        while true {
            wake.wait()
            while true {
                usleep(30_000)
                let started = workStarted.load(ordering: .relaxed)
                if started == 0 {
                    armed.store(false, ordering: .relaxed)
                    // The main thread may have woken again just now, before `armed` was cleared.
                    if workStarted.load(ordering: .relaxed) != 0, !armed.exchange(true, ordering: .relaxed) { continue }
                    break
                }
                guard started != caught, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started > threshold else { continue }
                caught = started
                let count = sampleMainThread(into: frames, capacity: capacity)
                let text = describe(frames, count)
                seen.withLock { $0 = (caught, text) }
            }
        }
    }

    /// The return addresses on the main thread's stack, innermost first. The thread is paused
    /// meanwhile, so nothing here may allocate memory or take a lock it could be holding.
    private static func sampleMainThread(into frames: UnsafeMutablePointer<UInt>, capacity: Int) -> Int {
        let thread = mainThread
        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(thread) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // Return addresses can carry a pointer signature in their top bits.
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF
        var n = 0
        frames[n] = UInt(state.__pc) & mask; n += 1
        frames[n] = UInt(state.__lr) & mask; n += 1
        var frame = UInt(state.__fp)
        var record: (next: UInt, returnAddress: UInt) = (0, 0)
        while frame != 0, n < capacity {
            var read: vm_size_t = 0
            let ok = withUnsafeMutablePointer(to: &record) {
                vm_read_overwrite(mach_task_self_, vm_address_t(frame), vm_size_t(16), vm_address_t(UInt(bitPattern: $0)), &read)
            }
            guard ok == KERN_SUCCESS, read == 16, record.returnAddress != 0 else { break }
            frames[n] = record.returnAddress & mask; n += 1
            // The stack grows down, so each caller's frame is higher up.
            guard record.next > frame else { break }
            frame = record.next
        }
        return n
    }

    /// The innermost system calls (where it was waiting, and what in macOS got it there, with the
    /// part of macOS each is in) and Clear Dock's own functions.
    private static func describe(_ frames: UnsafeMutablePointer<UInt>, _ count: Int) -> String {
        var inner: [String] = []
        var ours: [String] = []
        for i in 0..<count {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: frames[i]), &info) != 0, let symbol = info.dli_sname else { continue }
            let image = info.dli_fname.map { String(cString: $0) } ?? ""
            let name = readable(symbol)
            // Glue the compiler adds between functions says nothing about what was going on.
            if name.contains("thunk") { continue }
            if image.hasSuffix("/ClearDock") {
                if ours.last != name { ours.append(name) }
                if ours.count == 8 { break }
            } else if ours.isEmpty, inner.count < 6 {
                let library = image.split(separator: "/").last.map(String.init) ?? "?"
                let entry = "\(name) [\(library)]"
                if inner.last != entry { inner.append(entry) }
            }
        }
        return (inner + ours).joined(separator: " ← ")
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private static let demangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
        .map { unsafeBitCast($0, to: Demangle.self) }

    private static func readable(_ symbol: UnsafePointer<CChar>) -> String {
        guard let demangle, let plain = demangle(symbol, strlen(symbol), nil, nil, 0) else { return String(cString: symbol) }
        defer { free(plain) }
        var name = String(cString: plain)
        for noise in ["ClearDock.", " in ClearDock", "specialized ", "partial apply for ", "@objc "] {
            name = name.replacingOccurrences(of: noise, with: "")
        }
        // Drop argument lists, which make the names long without saying much more.
        if let open = name.firstIndex(of: "("), !name.hasPrefix("closure") { name = String(name[..<open]) + "()" }
        return name
    }
}

import AppKit
import os

/// "Restart if stuck": a small shell process waits for Nook to end and opens
/// it again unless it quit cleanly; a background check ends Nook when its main
/// thread stops answering, so the watcher can bring it back.
@MainActor
enum Watchdog {
    private static var watcher: Process?
    private static var checker: DispatchSourceTimer?
    private static var beat: Timer?
    private nonisolated static let lastBeat = OSAllocatedUnfairLock(initialState: DispatchTime.now().uptimeNanoseconds)
    /// Seconds of main-thread silence that count as stuck. Uptime only: sleep doesn't count.
    nonisolated static let limit: UInt64 = 20

    /// Present when Nook ended on purpose; the watcher then leaves it closed.
    static let cleanExitFlag = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dev.mithun.nook.clean-exit-\(getpid())")

    static func apply(_ on: Bool) {
        on ? start() : stop()
    }

    private static func start() {
        guard watcher == nil else { return }
        try? FileManager.default.removeItem(at: cleanExitFlag)
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 2; done
        if [ ! -e "$3" ]; then sleep 1; /usr/bin/open "$2"; fi
        rm -f "$3"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "nook-watchdog", "\(getpid())", Bundle.main.bundlePath, cleanExitFlag.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        watcher = p

        lastBeat.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            lastBeat.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        }
        // Common modes: keeps beating while a menu is tracking or an Open panel is up.
        RunLoop.main.add(timer, forMode: .common)
        beat = timer
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler {
            let silent = (DispatchTime.now().uptimeNanoseconds - lastBeat.withLock { $0 }) / 1_000_000_000
            // Stuck: end now, without the clean-exit flag, so the watcher reopens Nook.
            if silent > limit { _exit(3) }
        }
        t.resume()
        checker = t
    }

    private static func stop() {
        markCleanExit()
        watcher?.terminate()
        watcher = nil
        checker?.cancel()
        checker = nil
        beat?.invalidate()
        beat = nil
    }

    static func markCleanExit() {
        FileManager.default.createFile(atPath: cleanExitFlag.path, contents: nil)
    }
}

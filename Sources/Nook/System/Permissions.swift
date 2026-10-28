import AppKit
import ServiceManagement

/// macOS ties an Accessibility grant to the exact build it was made for. After
/// an update to an unsigned or ad-hoc-signed build, the switch in System
/// Settings still shows on, but belongs to the old build. Re-adding Nook clears
/// that stale entry and asks again for this build.
@MainActor
enum Permissions {
    private static let resetFlag = "permissionsJustReset"

    static func reset() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let tcc = Process()
        tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tcc.arguments = ["reset", "Accessibility", id]
        try? tcc.run()
        tcc.waitUntilExit()
        UserDefaults.standard.set(true, forKey: resetFlag)
        relaunch()
    }

    /// Called at launch. Asks macOS for access when that's clearly expected:
    /// right after a reset, or when a set-up Nook has lost access. A first run
    /// asks from the welcome tour instead, after explaining why.
    static func askIfExpected() {
        guard !AX.isTrusted else { return }
        let justReset = UserDefaults.standard.bool(forKey: resetFlag)
        UserDefaults.standard.removeObject(forKey: resetFlag)
        if justReset || Preferences.shared.setupComplete {
            AX.prompt()
            if justReset { AX.openSettings() }
        }
    }

    /// Quits, then opens again once this copy is gone (only one Nook runs at a time).
    private static func relaunch() {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; open \"$0\"", Bundle.main.bundlePath]
        try? sh.run()
        NSApp.terminate(nil)
    }
}

enum LoginItem {
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Nook: login item change failed: \(error)")
        }
    }
}

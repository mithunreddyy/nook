import AppKit
import Darwin

/// Things outside Nook that fight it for windows: other window managers and
/// macOS's own edge tiling.
enum SetupCheck {
    struct Issue: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String
        /// A System Settings page that fixes it, if there is one.
        var settingsURL: URL?
    }

    /// Apps with a bundle, by bundle ID.
    static let managerApps: [String: String] = [
        "com.knollsoft.Rectangle": "Rectangle",
        "com.knollsoft.Hookshot": "Hookshot",
        "com.crowdcafe.windowmagnet": "Magnet",
        "com.amethyst.Amethyst": "Amethyst",
        "bobko.aerospace": "AeroSpace",
        "com.manytricks.Moom": "Moom",
        "com.hegenberg.BetterSnapTool": "BetterSnapTool",
        "com.mizage.Divvy": "Divvy",
        "com.MrKai77.Loop": "Loop",
    ]

    /// Command-line managers with no bundle, by process name.
    static let managerProcesses: [String: String] = ["yabai": "yabai"]

    static let desktopSettings = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")

    static func issues() -> [Issue] {
        var out: [Issue] = []
        var seen = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, let name = managerApps[id], seen.insert(name).inserted else { continue }
            out.append(Issue(id: "app-\(name)", title: "\(name) is running",
                             detail: "Two window managers move the same windows. Quit \(name) or turn off its shortcuts and snapping."))
        }
        for name in runningProcessNames().compactMap({ managerProcesses[$0] }) where seen.insert(name).inserted {
            out.append(Issue(id: "app-\(name)", title: "\(name) is running",
                             detail: "Two window managers move the same windows. Stop \(name) while you use Nook."))
        }
        if edgeTilingOn {
            out.append(Issue(id: "edge-tiling", title: "macOS tiles windows dragged to screen edges",
                             detail: "Dragging a window near an edge can resize it behind Nook's back. Turn off “Drag windows to screen edges to tile” in Desktop & Dock.",
                             settingsURL: desktopSettings))
        }
        if StageManager.isOn {
            out.append(Issue(id: "stage-manager", title: "Stage Manager is on",
                             detail: "Nook pauses while Stage Manager is on.", settingsURL: desktopSettings))
        }
        return out
    }

    /// Other window managers only: the ones worth a notice at launch.
    static func runningManagers() -> [String] {
        issues().filter { $0.id.hasPrefix("app-") }.map { String($0.id.dropFirst(4)) }
    }

    /// macOS 15's "Drag windows to screen edges to tile" (on unless turned off).
    static var edgeTilingOn: Bool {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("EnableTilingByEdgeDrag" as CFString, domain) as? Bool) ?? true
    }

    private static func runningProcessNames() -> Set<String> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        var names = Set<String>()
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { names.insert(String(cString: buffer)) }
        }
        return names
    }
}

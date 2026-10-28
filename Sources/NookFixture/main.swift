import AppKit

// A test app for scripts/e2e.swift: opens and closes ordinary windows on command.
// Bundled as NookFixture.app and NookFixtureBig.app; the Big one's windows
// refuse to get smaller than 900 × 650, like a heavy IDE.

final class Fixture: NSObject, NSApplicationDelegate {
    let id = Bundle.main.bundleIdentifier ?? "dev.mithun.nook.fixture"
    var big: Bool { id.hasSuffix(".big") }
    var windows: [NSWindow] = []
    var count = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(command(_:)), name: .init(id), object: nil)
        let n = Int(UserDefaults.standard.string(forKey: "open") ?? "") ?? 0
        for _ in 0..<n { open(nil) }
    }

    @objc func command(_ note: Notification) {
        let info = note.userInfo as? [String: String] ?? [:]
        // Notifications can arrive off the main thread's turn; hop on.
        DispatchQueue.main.async { [self] in
            switch info["cmd"] {
            case "open": open(info["title"])
            case "close": windows.first { $0.title == info["title"] }?.close()
            // Closes the way many apps do: the window object stays alive, just off screen.
            case "hide": windows.first { $0.title == info["title"] }?.orderOut(nil)
            case "closeAll": windows.forEach { $0.close() }
            case "dialog": dialog(info["title"] ?? "Panel")
            case "minimize": windows.first { $0.title == info["title"] }?.miniaturize(nil)
            case "quit": NSApp.terminate(nil)
            default: break
            }
        }
    }

    func open(_ title: String?) {
        count += 1
        let w = NSWindow(contentRect: NSRect(x: 120 + count * 30, y: 200 + count * 20, width: 520, height: 360),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = title ?? "\(big ? "Big" : "Fixture") \(count)"
        w.isReleasedWhenClosed = false
        if big { w.contentMinSize = NSSize(width: 900, height: 650) }
        let label = NSTextField(labelWithString: w.title)
        label.font = .monospacedSystemFont(ofSize: 28, weight: .bold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(label)
        label.centerXAnchor.constraint(equalTo: w.contentView!.centerXAnchor).isActive = true
        label.centerYAnchor.constraint(equalTo: w.contentView!.centerYAnchor).isActive = true
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.windows.removeAll { $0 === w }
        }
        w.makeKeyAndOrderFront(nil)
    }

    func dialog(_ title: String) {
        let p = NSPanel(contentRect: NSRect(x: 300, y: 300, width: 300, height: 160),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        p.title = title
        p.isReleasedWhenClosed = false
        p.orderFront(nil)
        windows.append(p)
    }
}

let app = NSApplication.shared
let fixture = Fixture()
app.delegate = fixture
app.setActivationPolicy(.regular)
app.run()

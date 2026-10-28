import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Another Nook is already running: this copy only passes on what it was opened for.
    private var isDuplicate = false
    private static let forwardedURL = Notification.Name("dev.mithun.nook.url")

    func applicationWillFinishLaunching(_ notification: Notification) {
        isDuplicate = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != getpid() }
        // Registered before launch finishes, so a URL that launched this copy isn't missed.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one Nook at a time. Give a URL that opened this copy a moment to arrive and be passed on.
        if isDuplicate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.forwardedURL, object: nil, queue: .main) { [weak self] n in
            guard let s = n.object as? String, let url = URL(string: s) else { return }
            MainActor.assumeIsolated { self?.open(url) }
        }

        installMainMenu()
        StatusItem.shared = StatusItem()
        if Preferences.shared.iconStyle != .graphite { AppIcon.apply(Preferences.shared.iconStyle) }

        let engine = Engine.shared
        engine.boot()
        Mouse.shared.start()

        Permissions.askIfExpected()
        if !Preferences.shared.setupComplete || !AX.isTrusted {
            Tour.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.hotkeys.unregisterAll()
        Visuals.shared.hideAll()
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        if isDuplicate {
            DistributedNotificationCenter.default().postNotificationName(Self.forwardedURL, object: s, userInfo: nil, deliverImmediately: true)
            return
        }
        open(url)
    }

    private func open(_ url: URL) {
        if url.host == "debug" {
            Debug.handle(url)
            return
        }
        if url.host == "settings" {
            SettingsWindow.shared.show()
            return
        }
        guard let command = Command(url: url) else {
            NSLog("Nook: unknown URL \(url)")
            return
        }
        Engine.shared.run(command, from: .script)
    }

    /// Standard edit commands so text fields in Settings get ⌘C/⌘V, plus ⌘W and ⌘Q.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Nook", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Automatic tiling for macOS.\nNothing leaves your Mac.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }
}

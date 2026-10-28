import AppKit
import ApplicationServices

enum WindowEvent {
    case created(AXUIElement)
    case destroyed(AXUIElement)
    case minimized(AXUIElement)
    case restored(AXUIElement)
    case moved(AXUIElement)
    case resized(AXUIElement)
    case titleChanged(AXUIElement)
    case focusChanged(pid_t)
    case appHidden(pid_t)
    case appShown(pid_t)
}

@MainActor
protocol WindowTrackerDelegate: AnyObject {
    func tracker(_ event: WindowEvent, pid: pid_t)
    func trackerAppLaunched(_ app: NSRunningApplication)
    func trackerAppTerminated(_ pid: pid_t)
    func trackerAppActivated(_ pid: pid_t)
    func trackerSpaceChanged()
}

/// Watches every regular app through the Accessibility API and reports window
/// lifecycle events. Holds no window state of its own.
@MainActor
final class WindowTracker {
    weak var delegate: WindowTrackerDelegate?

    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []

    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]

    static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
    ]

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        tokens.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.launched(app) }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.observers[app.processIdentifier] = nil
                self?.delegate?.trackerAppTerminated(app.processIdentifier)
            }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.delegate?.trackerAppActivated(app.processIdentifier) }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.delegate?.trackerSpaceChanged() }
        })
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app)
        }
    }

    func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
        for (_, o) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        }
        observers.removeAll()
    }

    var observedPIDs: [pid_t] { Array(observers.keys) }

    private func launched(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        observe(app)
        delegate?.trackerAppLaunched(app)
        // Windows can open before we're listening; pick them up.
        let pid = app.processIdentifier
        for delay in [0.15, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.observers[pid] != nil else { return }
                for w in AXUIElementCreateApplication(pid).windows { self.delegate?.tracker(.created(w), pid: pid) }
            }
        }
    }

    /// Starts observing an app. Apps that are still launching may refuse; retry a few times.
    func observe(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard pid != getpid(), observers[pid] == nil, !app.isTerminated else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, trackerCallback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var ok = false
        for name in Self.appNotifications {
            if AXObserverAddNotification(observer, element, name as CFString, refcon) == .success { ok = true }
        }
        guard ok else {
            if attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(attempt + 1)) { [weak self] in
                    self?.observe(app, attempt: attempt + 1)
                }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        if attempt > 0 {
            // Windows may have opened while we waited.
            for w in element.windows { delegate?.tracker(.created(w), pid: pid) }
        }
    }

    /// Subscribes to a window's own notifications once it's managed.
    func watch(window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
    }

    func unwatch(window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        for name in Self.windowNotifications {
            AXObserverRemoveNotification(observer, window, name as CFString)
        }
    }

    fileprivate func handle(_ element: AXUIElement, _ name: String) {
        guard let pid = element.pid else { return }
        let event: WindowEvent
        switch name {
        case kAXWindowCreatedNotification: event = .created(element)
        case kAXUIElementDestroyedNotification: event = .destroyed(element)
        case kAXWindowMiniaturizedNotification: event = .minimized(element)
        case kAXWindowDeminiaturizedNotification: event = .restored(element)
        case kAXWindowMovedNotification: event = .moved(element)
        case kAXWindowResizedNotification: event = .resized(element)
        case kAXTitleChangedNotification: event = .titleChanged(element)
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification: event = .focusChanged(pid)
        case kAXApplicationHiddenNotification: event = .appHidden(pid)
        case kAXApplicationShownNotification: event = .appShown(pid)
        default: return
        }
        delegate?.tracker(event, pid: pid)
    }
}

private func trackerCallback(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    let n = name as String
    MainActor.assumeIsolated { tracker.handle(element, n) }
}

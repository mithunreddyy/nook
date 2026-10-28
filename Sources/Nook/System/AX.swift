import AppKit
import ApplicationServices

// MARK: - Private APIs
//
// Widely used by window managers (yabai, AeroSpace, AltTab, Rectangle). They
// fill gaps the public Accessibility API leaves: mapping an AX window to its
// CGWindowID, the current Space of a display, and reliable activation.

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
func CGSManagedDisplayGetCurrentSpace(_ cid: Int32, _ display: CFString) -> UInt64

@_silgen_name("GetProcessForPID")
@discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

/// Lives in the private SkyLight framework, so it's looked up at runtime.
private let setFrontProcess: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError)? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError).self)
}()

private let kCPSUserGenerated: UInt32 = 0x200

// MARK: - AXUIElement helpers

extension AXUIElement {
    static let systemWide = AXUIElementCreateSystemWide()

    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success && settable.boolValue
    }

    var windowID: CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(self, &wid) == .success && wid != 0 ? wid : nil
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    var role: String? { attribute(kAXRoleAttribute) }
    var subrole: String? { attribute(kAXSubroleAttribute) }
    var title: String? { attribute(kAXTitleAttribute) }
    var isMinimized: Bool { attribute(kAXMinimizedAttribute) ?? false }
    var isFullScreen: Bool { attribute("AXFullScreen") ?? false }
    var windows: [AXUIElement] { attribute(kAXWindowsAttribute) ?? [] }
    var focusedWindow: AXUIElement? { attribute(kAXFocusedWindowAttribute) }
    var closeButton: AXUIElement? { attribute(kAXCloseButtonAttribute) }

    var position: CGPoint? {
        guard let v: AXValue = attribute(kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    var size: CGSize? {
        guard let v: AXValue = attribute(kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    /// Frame in AX coordinates (top-left origin of the primary display, y down).
    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    func setPosition(_ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return set(kAXPositionAttribute, v)
    }

    @discardableResult
    func setSize(_ s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return set(kAXSizeAttribute, v)
    }

    /// Size, then position, then size again: the second size call lands
    /// windows that couldn't take the full size until they were moved.
    func setFrame(_ r: CGRect) {
        setSize(r.size)
        setPosition(r.origin)
        setSize(r.size)
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }

    /// The window under a screen point (AX coordinates), via the system-wide element.
    static func window(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              var e = element else { return nil }
        for _ in 0..<32 {
            if e.role == kAXWindowRole { return e }
            guard let parent: AXUIElement = e.attribute(kAXParentAttribute) else { return nil }
            e = parent
        }
        return nil
    }
}

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func configureTimeouts() {
        AXUIElementSetMessagingTimeout(AXUIElement.systemWide, 0.6)
    }

    /// Brings an app's window to the front and makes it key.
    static func focus(_ element: AXUIElement, pid: pid_t, wid: CGWindowID) {
        var psn = ProcessSerialNumber()
        GetProcessForPID(pid, &psn)
        _ = setFrontProcess?(&psn, wid, kCPSUserGenerated)
        element.set(kAXMainAttribute, kCFBooleanTrue)
        element.perform(kAXRaiseAction)
        if let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
            app.activate(from: .current, options: [])
        }
    }
}

// MARK: - Coordinates

enum Coords {
    /// Height of the primary display, the pivot between AppKit and AX space.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// AppKit (bottom-left, y up) to AX (top-left, y down), or back: the flip is its own inverse.
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func flip(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// The mouse location in AX coordinates.
    static var mouse: CGPoint { flip(NSEvent.mouseLocation) }
}

// MARK: - Window server

enum WindowServer {
    struct Info {
        var id: CGWindowID
        var pid: pid_t
        var layer: Int
        var bounds: CGRect // AX coordinates
    }

    /// On-screen windows, front to back.
    static func onScreen() -> [Info] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = d[kCGWindowLayer as String] as? Int,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return Info(id: id, pid: pid, layer: layer, bounds: rect)
        }
    }

    static func onScreenIDs() -> Set<CGWindowID> { Set(onScreen().map(\.id)) }

    /// The topmost ordinary window containing `point` (AX coordinates).
    static func topWindow(at point: CGPoint, excluding pid: pid_t = getpid()) -> Info? {
        onScreen().first { $0.layer == 0 && $0.pid != pid && $0.bounds.contains(point) }
    }
}

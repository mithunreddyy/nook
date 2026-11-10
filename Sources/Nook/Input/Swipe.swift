import AppKit
import NookKit

/// Hold the shortcut keys and swipe sideways (or up and down) with two fingers
/// to move to the next window that way. Swipes without the keys reach apps as usual.
/// An event tap, so a swipe Nook uses doesn't also scroll the app underneath.
@MainActor
final class Swipe {
    static let shared = Swipe()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Scroll travelled in the current gesture, in points.
    private var travel = CGSize.zero
    /// One move per gesture: set once a swipe has moved focus, cleared when the fingers lift.
    private var fired = false

    static let threshold: CGFloat = 60

    func apply(_ on: Bool) {
        on ? start() : stop()
    }

    private func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let swipe = Unmanaged<Swipe>.fromOpaque(refcon).takeUnretainedValue()
            let keep = MainActor.assumeIsolated { swipe.handle(type, event) }
            return keep ? Unmanaged.passUnretained(event) : nil
        }, userInfo: me) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }

    /// Returns false to swallow the event.
    private func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        // macOS turns a slow tap off; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return true
        }
        guard type == .scrollWheel, Engine.shared.canTile else { return true }
        // Trackpad gestures only, not a mouse wheel.
        guard e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else { return true }
        let want = WindowBar.prefixFlags(Preferences.shared.prefix)
        let flags = NSEvent.ModifierFlags(rawValue: UInt(e.flags.rawValue)).intersection([.control, .option, .command, .shift])
        let phase = e.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = e.getIntegerValueField(.scrollWheelEventMomentumPhase)
        guard flags == want else {
            travel = .zero
            fired = false
            return true
        }
        // The glide after the fingers lift: swallow it, it's part of the same swipe.
        if momentum != 0 { return false }
        if phase == 1 { // began
            travel = .zero
            fired = false
        }
        travel.width += CGFloat(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
        travel.height += CGFloat(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
        if !fired, max(abs(travel.width), abs(travel.height)) > Self.threshold {
            fired = true
            // Deltas follow content, so with natural scrolling (the default) fingers moving
            // left report a negative width. Undo that, so a swipe goes the way the fingers do.
            let natural = UserDefaults(suiteName: UserDefaults.globalDomain)?.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
            let fingers = natural ? travel : CGSize(width: -travel.width, height: -travel.height)
            let dir: Direction
            if abs(fingers.width) >= abs(fingers.height) {
                dir = fingers.width < 0 ? .left : .right
            } else {
                dir = fingers.height < 0 ? .up : .down
            }
            Engine.shared.run(.focus(dir), from: .mouse)
        }
        if phase == 4 || phase == 8 { // ended, cancelled
            travel = .zero
            fired = false
        }
        return false
    }
}

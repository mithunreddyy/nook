import AppKit
import NookKit

/// Global mouse handling: ⌘-drag to swap, ⌥⌘-drag to stack, drag to another
/// screen, live edge resizing, hover focus, and early close detection.
@MainActor
final class Mouse {
    static let shared = Mouse()

    private var monitors: [Any] = []
    private(set) var buttonDown = false
    private(set) var isDragging = false

    private struct Drag {
        var window: ManagedWindow
        var resizing: Bool
        var lastLive = Date.distantPast
    }

    private var drag: Drag?
    private var pressedButton: (window: ManagedWindow, at: CGPoint)?
    private var hoverTimer: Timer?
    private var lastKey = Date.distantPast
    private var lastMove = CGPoint.zero

    private var engine: Engine { Engine.shared }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved, .flagsChanged, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(m) }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            buttonDown = true
            hoverTimer?.invalidate()
            noteButtonPress()
        case .leftMouseDragged:
            buttonDown = true
            if drag != nil { updateDropTarget(flags: e.modifierFlags) }
        case .leftMouseUp:
            buttonDown = false
            finishDrag(flags: e.modifierFlags)
            finishButtonPress()
        case .flagsChanged:
            if drag != nil { updateDropTarget(flags: e.modifierFlags) }
        case .keyDown:
            lastKey = Date()
            hoverTimer?.invalidate()
        case .mouseMoved:
            hover()
        default:
            break
        }
    }

    // MARK: - Dragging windows

    /// A tiled window's frame changed while the button is down: it's being dragged.
    func windowIsMoving(_ w: ManagedWindow) {
        guard let assigned = w.assigned, let f = w.element.frame else { return }
        let resized = abs(f.width - assigned.width) > 2 || abs(f.height - assigned.height) > 2
        if drag == nil || drag?.window.id != w.id {
            drag = Drag(window: w, resizing: resized)
            isDragging = true
            if engine.zoomed[w.key] == w.id, !resized { engine.endFocusMode(on: w.key) }
        }
        if resized { drag?.resizing = true }
        guard drag?.resizing == true else { return }
        // Neighbours follow the edge live, a few times a second.
        if Date().timeIntervalSince(drag!.lastLive) > 0.04 {
            drag?.lastLive = Date()
            engine.resizeFromDrag(w, to: f, live: true)
        }
    }

    private enum DropTarget: Equatable {
        case tile(ScreenKey, Int, CGRect)
        case screen(ScreenKey, CGRect)
    }

    private func dropTarget(for w: ManagedWindow) -> DropTarget? {
        let p = Coords.mouse
        guard let d = engine.display(at: p) else { return nil }
        let frames = engine.tileFrames[d.key] ?? []
        let ownTile = engine.models[w.key]?.tileIndex(of: w.id)
        if let i = frames.firstIndex(where: { $0.contains(p) }) {
            if d.key == w.key && i == ownTile { return nil }
            return .tile(d.key, i, frames[i])
        }
        if d.key != w.key { return .screen(d.key, d.visible) }
        return nil
    }

    private func updateDropTarget(flags: NSEvent.ModifierFlags) {
        guard let drag, !drag.resizing else { return }
        guard flags.contains(.command), let target = dropTarget(for: drag.window) else {
            DropHighlight.shared.hide()
            return
        }
        let stack = flags.contains(.option)
        switch target {
        case .tile(_, _, let r): DropHighlight.shared.show(r, label: stack ? "Add to stack" : "Swap")
        case .screen(_, let r): DropHighlight.shared.show(r, label: "Move here")
        }
    }

    private func finishDrag(flags: NSEvent.ModifierFlags) {
        DropHighlight.shared.hide()
        guard let d = drag else { return }
        drag = nil
        isDragging = false
        let w = d.window
        guard engine.windows[w.id] != nil, w.mode == .tiled else { return }

        if d.resizing {
            if let f = w.element.frame { engine.resizeFromDrag(w, to: f, live: false) }
            engine.countUse(.grow, from: .mouse)
            return
        }

        let point = Coords.mouse
        if flags.contains(.command), let target = dropTarget(for: w) {
            switch target {
            case .tile(let key, let i, _):
                if let model = engine.models[key], i < model.tiles.count, let other = engine.windows[model.tiles[i].showing] {
                    if flags.contains(.option) {
                        engine.detach(w)
                        w.key = key
                        var m = engine.models[key] ?? model
                        m.stack(w.id, onto: min(i, max(m.tiles.count - 1, 0)))
                        engine.models[key] = m
                        engine.retile(key)
                    } else {
                        engine.exchange(w, other)
                    }
                    engine.countUse(.swap(.left), from: .both)
                    return
                }
            case .screen(let key, _):
                if let target = engine.display(for: key) {
                    engine.move(w, to: target, toward: nil, viaDrag: true, landing: point)
                    engine.countUse(.nextScreen, from: .both)
                }
                engine.retile(w.key)
                return
            }
        }

        // A plain drag: onto another screen joins it; anywhere else returns home.
        if let target = engine.display(at: point), target.key != w.key {
            if engine.move(w, to: target, toward: nil, viaDrag: true, landing: point) {
                engine.countUse(.nextScreen, from: .mouse)
                return
            }
        }
        engine.retile(w.key)
    }

    // MARK: - Close and minimize buttons

    /// A click on a close or minimize button lets the others start moving at once.
    private func noteButtonPress() {
        pressedButton = nil
        let p = Coords.mouse
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElement.systemWide, Float(p.x), Float(p.y), &element) == .success,
              let e = element, let sub = e.subrole,
              sub == kAXCloseButtonSubrole || sub == kAXMinimizeButtonSubrole,
              let win: AXUIElement = e.attribute(kAXWindowAttribute),
              let w = engine.managed(win), w.mode == .tiled else { return }
        pressedButton = (w, p)
    }

    private func finishButtonPress() {
        guard let (w, p) = pressedButton else { return }
        pressedButton = nil
        guard hypot(Coords.mouse.x - p.x, Coords.mouse.y - p.y) < 6, engine.windows[w.id] != nil else { return }
        w.mode = .closing
        engine.detach(w)
        // If it's still around shortly (a "Save changes?" sheet), it comes back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.engine.windows[w.id] === w, w.mode == .closing else { return }
            // Apps that hide a closed window keep its element alive; only one still on screen returns.
            if w.element.role != nil, !w.element.isMinimized, WindowServer.onScreenIDs().contains(w.id), let d = self.engine.display(for: w.key) {
                self.engine.place(w, on: d, fresh: false)
            } else {
                self.engine.forget(w.id)
            }
        }
    }

    // MARK: - Hover focus

    private func hover() {
        let p = Coords.mouse
        let moved = hypot(p.x - lastMove.x, p.y - lastMove.y)
        lastMove = p
        Visuals.shared.pointerMoved(p)
        guard engine.prefs.hoverFocus, engine.canTile, !buttonDown, moved > 0.5 else { return }
        // After a key press the pointer must move a little before hover takes over.
        if Date().timeIntervalSince(lastKey) < 0.25 { return }
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hoverSettled(at: p) }
        }
    }

    private func hoverSettled(at p: CGPoint) {
        guard !buttonDown, hypot(Coords.mouse.x - p.x, Coords.mouse.y - p.y) < 4 else { return }
        guard let info = WindowServer.topWindow(at: p), let w = engine.windows[info.id], w.mode == .tiled else { return }
        guard engine.activeID != w.id else { return }
        engine.focus(w)
    }
}

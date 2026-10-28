import AppKit
import QuartzCore
import NookKit

/// Draws everything Nook puts on screen around other apps' windows:
/// borders, the glow, No peek, Clean Space, and the grips above tiles.
@MainActor
final class Visuals {
    static let shared = Visuals()

    private var borders: [CGWindowID: BorderPanel] = [:]
    private var glow: GlowPanel?
    private var dimmers: [CGDirectDisplayID: ShadePanel] = [:]
    private var cleanBackdrop: ShadePanel?
    private var grips: [String: GripPanel] = [:]
    private var engine: Engine { Engine.shared }
    private var prefs: Preferences { Preferences.shared }

    /// How many of each overlay are showing, for the end-to-end tests.
    var counts: [String: Int] {
        [
            "borders": borders.values.filter(\.isVisible).count,
            "glow": glow?.isVisible == true ? 1 : 0,
            "dimmers": dimmers.values.filter(\.isVisible).count,
            "cleanBackdrop": cleanBackdrop?.isVisible == true ? 1 : 0,
            "grips": grips.values.filter(\.isVisible).count,
        ]
    }

    func hideAll() {
        borders.values.forEach { $0.orderOut(nil) }
        borders.removeAll()
        glow?.orderOut(nil)
        dimmers.values.forEach { $0.orderOut(nil) }
        dimmers.removeAll()
        cleanBackdrop?.orderOut(nil)
        cleanBackdrop = nil
        grips.values.forEach { $0.orderOut(nil) }
        grips.removeAll()
        HoverBar.shared.close()
    }

    func update() {
        guard engine.canTile else { hideAll(); return }
        updateBorders()
        updateGlow()
        updateNoPeek()
        updateCleanSpace()
        updateGrips()
        HoverBar.shared.refresh()
    }

    /// Our app was activated: put shades back below the windows they sit under.
    func restack() {
        guard engine.canTile else { return }
        updateNoPeek()
        updateCleanSpace()
    }

    func pointerMoved(_ p: CGPoint) {
        HoverBar.shared.pointerMoved(p)
        for g in grips.values where g.active { g.pointer(inside: g.hoverZone.contains(p)) }
    }

    // MARK: - Borders

    private var activeTiled: ManagedWindow? {
        guard let w = engine.activeTiled, engine.display(for: w.key) != nil else { return nil }
        return w
    }

    /// Tiled windows currently showing on visible screens.
    private var showingWindows: [ManagedWindow] {
        engine.visibleKeys.flatMap { engine.models[$0]?.showing ?? [] }.compactMap { engine.windows[$0] }
    }

    private func updateBorders() {
        var wanted: [ManagedWindow] = []
        switch prefs.highlight {
        case .borderActive: if let w = activeTiled { wanted = [w] }
        case .borderAll: wanted = showingWindows
        case .none, .glowActive: break
        }
        if engine.cleanSpace != nil { wanted.removeAll { !(engine.cleanSpace?.windows.contains($0.id) ?? false) } }
        let ids = Set(wanted.map(\.id))
        for (id, panel) in borders where !ids.contains(id) {
            panel.orderOut(nil)
            borders[id] = nil
        }
        let thickness = CGFloat(prefs.borderThickness)
        let color = prefs.accentNSColor
        for w in wanted {
            guard let frame = w.assigned else { continue }
            let panel = borders[w.id] ?? BorderPanel()
            borders[w.id] = panel
            let active = w.id == engine.activeID
            panel.configure(color: active || prefs.highlight == .borderActive ? color : color.withAlphaComponent(0.35),
                            thickness: thickness, radius: CGFloat(prefs.cornerRadius))
            panel.place(ax: frame.insetBy(dx: -thickness, dy: -thickness))
            panel.order(.above, relativeTo: Int(w.id))
        }
    }

    private func updateGlow() {
        guard prefs.highlight == .glowActive, let w = activeTiled, let f = w.assigned else {
            glow?.orderOut(nil)
            return
        }
        let panel = glow ?? GlowPanel()
        glow = panel
        let inset = CGFloat(prefs.cornerRadius)
        panel.place(ax: CGRect(x: f.minX + inset, y: f.minY - 5, width: max(f.width - inset * 2, 10), height: 5))
        panel.configure(color: prefs.accentNSColor)
        panel.order(.above, relativeTo: Int(w.id))
    }

    // MARK: - No peek

    private func updateNoPeek() {
        guard prefs.noPeek else {
            for p in dimmers.values { p.fadeOut() }
            dimmers.removeAll()
            return
        }
        // The window to keep bright: Nook's own when it's in front, else the
        // focused window of the frontmost app, tiled or not.
        let ownWindow = NSApp.isActive ? NSApp.keyWindow.flatMap { $0.isVisible ? $0 : nil } : nil
        let frontID: Int? = ownWindow.map(\.windowNumber) ?? engine.focusedID.map { Int($0) }
        let frontFrame: CGRect? = ownWindow.map { Coords.flip($0.frame) }
            ?? engine.focusedID.flatMap { id in WindowServer.onScreen().first { $0.id == id }?.bounds }
        let activeDisplay = frontFrame.flatMap { Displays.containing($0, in: engine.displays) }
        let ids = Set(engine.displays.map(\.id))
        for (id, p) in dimmers where !ids.contains(id) { p.orderOut(nil); dimmers[id] = nil }
        for d in engine.displays {
            let p = dimmers[d.id] ?? ShadePanel()
            let fresh = dimmers[d.id] == nil
            dimmers[d.id] = p
            p.configureDim(amount: prefs.dimAmount, blur: prefs.blurOthers)
            p.place(ax: d.visible)
            if let frontID, d.id == activeDisplay?.id {
                p.order(.below, relativeTo: frontID)
            } else {
                p.orderFrontRegardless()
            }
            if fresh { p.fadeIn() }
        }
    }

    // MARK: - Clean Space

    private func updateCleanSpace() {
        guard let clean = engine.cleanSpace, let d = engine.display(for: clean.key) else {
            cleanBackdrop?.fadeOut()
            cleanBackdrop = nil
            return
        }
        let p = cleanBackdrop ?? ShadePanel()
        let fresh = cleanBackdrop == nil
        cleanBackdrop = p
        p.configureSolid(prefs.cleanBackground.color)
        p.place(ax: d.visible)
        if let bottom = clean.order.first(where: { engine.windows[$0] != nil }) {
            p.order(.below, relativeTo: Int(bottom))
        } else {
            p.orderFrontRegardless()
        }
        if fresh { p.fadeIn() }
    }

    // MARK: - Grips

    private func updateGrips() {
        var wanted: [String: (CGRect, ManagedWindow, Tile, Bool)] = [:]
        let activeID = engine.activeID
        for key in engine.visibleKeys {
            guard let model = engine.models[key], let frames = engine.tileFrames[key] else { continue }
            if engine.cleanSpace?.key == key { continue }
            for (i, tile) in model.tiles.enumerated() where i < frames.count {
                guard let w = engine.windows[tile.showing] else { continue }
                let isActive = tile.contains(activeID ?? 0)
                let frame = engine.zoomed[key] == w.id ? (w.assigned ?? frames[i]) : frames[i]
                if engine.zoomed[key] != nil && engine.zoomed[key] != w.id { continue }
                if isActive && (prefs.quickActions || tile.isStack) {
                    wanted["\(key)#\(i)"] = (frame, w, tile, true)
                } else if tile.isStack {
                    wanted["\(key)#\(i)"] = (frame, w, tile, false)
                }
            }
        }
        for (k, g) in grips where wanted[k] == nil {
            g.orderOut(nil)
            grips[k] = nil
        }
        let gap = engine.prefs.effectiveGap
        for (k, item) in wanted {
            let (frame, w, tile, active) = item
            let g = grips[k] ?? GripPanel()
            grips[k] = g
            g.configure(window: w, tile: tile, active: active)
            let size = g.preferredSize
            // Sit in the gap above the tile; with no gap, just inside its top edge.
            let y = gap >= size.height + 2 ? frame.minY - (gap + size.height) / 2 : frame.minY + 1
            g.place(ax: CGRect(x: frame.midX - size.width / 2, y: y - (size.height - 6) / 2, width: size.width, height: size.height).integral)
            g.order(.above, relativeTo: Int(w.id))
        }
    }

    func grip(for windowID: CGWindowID) -> GripPanel? {
        grips.values.first { $0.windowID == windowID }
    }
}

// MARK: - Panels

final class BorderPanel: OverlayPanel {
    private let shape = CAShapeLayer()

    init() {
        super.init()
        let v = NSView()
        v.wantsLayer = true
        v.layer?.addSublayer(shape)
        shape.fillColor = nil
        contentView = v
    }

    private var radius: CGFloat = 12

    func configure(color: NSColor, thickness: CGFloat, radius: CGFloat) {
        shape.strokeColor = color.cgColor
        shape.lineWidth = thickness
        self.radius = radius
        redraw()
    }

    private func redraw() {
        let b = contentView?.bounds ?? .zero
        let t = shape.lineWidth
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = b
        let r = b.insetBy(dx: t / 2, dy: t / 2)
        let corner = min(radius + t / 2, min(r.width, r.height) / 2)
        shape.path = r.width > 0 && r.height > 0 ? CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil) : nil
        CATransaction.commit()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        redraw()
    }
}

final class GlowPanel: OverlayPanel {
    private let line = CALayer()

    init() {
        super.init()
        let v = NSView()
        v.wantsLayer = true
        v.layer?.masksToBounds = false
        v.layer?.addSublayer(line)
        contentView = v
    }

    func configure(color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = contentView?.bounds ?? .zero
        line.frame = CGRect(x: 0, y: 1, width: b.width, height: 2.5)
        line.cornerRadius = 1.25
        line.backgroundColor = color.cgColor
        line.shadowColor = color.cgColor
        line.shadowOpacity = 0.9
        line.shadowRadius = 3
        line.shadowOffset = .zero
        CATransaction.commit()
    }
}

/// A full-screen shade: dim and blur for No peek, or a solid plain background.
final class ShadePanel: OverlayPanel {
    private let blur = NSVisualEffectView()
    private let tint = NSView()

    init() {
        super.init()
        let root = NSView()
        blur.blendingMode = .behindWindow
        blur.material = .fullScreenUI
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        root.addSubview(blur)
        root.addSubview(tint)
        contentView = root
        alphaValue = 0
    }

    func configureDim(amount: Double, blur on: Bool) {
        blur.isHidden = !on
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(amount).cgColor
        layout()
    }

    func configureSolid(_ color: NSColor) {
        blur.isHidden = true
        tint.layer?.backgroundColor = color.cgColor
        layout()
    }

    private func layout() {
        let b = contentView?.bounds ?? .zero
        blur.frame = b
        tint.frame = b
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        layout()
    }

    func fadeIn() {
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            animator().alphaValue = 1
        }
    }

    func fadeOut() {
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        })
    }
}

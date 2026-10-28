import AppKit
import SwiftUI

/// The menu bar icon and the panel it opens.
@MainActor
final class StatusItem: NSObject {
    static var shared: StatusItem?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: KeyPanel?
    private var outsideMonitor: Any?

    override init() {
        super.init()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refresh()
    }

    func refresh() {
        let engine = Engine.shared
        item.button?.image = Self.icon(filled: engine.status.isActive, marked: engine.cleanSpace != nil)
        item.button?.toolTip = "Nook — \(engine.status.label)"
        item.button?.setAccessibilityLabel("Nook, \(engine.status.label)")
    }

    /// Three panes in the fold: filled while tiling, outlined when not.
    static func icon(filled: Bool, marked: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let outer = NSRect(x: 2.5, y: 3.5, width: 13, height: 11)
            let gap: CGFloat = 1.5
            let leftW = (outer.width - gap) * 0.5
            let rightH = (outer.height - gap) / 2
            let panes = [
                NSRect(x: outer.minX, y: outer.minY, width: leftW, height: outer.height),
                NSRect(x: outer.minX + leftW + gap, y: outer.minY + rightH + gap, width: outer.width - leftW - gap, height: rightH),
                NSRect(x: outer.minX + leftW + gap, y: outer.minY, width: outer.width - leftW - gap, height: rightH),
            ]
            NSColor.black.set()
            for p in panes {
                let path = NSBezierPath(roundedRect: filled ? p : p.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.2, yRadius: 1.2)
                if filled { path.fill() } else { path.lineWidth = 1; path.stroke() }
            }
            if marked {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 4.5, height: 4.5)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc private func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    func open() {
        guard let button = item.button, let window = button.window else { return }
        let p = panel ?? KeyPanel()
        panel = p
        p.level = .statusBar
        let size = p.setMaterialContent(PanelView(close: { [weak self] in self?.close() }), material: .popover, radius: 12)
        p.onKey = { [weak self] e in
            if e.keyCode == 53 { self?.close(); return true }
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "," {
                self?.close()
                SettingsWindow.shared.show()
                return true
            }
            return false
        }
        let anchor = window.convertToScreen(button.frame)
        let screen = window.screen ?? NSScreen.main
        var x = anchor.midX - size.width / 2
        if let s = screen?.visibleFrame { x = min(max(x, s.minX + 6), s.maxX - size.width - 6) }
        p.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        panel?.orderOut(nil)
        if let m = outsideMonitor { NSEvent.removeMonitor(m) }
        outsideMonitor = nil
    }
}

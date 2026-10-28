import AppKit
import SwiftUI
import NookKit

/// The small grip in the gap above a tile. On the active tile, resting near it
/// opens the quick actions; on a stack it shows one segment (or dot) per window.
final class GripPanel: OverlayPanel {
    private(set) var windowID: CGWindowID = 0
    private(set) var active = false
    private var tile: Tile?
    private var dwell: Timer?
    private let view = GripView()

    init() {
        super.init(interactive: true)
        contentView = view
        view.onClickSegment = { [weak self] i in
            guard let self, let tile = self.tile, i < tile.order.count else { return }
            MainActor.assumeIsolated { Engine.shared.show(tile.order[i]) }
        }
    }

    var preferredSize: CGSize {
        let n = tile?.order.count ?? 1
        if tile?.isStack ?? false {
            return CGSize(width: CGFloat(n) * (active ? 18 : 10) + 8, height: 6)
        }
        return CGSize(width: 44, height: 6)
    }

    /// Where resting the pointer counts as resting on the grip: well past its
    /// 6-point drawing, so it's easy to hit without blocking the title bar.
    var hoverZone: CGRect {
        Coords.flip(frame).insetBy(dx: -10, dy: -8)
    }

    func configure(window: ManagedWindow, tile: Tile, active: Bool) {
        windowID = window.id
        self.tile = tile
        self.active = active
        view.segments = tile.isStack ? tile.order.map { $0 == tile.showing } : []
        view.active = active
        view.needsDisplay = true
        setAccessibilityLabel(tile.isStack ? "Stack of \(tile.count) windows" : "Quick actions")
    }

    func pointer(inside: Bool) {
        guard inside else {
            dwell?.invalidate()
            dwell = nil
            return
        }
        guard active, Preferences.shared.quickActions, dwell == nil, !HoverBar.shared.isOpen else { return }
        dwell = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dwell = nil
                guard let w = Engine.shared.windows[self.windowID] else { return }
                HoverBar.shared.open(for: w, below: self)
            }
        }
    }
}

final class GripView: NSView {
    var segments: [Bool] = []
    var active = false
    var onClickSegment: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard !segments.isEmpty else { return }
        let x = convert(event.locationInWindow, from: nil).x - 4
        let w = (bounds.width - 8) / CGFloat(segments.count)
        onClickSegment?(min(max(Int(x / w), 0), segments.count - 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let h: CGFloat = 3
        let y = (bounds.height - h) / 2
        if segments.isEmpty {
            let r = NSRect(x: 4, y: y, width: bounds.width - 8, height: h)
            NSColor.labelColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
            return
        }
        let slot = (bounds.width - 8) / CGFloat(segments.count)
        for (i, showing) in segments.enumerated() {
            let x = 4 + CGFloat(i) * slot
            Theme.stackColor.withAlphaComponent(showing ? 1 : 0.45).setFill()
            if active {
                let r = NSRect(x: x + 1.5, y: y, width: slot - 3, height: h)
                NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
            } else {
                let d: CGFloat = 5
                NSBezierPath(ovalIn: NSRect(x: x + (slot - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)).fill()
            }
        }
    }
}

// MARK: - The bar

@MainActor
final class HoverBarModel: ObservableObject {
    @Published var window: ManagedWindow?
    @Published var optionHeld = false
    @Published var revision = 0
}

@MainActor
final class HoverBar {
    static let shared = HoverBar()

    private var panel: OverlayPanel?
    private let model = HoverBarModel()
    private var anchor: CGRect = .zero
    private var flagsTimer: Timer?
    private var draggingChip = false

    var isOpen: Bool { panel?.isVisible ?? false }

    func open(for w: ManagedWindow, below grip: GripPanel) {
        model.window = w
        model.revision += 1
        let p = panel ?? OverlayPanel(interactive: true, level: .floating)
        panel = p
        let size = p.setMaterialContent(HoverBarView(model: model), material: .popover, radius: 12)
        let gripFrame = Coords.flip(grip.frame)
        anchor = grip.hoverZone
        var x = gripFrame.midX - size.width / 2
        if let d = Engine.shared.display(for: w.key) {
            x = min(max(x, d.visible.minX + 4), d.visible.maxX - size.width - 4)
        }
        p.place(ax: CGRect(x: x, y: gripFrame.maxY + 4, width: size.width, height: size.height))
        p.orderFrontRegardless()
        flagsTimer?.invalidate()
        flagsTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let held = NSEvent.modifierFlags.contains(.option)
                if held != self.model.optionHeld {
                    self.model.optionHeld = held
                    self.refit()
                }
                self.pointerMoved(Coords.mouse)
            }
        }
    }

    /// Re-measures the bar after its content changed.
    private func refit() {
        guard let panel, let w = model.window else { return }
        var f = Coords.flip(panel.frame)
        let size = panel.setMaterialContent(HoverBarView(model: model), material: .popover, radius: 12)
        f.origin.x += (f.width - size.width) / 2
        f.size = size
        if let d = Engine.shared.display(for: w.key) {
            f.origin.x = min(max(f.minX, d.visible.minX + 4), d.visible.maxX - size.width - 4)
        }
        panel.place(ax: f)
    }

    func refresh() {
        guard isOpen else { return }
        guard let w = model.window, Engine.shared.windows[w.id] != nil, Engine.shared.activeID == w.id else {
            close()
            return
        }
        model.revision += 1
        refit()
    }

    func close() {
        flagsTimer?.invalidate()
        flagsTimer = nil
        panel?.orderOut(nil)
    }

    func setDraggingChip(_ on: Bool) { draggingChip = on }

    func pointerMoved(_ p: CGPoint) {
        guard isOpen, !draggingChip, let panel else { return }
        let bar = Coords.flip(panel.frame).insetBy(dx: -10, dy: -10)
        if !bar.union(anchor).contains(p) { close() }
    }
}

struct HoverBarView: View {
    @ObservedObject var model: HoverBarModel
    @ObservedObject private var engine = Engine.shared

    var body: some View {
        let _ = model.revision
        VStack(spacing: 6) {
            if let w = model.window {
                HStack(spacing: 2) {
                    action("Make Primary", "rectangle.lefthalf.inset.filled", .makePrimary)
                    if engine.zoomed[w.key] == w.id {
                        action("Exit Focus", "arrow.down.right.and.arrow.up.left", .focusMode)
                    } else {
                        action("Focus", "arrow.up.left.and.arrow.down.right", .focusMode)
                    }
                    screenAction(w)
                    if model.optionHeld {
                        action("Always Float Windows Like This", "pin", .alwaysFloat)
                    } else if w.mode == .tiled {
                        action("Float", "macwindow.on.rectangle", .toggleFloat)
                    } else {
                        action("Tile", "rectangle.split.2x1", .toggleFloat)
                    }
                }
                if let tile = engine.models[w.key]?.tiles.first(where: { $0.contains(w.id) }), tile.isStack {
                    Divider()
                    StackChips(tile: tile)
                }
            }
        }
        .padding(4)
        .fixedSize()
    }

    private func action(_ title: String, _ icon: String, _ command: Command) -> some View {
        let keys = engine.hotkeys.combo(for: command)?.display
        return Button {
            engine.run(command, from: .mouse)
            HoverBar.shared.refresh()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .help(keys.map { "\(title)  \($0)" } ?? title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func screenAction(_ w: ManagedWindow) -> some View {
        let others = engine.displays.filter { $0.key != w.key }
        if others.count == 1, let d = others.first {
            let full = engine.roomDescription(d) == "full"
            action(full ? (engine.prefs.moveIntoFull == .swap ? "Swap with \(d.name)" : "Stack on \(d.name)") : "Move to \(d.name)",
                   "rectangle.portrait.and.arrow.right", .nextScreen)
        } else if others.count > 1 {
            Menu {
                ForEach(others, id: \.id) { d in
                    Button("\(d.name) (\(engine.roomDescription(d)))") {
                        engine.move(w, to: d, toward: nil, viaDrag: false)
                    }
                }
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 28)
            .help("Move to Screen")
            .accessibilityLabel("Move to Screen")
        }
    }
}

private struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration)
    }

    private struct Inner: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hover ? 0.08 : 0))))
                .onHover { hover = $0 }
        }
    }
}

/// The windows in a stack, as chips: click to show, × to close, drag to another tile.
struct StackChips: View {
    var tile: Tile
    @ObservedObject private var engine = Engine.shared

    var body: some View {
        HStack(spacing: 4) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous window in stack")
            ForEach(tile.order, id: \.self) { id in
                if let w = engine.windows[id] { Chip(window: w, showing: id == tile.showing) }
            }
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Next window in stack")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .onScrollWheel { delta in step(delta > 0 ? -1 : 1) }
    }

    private func step(_ by: Int) {
        engine.run(by > 0 ? .stackNext : .stackPrevious, from: .mouse)
        HoverBar.shared.refresh()
    }
}

struct Chip: View {
    var window: ManagedWindow
    var showing: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: window.icon).resizable().frame(width: 16, height: 16)
            Text(window.appName).font(.callout).lineLimit(1).frame(maxWidth: 100, alignment: .leading)
            if hovering {
                Button { close() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(window.appName)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(showing ? Color.orange.opacity(0.2) : Color.primary.opacity(hovering ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(showing ? Color.orange : Color.clear, lineWidth: 1))
        .onHover { hovering = $0 }
        .onTapGesture { Engine.shared.show(window.id) }
        .onMiddleClick { close() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(window.appName)
        .accessibilityAddTraits(showing ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { Engine.shared.show(window.id) }
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { _ in
                HoverBar.shared.setDraggingChip(true)
                if let (_, _, r) = Chip.tile(at: Coords.mouse, excluding: window) {
                    DropHighlight.shared.show(r, label: "Move Here")
                } else {
                    DropHighlight.shared.hide()
                }
            }
            .onEnded { _ in
                HoverBar.shared.setDraggingChip(false)
                DropHighlight.shared.hide()
                if let (key, i, _) = Chip.tile(at: Coords.mouse, excluding: window) {
                    Engine.shared.moveToTile(window, key: key, tile: i)
                }
                HoverBar.shared.close()
            })
    }

    private func close() {
        if let button = window.element.closeButton {
            button.perform(kAXPressAction)
        } else if let d = Engine.shared.display(for: window.key) {
            Toast.show("\(window.appName) can't be closed from here", on: d, symbol: "xmark")
        }
    }

    static func tile(at p: CGPoint, excluding w: ManagedWindow) -> (ScreenKey, Int, CGRect)? {
        let engine = Engine.shared
        guard let d = engine.display(at: p), let frames = engine.tileFrames[d.key] else { return nil }
        guard let i = frames.firstIndex(where: { $0.contains(p) }) else { return nil }
        if d.key == w.key, engine.models[d.key]?.tileIndex(of: w.id) == i { return nil }
        return (d.key, i, frames[i])
    }
}

extension Engine {
    /// Moves a window into another tile's stack, on any screen.
    func moveToTile(_ w: ManagedWindow, key: ScreenKey, tile: Int) {
        detach(w)
        w.key = key
        guard var m = models[key], !m.tiles.isEmpty else { return }
        m.stack(w.id, onto: min(tile, m.tiles.count - 1))
        models[key] = m
        retile(key)
        raiseShowing(on: key)
        focus(w)
    }
}

// MARK: - Mouse helpers for SwiftUI

private struct MouseCatcher: NSViewRepresentable {
    var onScroll: ((CGFloat) -> Void)?
    var onMiddle: (() -> Void)?

    final class V: NSView {
        var onScroll: ((CGFloat) -> Void)?
        var onMiddle: (() -> Void)?
        private var accumulated: CGFloat = 0

        override func scrollWheel(with e: NSEvent) {
            guard let onScroll else { return super.scrollWheel(with: e) }
            accumulated += e.scrollingDeltaX + e.scrollingDeltaY
            if abs(accumulated) > 12 {
                onScroll(accumulated)
                accumulated = 0
            }
        }

        override func otherMouseUp(with e: NSEvent) {
            if e.buttonNumber == 2 { onMiddle?() } else { super.otherMouseUp(with: e) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Claim only scroll and middle clicks; SwiftUI handles the rest.
            switch NSApp.currentEvent?.type {
            case .scrollWheel where onScroll != nil: return super.hitTest(point)
            case .otherMouseDown, .otherMouseUp: return onMiddle != nil ? super.hitTest(point) : nil
            default: return nil
            }
        }
    }

    func makeNSView(context: Context) -> V { V() }

    func updateNSView(_ v: V, context: Context) {
        v.onScroll = onScroll
        v.onMiddle = onMiddle
    }
}

extension View {
    func onScrollWheel(_ action: @escaping (CGFloat) -> Void) -> some View {
        overlay(MouseCatcher(onScroll: action))
    }

    func onMiddleClick(_ action: @escaping () -> Void) -> some View {
        overlay(MouseCatcher(onMiddle: action))
    }
}

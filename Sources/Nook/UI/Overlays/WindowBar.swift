import AppKit
import NookKit
import SwiftUI

/// A row of app icons, one per tile, at the top or bottom of each screen.
/// Click an icon to go to that window; drag one onto another to swap them.
@MainActor
final class WindowBar {
    static let shared = WindowBar()
    static let height: CGFloat = 36

    private var panels: [CGDirectDisplayID: BarPanel] = [:]
    private var holding = false
    private var engine: Engine { Engine.shared }
    private var prefs: Preferences { Preferences.shared }

    var visibleCount: Int { panels.values.filter(\.isVisible).count }

    func hideAll() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    /// Shows the bar while the shortcut keys are held, in that mode.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard prefs.windowBar == .whileHolding else { return }
        let want = Self.prefixFlags(prefs.prefix)
        let now = flags.intersection([.control, .option, .command, .shift]).isSuperset(of: want)
        guard now != holding else { return }
        holding = now
        update()
    }

    static func prefixFlags(_ p: ShortcutPrefix) -> NSEvent.ModifierFlags {
        switch p {
        case .controlOption: [.control, .option]
        case .optionCommand: [.option, .command]
        case .controlShift: [.control, .shift]
        }
    }

    func update() {
        let show = engine.canTile && (prefs.windowBar == .always || (prefs.windowBar == .whileHolding && holding))
        guard show else { hideAll(); return }
        var seen = Set<CGDirectDisplayID>()
        for d in engine.displays {
            let tiles = engine.models[d.key]?.tiles ?? []
            guard !tiles.isEmpty else { continue }
            seen.insert(d.id)
            let items = tiles.enumerated().compactMap { i, t -> BarItem? in
                guard let w = engine.windows[t.showing] else { return nil }
                return BarItem(id: w.id, index: i, app: w.appName, icon: w.icon, stacked: t.count, active: w.id == engine.activeID)
            }
            let panel = panels[d.id] ?? BarPanel()
            panels[d.id] = panel
            let size = panel.show(items, key: d.key)
            let area = engine.workArea(d)
            let outer = d.visible.insetBy(dx: prefs.effectiveOuterGap, dy: prefs.effectiveOuterGap)
            let y: CGFloat
            if prefs.windowBar == .always {
                // In the strip the tiles leave free.
                y = prefs.windowBarEdge == .top ? outer.minY : area.maxY + prefs.effectiveGap
            } else {
                y = prefs.windowBarEdge == .top ? outer.minY + 6 : outer.maxY - Self.height - 6
            }
            panel.level = prefs.windowBar == .always ? .floating : .statusBar
            panel.place(ax: CGRect(x: (d.visible.midX - size.width / 2).rounded(), y: y, width: size.width, height: Self.height))
            panel.orderFrontRegardless()
        }
        for (id, p) in panels where !seen.contains(id) {
            p.orderOut(nil)
            panels[id] = nil
        }
    }
}

struct BarItem: Identifiable, Equatable {
    var id: CGWindowID
    var index: Int
    var app: String
    var icon: NSImage
    var stacked: Int
    var active: Bool
}

private final class BarPanel: OverlayPanel {
    private let host = FirstMouseHost(rootView: AnyView(EmptyView()))

    init() {
        super.init(interactive: true, level: .floating)
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = .roundedMask(radius: WindowBar.height / 2)
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        contentView = effect
        hasShadow = true
    }

    /// Fills the bar and returns its size.
    func show(_ items: [BarItem], key: ScreenKey) -> CGSize {
        host.rootView = AnyView(BarContent(items: items, key: key))
        let size = CGSize(width: max(host.fittingSize.width, 60), height: WindowBar.height)
        host.frame = NSRect(origin: .zero, size: size)
        return size
    }
}

/// Takes the first click, so the bar works without making Nook active.
private final class FirstMouseHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct BarContent: View {
    var items: [BarItem]
    var key: ScreenKey
    @State private var dragging: CGWindowID?
    @State private var offset: CGFloat = 0

    private let slot: CGFloat = 34

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                icon(item)
                    .offset(x: dragging == item.id ? offset : 0)
                    .zIndex(dragging == item.id ? 1 : 0)
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            dragging = item.id
                            offset = g.translation.width
                        }
                        .onEnded { g in
                            let target = min(max(item.index + Int((g.translation.width / slot).rounded()), 0), items.count - 1)
                            dragging = nil
                            offset = 0
                            if target != item.index { Engine.shared.swapTiles(item.index, target, on: key) }
                        })
                    .onTapGesture { Engine.shared.show(item.id) }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: WindowBar.height)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private func icon(_ item: BarItem) -> some View {
        Image(nsImage: item.icon).resizable().frame(width: 24, height: 24)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(item.active ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.001)))
            .overlay(alignment: .topTrailing) {
                if item.stacked > 1 {
                    Text("\(item.stacked)").font(.system(size: 9, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 3).background(Capsule().fill(Color.secondary))
                        .offset(x: 2, y: -2)
                }
            }
            .help("\(item.index + 1). \(item.app)")
            .accessibilityElement()
            .accessibilityLabel("Window \(item.index + 1), \(item.app)\(item.stacked > 1 ? ", \(item.stacked) stacked" : "")")
            .accessibilityAddTraits(item.active ? [.isSelected, .isButton] : .isButton)
    }
}

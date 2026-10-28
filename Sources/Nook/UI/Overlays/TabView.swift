import AppKit
import SwiftUI

/// ⌥⇥: every window, screen by screen, laid out where it sits. Titles are
/// read only while it's open, to label the tiles, and never kept.
@MainActor
final class TabView: ObservableObject {
    static let shared = TabView()

    struct Item: Identifiable {
        var id: CGWindowID
        var pid: pid_t
        var element: AXUIElement
        var app: String
        var icon: NSImage
        var title: String
        var frame: CGRect // AX coordinates
        var minimized: Bool
        var display: CGDirectDisplayID
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var displays: [Display] = []
    @Published var selected: CGWindowID?

    private var panel: KeyPanel?
    private var poll: Timer?
    private var order: [CGWindowID] = []

    var isOpen: Bool { panel?.isVisible ?? false }

    func press(forward: Bool) {
        if isOpen {
            step(forward ? 1 : -1)
            return
        }
        gather()
        guard !order.isEmpty else { return }
        // Start on the window used before this one, like ⌘⇥ between apps.
        selected = forward ? order[min(1, order.count - 1)] : order.last
        show()
    }

    private func gather() {
        displays = Displays.all()
        let onScreen = WindowServer.onScreen()
        let visible = Set(onScreen.map(\.id))
        // Back to front, so overlapping tiles draw in the right order.
        let zOrder = Dictionary(uniqueKeysWithValues: onScreen.enumerated().map { ($1.id, $0) })
        var list: [Item] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            for e in AXUIElementCreateApplication(app.processIdentifier).windows {
                guard e.subrole == kAXStandardWindowSubrole, let id = e.windowID, let f = e.frame else { continue }
                let minimized = e.isMinimized
                guard minimized || visible.contains(id) else { continue }
                list.append(Item(id: id, pid: app.processIdentifier, element: e, app: app.localizedName ?? "App",
                                 icon: app.icon ?? NSImage(), title: e.title ?? "", frame: f, minimized: minimized,
                                 display: Displays.containing(f, in: displays)?.id ?? 0))
            }
        }
        list.sort { (zOrder[$0.id] ?? Int.max) > (zOrder[$1.id] ?? Int.max) }
        items = list
        let ids = Set(list.map(\.id))
        let recent = Engine.shared.recent.filter(ids.contains)
        let rest = onScreen.map(\.id).filter { ids.contains($0) && !recent.contains($0) }
        let minimized = list.filter(\.minimized).map(\.id).filter { !recent.contains($0) }
        order = recent + rest + minimized
    }

    private func show() {
        let p = panel ?? KeyPanel()
        panel = p
        let size = p.setMaterialContent(TabViewContent(model: self), material: .hudWindow, radius: 18)
        let f = (NSScreen.main ?? NSScreen.screens[0]).frame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
        p.onKey = { [weak self] e in self?.key(e) ?? false }
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Letting go of ⌥ switches.
                if !NSEvent.modifierFlags.contains(.option) { self?.commit() }
            }
        }
    }

    private func step(_ by: Int) {
        guard !order.isEmpty else { return }
        let i = selected.flatMap { order.firstIndex(of: $0) } ?? 0
        selected = order[((i + by) % order.count + order.count) % order.count]
    }

    /// Moves to the nearest window that way, across screens too.
    private func move(_ dir: Direction) {
        guard let current = items.first(where: { $0.id == selected }) else { return }
        let c = CGPoint(x: current.frame.midX, y: current.frame.midY)
        let candidates = items.filter { $0.id != current.id && !$0.minimized }.filter {
            switch dir {
            case .left: $0.frame.midX < c.x - 1
            case .right: $0.frame.midX > c.x + 1
            case .up: $0.frame.midY < c.y - 1
            case .down: $0.frame.midY > c.y + 1
            }
        }
        func cost(_ i: Item) -> CGFloat {
            let dx = abs(i.frame.midX - c.x), dy = abs(i.frame.midY - c.y)
            return dir == .left || dir == .right ? dx + dy * 2 : dy + dx * 2
        }
        if let best = candidates.min(by: { cost($0) < cost($1) }) { selected = best.id }
    }

    private func key(_ e: NSEvent) -> Bool {
        switch Int(e.keyCode) {
        case 53: close() // esc
        case 36, 76: commit() // return
        case 123: move(.left)
        case 124: move(.right)
        case 125: move(.down)
        case 126: move(.up)
        case 48: step(e.modifierFlags.contains(.shift) ? -1 : 1)
        default: return false
        }
        return true
    }

    func commit(_ id: CGWindowID? = nil) {
        let target = items.first { $0.id == (id ?? selected) }
        close()
        guard let item = target else { return }
        if item.minimized { item.element.set(kAXMinimizedAttribute, kCFBooleanFalse) }
        AX.focus(item.element, pid: item.pid, wid: item.id)
    }

    func close() {
        poll?.invalidate()
        poll = nil
        panel?.orderOut(nil)
        items = []
    }
}

/// A panel that takes the keyboard without activating Nook.
final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

private struct TabViewContent: View {
    @ObservedObject var model: TabView

    private var columns: [(Display, [TabView.Item])] {
        model.displays.sorted { $0.frame.minX < $1.frame.minX }.map { d in (d, model.items.filter { $0.display == d.id }) }
    }

    private var selectedItem: TabView.Item? { model.items.first { $0.id == model.selected } }

    var body: some View {
        let maxH: CGFloat = 300
        let totalW = columns.reduce(CGFloat(0)) { $0 + $1.0.frame.width * (maxH / $1.0.frame.height) }
        let limit = (NSScreen.main?.frame.width ?? 1600) * 0.84
        let scale = min(1, limit / max(totalW, 1))
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                ForEach(columns, id: \.0.id) { d, items in
                    let s = maxH * scale / d.frame.height
                    VStack(alignment: .leading, spacing: 8) {
                        if columns.count > 1 {
                            Text(d.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06))
                            ForEach(items.filter { !$0.minimized }) { tile($0, scale: s, origin: d.frame.origin) }
                        }
                        .frame(width: d.frame.width * s, height: d.frame.height * s)
                        let minimized = items.filter(\.minimized)
                        if !minimized.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(minimized) { item in
                                    Image(nsImage: item.icon).resizable().frame(width: 22, height: 22)
                                        .padding(4)
                                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(model.selected == item.id ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06)))
                                        .onTapGesture { model.commit(item.id) }
                                        .help(item.title.isEmpty ? item.app : item.title)
                                        .accessibilityLabel("\(item.app), minimized")
                                }
                            }
                        }
                    }
                }
            }
            // The picked window's name, the way ⌘⇥ names the picked app.
            VStack(spacing: 2) {
                Text(selectedItem?.app ?? " ").font(.headline)
                Text(selectedItem.map { $0.title.isEmpty ? " " : $0.title } ?? " ")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 520)
        }
        .padding(20)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private func tile(_ item: TabView.Item, scale s: CGFloat, origin: CGPoint) -> some View {
        let selected = model.selected == item.id
        let r = CGRect(x: (item.frame.minX - origin.x) * s, y: (item.frame.minY - origin.y) * s,
                       width: max(item.frame.width * s, 40), height: max(item.frame.height * s, 30))
        let icon = min(40, r.height * 0.45, r.width * 0.45)
        return Image(nsImage: item.icon).resizable().frame(width: icon, height: icon)
            .frame(width: r.width - 4, height: r.height - 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: selected ? 3 : 1))
            .offset(x: r.minX + 2, y: r.minY + 2)
            .onTapGesture { model.commit(item.id) }
            .accessibilityLabel("\(item.app), \(item.title)")
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

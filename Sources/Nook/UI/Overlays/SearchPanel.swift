import AppKit
import NookKit
import SwiftUI

/// ⌃⌥S: type a few letters of an app or window title and press Return to go
/// there. Titles are read only while it's open, to match against, and never kept.
@MainActor
final class SearchPanel: ObservableObject {
    static let shared = SearchPanel()

    struct Item: Identifiable {
        var id: CGWindowID
        var pid: pid_t
        var element: AXUIElement
        var app: String
        var icon: NSImage
        var title: String
        var minimized: Bool
        var hidden: Bool
    }

    static let maxRows = 8

    @Published private(set) var query = ""
    @Published private(set) var results: [Item] = []
    @Published var selected = 0

    private var all: [Item] = []
    private var panel: KeyPanel?

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    private func open() {
        TabView.shared.close()
        gather()
        query = ""
        filter()
        // Start on the window used before this one, so Return alone goes back.
        selected = results.count > 1 ? 1 : 0
        let p = panel ?? KeyPanel()
        panel = p
        let size = p.setMaterialContent(SearchContent(model: self), material: .hudWindow, radius: 16)
        let f = (Engine.shared.currentDisplay?.screen ?? NSScreen.main ?? NSScreen.screens[0]).frame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + f.height * 0.62 - size.height / 2,
                          width: size.width, height: size.height), display: true)
        p.onKey = { [weak self] e in self?.key(e) ?? false }
        p.onResign = { [weak self] in self?.close() }
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
    }

    /// Every standard window: on screen, minimized, or in a hidden app. Most recently used first.
    private func gather() {
        let onScreen = WindowServer.onScreen().map(\.id)
        let visible = Set(onScreen)
        var list: [Item] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            for e in AXUIElementCreateApplication(app.processIdentifier).windows {
                guard e.subrole == kAXStandardWindowSubrole, let id = e.windowID else { continue }
                let minimized = e.isMinimized
                guard visible.contains(id) || minimized || app.isHidden else { continue }
                list.append(Item(id: id, pid: app.processIdentifier, element: e, app: app.localizedName ?? "App",
                                 icon: app.icon ?? NSImage(), title: e.title ?? "", minimized: minimized, hidden: app.isHidden))
            }
        }
        let ids = Set(list.map(\.id))
        let recent = Engine.shared.recent.filter(ids.contains)
        let rest = onScreen.filter { ids.contains($0) && !recent.contains($0) }
        let order = recent + rest
        list.sort { (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max) }
        all = list
    }

    private func filter() {
        results = WindowSearch.rank(query, items: all) { [$0.app, $0.title] }
        selected = 0
    }

    private func key(_ e: NSEvent) -> Bool {
        switch Int(e.keyCode) {
        case 53: close() // esc
        case 36, 76: commit() // return
        case 125: step(1) // down
        case 126: step(-1) // up
        case 48: step(e.modifierFlags.contains(.shift) ? -1 : 1) // tab
        case 51: // delete
            guard !query.isEmpty else { return true }
            if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.command) { query = "" } else { query.removeLast() }
            filter()
        default:
            // Plain typing only: shortcuts with ⌘ or ⌃ aren't letters.
            guard e.modifierFlags.intersection([.command, .control]).isEmpty,
                  let s = e.characters, !s.isEmpty, s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            query += s
            filter()
        }
        return true
    }

    private func step(_ by: Int) {
        let n = min(results.count, Self.maxRows)
        guard n > 0 else { return }
        selected = ((selected + by) % n + n) % n
    }

    func commit(_ index: Int? = nil) {
        let i = index ?? selected
        let target = results.indices.contains(i) ? results[i] : nil
        close()
        guard let item = target else { return }
        if item.hidden { NSRunningApplication(processIdentifier: item.pid)?.unhide() }
        if item.minimized { item.element.set(kAXMinimizedAttribute, kCFBooleanFalse) }
        let engine = Engine.shared
        if let w = engine.windows[item.id] {
            engine.focus(w, keyboard: true)
        } else {
            AX.focus(item.element, pid: item.pid, wid: item.id)
        }
    }

    func close() {
        panel?.onResign = nil
        panel?.orderOut(nil)
        all = []
        results = []
    }
}

private struct SearchContent: View {
    @ObservedObject var model: SearchPanel

    private let rowHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                HStack(spacing: 1) {
                    if model.query.isEmpty {
                        Text("Search windows").foregroundStyle(.tertiary)
                    } else {
                        Text(model.query).lineLimit(1).truncationMode(.head)
                        RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 2, height: 20)
                    }
                }
                .font(.title3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.query.isEmpty ? "Search windows" : "Search: \(model.query)")

            Divider().opacity(0.5)

            let rows = Array(model.results.prefix(SearchPanel.maxRows).enumerated())
            VStack(spacing: 2) {
                if rows.isEmpty {
                    Text("No windows match").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 20)
                }
                ForEach(rows, id: \.element.id) { i, item in row(item, index: i) }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(height: rowHeight * CGFloat(SearchPanel.maxRows) + 2 * CGFloat(SearchPanel.maxRows) + 12, alignment: .top)

            HStack(spacing: 14) {
                Text("↩ Go").fixedSize()
                Text("↑↓ Choose").fixedSize()
                Text("esc Close").fixedSize()
                Spacer()
                Text(count).fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 580)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var count: String {
        let n = model.results.count
        return n == 1 ? "1 window" : "\(n) windows"
    }

    private func row(_ item: SearchPanel.Item, index i: Int) -> some View {
        let on = model.selected == i
        let note = item.minimized ? "Minimized" : item.hidden ? "Hidden" : nil
        return HStack(spacing: 10) {
            Image(nsImage: item.icon).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? item.app : item.title).lineLimit(1).truncationMode(.middle)
                if !item.title.isEmpty {
                    Text(item.app).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.accentColor.opacity(0.35) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.commit(i) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}

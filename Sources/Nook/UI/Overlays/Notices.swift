import AppKit
import SwiftUI

// MARK: - Toast

/// A short notice near the bottom of a screen, on the system HUD material.
@MainActor
enum Toast {
    private static var panel: OverlayPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, on d: Display?, symbol: String = "rectangle.split.3x1") {
        let d = d ?? Engine.shared.currentDisplay
        guard let d else { return }
        let p = panel ?? OverlayPanel(level: .statusBar)
        panel = p
        let size = p.setMaterialContent(ToastView(text: text, symbol: symbol), material: .hudWindow, radius: 12)
        p.place(ax: CGRect(x: d.visible.midX - size.width / 2, y: d.visible.maxY - size.height - 48,
                           width: size.width, height: size.height).integral)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAccessibility.post(element: p, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            p.animator().alphaValue = 1
        }
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}

private struct ToastView: View {
    var text: String
    var symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.body.weight(.medium)).foregroundStyle(.secondary)
            Text(text).font(.body.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Drop highlight

/// Marks where a ⌘-dragged window or chip will land.
@MainActor
final class DropHighlight {
    static let shared = DropHighlight()
    private var panel: OverlayPanel?
    private var label = ""

    func show(_ rect: CGRect, label: String) {
        let p = panel ?? OverlayPanel(level: .floating)
        panel = p
        if label != self.label || p.contentView == nil {
            self.label = label
            p.contentView = NSHostingView(transparent: DropView(label: label))
        }
        p.place(ax: rect)
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct DropView: View {
    var label: String
    var body: some View {
        let radius = CGFloat(Preferences.shared.cornerRadius)
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.accent.opacity(0.18))
            RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.accent, lineWidth: 3)
            Text(label)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.accent))
        }
    }
}

// MARK: - Cards

/// Small cards near a window's title bar that offer a choice.
@MainActor
enum Cards {
    private static var panel: OverlayPanel?
    private static var closeWork: DispatchWorkItem?

    static func dismiss() {
        closeWork?.cancel()
        panel?.orderOut(nil)
    }

    private static func present<V: View>(_ view: V, under w: ManagedWindow, timeout: TimeInterval) {
        let p = panel ?? OverlayPanel(interactive: true, level: .floating)
        panel = p
        let size = p.setMaterialContent(view.onHover { inside in
            // Waits while the pointer is over it.
            if inside { closeWork?.cancel() } else { schedule(timeout / 2) }
        }, material: .popover, radius: 14)
        let f = w.element.frame ?? w.assigned ?? .zero
        p.place(ax: CGRect(x: f.midX - size.width / 2, y: f.minY + 40, width: size.width, height: size.height).integral)
        p.orderFrontRegardless()
        NSSound(named: "Tink")?.play()
        schedule(timeout)
    }

    private static func schedule(_ t: TimeInterval) {
        closeWork?.cancel()
        let work = DispatchWorkItem { dismiss() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: work)
    }

    static func confirmAlwaysFloat(_ rule: FloatRule, for w: ManagedWindow, on d: Display, confirm: @escaping () -> Void) {
        present(CardView(
            symbol: "pin",
            title: "Always float “\(rule.words)” windows?",
            detail: "\(rule.appName) windows whose title starts with these words will float.",
            actions: [
                .init(title: "Always Float", primary: true) { confirm(); dismiss() },
                .init(title: "Not Now") { dismiss() },
            ]
        ), under: w, timeout: 12)
    }

    static func needsRoom(for w: ManagedWindow, on d: Display) {
        let prefs = Preferences.shared
        guard !prefs.quietNeedsRoom.contains(w.appKey) else { return }
        let stampKey = "needsRoom." + w.appKey
        let last = UserDefaults.standard.double(forKey: stampKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: stampKey)

        let engine = Engine.shared
        var actions: [CardView.Action] = []
        let roomy = engine.displays.filter { $0.key != d.key && engine.roomDescription($0) != "full" }
        if let other = roomy.first {
            actions.append(.init(title: "Move to \(other.name)", primary: true) {
                w.mode = .tiled
                w.key = other.key
                engine.place(w, on: other, fresh: false)
                dismiss()
            })
        }
        let current = engine.models[d.key]?.tiles.count ?? 0
        if current >= 1 {
            let n = max(current, 1)
            actions.append(.init(title: "Use \(n) Window\(n == 1 ? "" : "s") Here", primary: roomy.isEmpty) {
                engine.setCount(n, on: d)
                // It becomes the main window.
                w.mode = .tiled
                var m = engine.models[d.key] ?? .init(capacity: n)
                m.setCapacity(n, mode: prefs.overflow)
                if m.tiles.count >= n, let last = m.tiles.last?.showing, let lw = engine.windows[last] {
                    m.remove(last, mode: .float)
                    lw.mode = .floated
                }
                m.add(w.id, active: nil, mode: .stack)
                if let i = m.tileIndex(of: w.id) { m.swap(i, 0) }
                engine.models[d.key] = m
                engine.retile(d.key)
                dismiss()
            })
        }
        actions.append(.init(title: "Keep Floating") { dismiss() })
        present(CardView(
            symbol: "arrow.up.left.and.arrow.down.right",
            title: "\(w.appName) needs more room",
            detail: "It can't get small enough for this layout, so it's floating.",
            actions: actions,
            footer: .init(title: "Don't Show Again for \(w.appName)") {
                prefs.quietNeedsRoom.append(w.appKey)
                dismiss()
            }
        ), under: w, timeout: 7)
    }
}

private struct CardView: View {
    struct Action {
        var title: String
        var primary = false
        var run: () -> Void
    }

    var symbol: String
    var title: String
    var detail: String
    var actions: [Action]
    var footer: Action? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                ForEach(Array(actions.enumerated().reversed()), id: \.offset) { _, a in
                    if a.primary {
                        Button(a.title, action: a.run).buttonStyle(.borderedProminent)
                    } else {
                        Button(a.title, action: a.run)
                    }
                }
            }
            if let footer {
                Button(footer.title, action: footer.run)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .controlSize(.small)
        .padding(16)
        .frame(width: 340)
    }
}

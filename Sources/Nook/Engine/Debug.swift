import AppKit
import NookKit

/// `nook://debug/<verb>` hooks for the end-to-end tests in scripts/e2e.swift.
/// They read state and drive input; none changes how tiling behaves.
@MainActor
enum Debug {
    static func handle(_ url: URL) {
        let verb = url.pathComponents.dropFirst().first ?? ""
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        switch verb {
        case "dump":
            if let path = q["path"] { write(dump(), to: path) }
        case "focus":
            let e = Engine.shared
            if let title = q["title"], let w = e.windows.values.first(where: { $0.element.title == title }) {
                e.focus(w)
            }
        case "drag":
            guard let from = point(q["from"]), let to = point(q["to"]) else { return }
            var flags: CGEventFlags = []
            for m in (q["mods"] ?? "").split(separator: ",") {
                switch m {
                case "cmd": flags.insert(.maskCommand)
                case "opt": flags.insert(.maskAlternate)
                case "ctrl": flags.insert(.maskControl)
                case "shift": flags.insert(.maskShift)
                default: break
                }
            }
            Task { await drag(from: from, to: to, flags: flags) }
        case "snapshot":
            if let dir = q["path"] { snapshot(into: dir) }
        case "pref":
            let p = Engine.shared.prefs
            let v = q["value"] ?? ""
            switch q["key"] {
            case "highlight": if let h = Highlight(rawValue: v) { p.highlight = h }
            case "overflow": if let o = OverflowMode(rawValue: v) { p.overflow = o }
            case "quickActions": p.quickActions = v == "1"
            case "gap": if let g = Double(v) { p.gap = g }
            default: break
            }
        case "panel":
            if q["open"] == "0" { StatusItem.shared?.close() } else { StatusItem.shared?.open() }
        case "hover":
            // Moves the pointer, so grips and the hover bar can be exercised.
            if let p = point(q["at"]) {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        default:
            NSLog("Nook: unknown debug verb \(verb)")
        }
    }

    private static func point(_ s: String?) -> CGPoint? {
        let parts = (s ?? "").split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }

    private static func write(_ object: Any, to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func rect(_ r: CGRect?) -> Any {
        guard let r else { return NSNull() }
        return [r.minX, r.minY, r.width, r.height].map { Double($0) }
    }

    static func dump() -> [String: Any] {
        let e = Engine.shared
        let p = e.prefs
        let screens: [[String: Any]] = e.displays.map { d in
            let model = e.models[d.key]
            let frames = e.tileFrames[d.key] ?? []
            return [
                "display": d.uuid,
                "name": d.name,
                "frame": rect(d.frame),
                "visible": rect(d.visible),
                "shape": d.shape.rawValue,
                "layout": e.layoutKind(for: d).rawValue,
                "capacity": e.capacity(for: d),
                "zoomed": e.zoomed[d.key].map { Int($0) } as Any,
                "customSizes": e.hasCustomSizes(d),
                "overflow": (model?.overflow ?? []).map { Int($0) },
                "tiles": (model?.tiles ?? []).enumerated().map { i, t in
                    [
                        "windows": t.order.map { Int($0) },
                        "showing": Int(t.showing),
                        "frame": rect(i < frames.count ? frames[i] : nil),
                    ] as [String: Any]
                },
            ]
        }
        let windows: [[String: Any]] = e.windows.values.sorted { $0.id < $1.id }.map { w in
            [
                "id": Int(w.id),
                "app": w.appName,
                "title": w.element.title ?? "",
                "mode": "\(w.mode)",
                "assigned": rect(w.assigned),
                "actual": rect(w.element.frame),
                "screen": w.key.display,
            ]
        }
        let v = Visuals.shared.counts
        return [
            "status": e.status.label,
            "trusted": e.trusted,
            "started": e.started,
            "active": e.activeID.map { Int($0) } as Any,
            "cleanSpace": e.cleanSpace.map { Array($0.windows).map { Int($0) } } as Any,
            "screens": screens,
            "windows": windows,
            "hotkeys": e.hotkeys.bindings.map { ["name": $0.command.name, "keys": $0.combo.display, "state": "\($0.state)"] },
            "visuals": v,
            "prefs": [
                "noPeek": p.noPeek, "highlight": p.highlight.rawValue, "gap": p.gap,
                "learned": p.learnedSizes.mapValues { [$0.width ?? 0, $0.height ?? 0] },
                "floatRules": p.floatRules.map { "\($0.appName): \($0.words)" },
            ],
            "hoverBarOpen": HoverBar.shared.isOpen,
            "tabViewOpen": TabView.shared.isOpen,
        ]
    }

    /// Presses, drags in small steps and releases, like a hand would.
    static func drag(from a: CGPoint, to b: CGPoint, flags: CGEventFlags) async {
        func post(_ type: CGEventType, _ p: CGPoint) {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, a)
        try? await Task.sleep(for: .milliseconds(80))
        post(.leftMouseDown, a)
        try? await Task.sleep(for: .milliseconds(80))
        let steps = 24
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .milliseconds(120))
        post(.leftMouseUp, b)
    }

    /// Writes every visible Nook window (panel, toasts, cards, grips…) to PNG.
    static func snapshot(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (i, w) in NSApp.windows.enumerated() where w.isVisible {
            guard let v = w.contentView, v.bounds.width > 0, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let name = String(describing: type(of: w))
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(i)-\(name).png"))
        }
    }
}

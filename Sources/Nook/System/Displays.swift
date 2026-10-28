import AppKit
import NookKit

/// Identifies one screen in one macOS Space.
struct ScreenKey: Hashable, Codable, CustomStringConvertible {
    var display: String
    var space: UInt64

    var description: String { "\(display)#\(space)" }
}

struct Display: Equatable {
    var id: CGDirectDisplayID
    var uuid: String
    var name: String
    /// Whole screen, AX coordinates.
    var frame: CGRect
    /// Below the menu bar and beside the Dock, AX coordinates.
    var visible: CGRect
    var space: UInt64

    var shape: ScreenShape { ScreenShape(size: visible.size) }
    var key: ScreenKey { ScreenKey(display: uuid, space: space) }

    var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    static func == (a: Display, b: Display) -> Bool {
        a.id == b.id && a.frame == b.frame && a.visible == b.visible && a.space == b.space
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var uuidString: String {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "\(displayID)" }
        return CFUUIDCreateString(nil, cf) as String
    }
}

enum Displays {
    private static let connection = CGSMainConnectionID()

    static func all() -> [Display] {
        NSScreen.screens.map { s in
            let uuid = s.uuidString
            return Display(
                id: s.displayID,
                uuid: uuid,
                name: s.localizedName,
                frame: Coords.flip(s.frame),
                visible: Coords.flip(s.visibleFrame),
                space: CGSManagedDisplayGetCurrentSpace(connection, uuid as CFString)
            )
        }
    }

    /// The display holding most of `rect` (AX coordinates), else the nearest one.
    static func containing(_ rect: CGRect, in displays: [Display]) -> Display? {
        let best = displays.max { a, b in
            area(a.frame.intersection(rect)) < area(b.frame.intersection(rect))
        }
        if let best, area(best.frame.intersection(rect)) > 0 { return best }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        return displays.min { distance($0.frame, c) < distance($1.frame, c) }
    }

    static func at(_ point: CGPoint, in displays: [Display]) -> Display? {
        displays.first { $0.frame.contains(point) }
            ?? displays.min { distance($0.frame, point) < distance($1.frame, point) }
    }

    /// The display next to `from` in `direction`, following System Settings → Displays → Arrange.
    static func neighbor(of from: Display, toward direction: Direction, in displays: [Display]) -> Display? {
        let f = from.frame
        let candidates = displays.filter { d in
            guard d.id != from.id else { return false }
            let g = d.frame
            switch direction {
            case .left: return g.midX < f.minX + 1 && overlaps(g.minY...g.maxY, f.minY...f.maxY)
            case .right: return g.midX > f.maxX - 1 && overlaps(g.minY...g.maxY, f.minY...f.maxY)
            case .up: return g.midY < f.minY + 1 && overlaps(g.minX...g.maxX, f.minX...f.maxX)
            case .down: return g.midY > f.maxY - 1 && overlaps(g.minX...g.maxX, f.minX...f.maxX)
            }
        }
        let c = CGPoint(x: f.midX, y: f.midY)
        return candidates.min { distance($0.frame, c) < distance($1.frame, c) }
            // Screens arranged diagonally still count as "that way".
            ?? displays.filter { d in
                guard d.id != from.id else { return false }
                switch direction {
                case .left: return d.frame.midX < f.midX
                case .right: return d.frame.midX > f.midX
                case .up: return d.frame.midY < f.midY
                case .down: return d.frame.midY > f.midY
                }
            }.min { distance($0.frame, c) < distance($1.frame, c) }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    private static func overlaps(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> Bool {
        a.lowerBound < b.upperBound - 1 && b.lowerBound < a.upperBound - 1
    }

    static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy) + hypot(r.midX - p.x, r.midY - p.y) * 0.001
    }
}

enum Direction: String, CaseIterable, Codable {
    case left, right, up, down
}

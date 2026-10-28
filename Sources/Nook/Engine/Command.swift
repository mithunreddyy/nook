import Foundation
import NookKit

/// Everything Nook can do, from any input: keys, mouse, menu or the `nook://` URL scheme.
enum Command: Hashable {
    case swap(Direction)
    case makePrimary
    case focusNext, focusPrevious
    case stackNext, stackPrevious
    case grow, shrink, resetSizes
    case toggleFloat, alwaysFloat
    case focusMode, noPeek, cleanSpace
    case retile
    case setCount(Int)
    case setLayout(LayoutKind)
    case cycleLayout
    case nextScreen
    case tabView(forward: Bool)
    case toggleTiling

    /// Stable name for activity counts and the URL scheme.
    var name: String {
        switch self {
        case .swap(let d): "swap-\(d.rawValue)"
        case .makePrimary: "primary"
        case .focusNext: "next"
        case .focusPrevious: "previous"
        case .stackNext: "stack-next"
        case .stackPrevious: "stack-previous"
        case .grow: "grow"
        case .shrink: "shrink"
        case .resetSizes: "reset"
        case .toggleFloat: "float"
        case .alwaysFloat: "always-float"
        case .focusMode: "focus"
        case .noPeek: "nopeek"
        case .cleanSpace: "cleanspace"
        case .retile: "retile"
        case .setCount(let n): "count-\(n)"
        case .setLayout(let l): "layout-\(l.rawValue)"
        case .cycleLayout: "cycle-layout"
        case .nextScreen: "next-screen"
        case .tabView: "tabview"
        case .toggleTiling: "toggle"
        }
    }

    var title: String {
        switch self {
        case .swap(.left): "Swap with the window on the left"
        case .swap(.right): "Swap with the window on the right"
        case .swap(.up): "Swap with the window above"
        case .swap(.down): "Swap with the window below"
        case .makePrimary: "Make the active window primary"
        case .focusNext: "Activate the next window"
        case .focusPrevious: "Activate the previous window"
        case .stackNext: "Show the next window in this tile"
        case .stackPrevious: "Show the previous window in this tile"
        case .grow: "Make the active window bigger"
        case .shrink: "Make the active window smaller"
        case .resetSizes: "Reset window sizes on this screen"
        case .toggleFloat: "Float the active window, or tile it again"
        case .alwaysFloat: "Always float windows like the active one"
        case .focusMode: "Focus mode"
        case .noPeek: "No peek mode"
        case .cleanSpace: "Clean Space"
        case .retile: "Retile"
        case .setCount(1): "Tile 1 window on this screen"
        case .setCount(let n): "Tile up to \(n) windows on this screen"
        case .setLayout(let l): "Use \(l.title) on this screen"
        case .cycleLayout: "Cycle this screen's layout"
        case .nextScreen: "Move to the next screen"
        case .tabView(true): "Tab View"
        case .tabView(false): "Tab View, moving backwards"
        case .toggleTiling: "Pause or resume tiling"
        }
    }

    /// Parses `nook://verb/argument`.
    init?(url: URL) {
        guard url.scheme == "nook" else { return nil }
        let verb = url.host ?? ""
        let arg = url.pathComponents.dropFirst().first
        switch verb {
        case "retile": self = .retile
        case "toggle": self = .toggleTiling
        case "primary": self = .makePrimary
        case "next": self = .focusNext
        case "previous", "prev": self = .focusPrevious
        case "stack-next": self = .stackNext
        case "stack-previous": self = .stackPrevious
        case "grow": self = .grow
        case "shrink": self = .shrink
        case "reset": self = .resetSizes
        case "float": self = .toggleFloat
        case "focus": self = .focusMode
        case "nopeek": self = .noPeek
        case "cleanspace": self = .cleanSpace
        case "next-screen": self = .nextScreen
        case "cycle-layout": self = .cycleLayout
        case "tabview": self = .tabView(forward: true)
        case "swap":
            guard let a = arg, let d = Direction(rawValue: a) else { return nil }
            self = .swap(d)
        case "layout":
            guard let a = arg, let l = LayoutKind(rawValue: a) else { return nil }
            self = .setLayout(l)
        case "count":
            guard let a = arg, let n = Int(a), (1...5).contains(n) else { return nil }
            self = .setCount(n)
        default: return nil
        }
    }
}

enum InputSource {
    case keyboard, mouse, both, script
}

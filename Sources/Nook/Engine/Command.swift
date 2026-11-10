import Foundation
import NookKit

/// Everything Nook can do, from any input: keys, mouse, menu or the `nook://` URL scheme.
enum Command: Hashable {
    case swap(Direction)
    case focus(Direction)
    case focusTile(Int)
    case search
    case saveWorkspace(String)
    case stackOnto(Direction)
    case popOut
    case toggleSplit
    case taller, shorter, evenHeights
    case cycleWidth
    case togglePin
    case notify(String, pid: Int32?)
    case focusApp(String)
    /// Tab View that stays open until you pick a window, without holding ⌥.
    case overview
    case loadWorkspace(String)
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
        case .focus(let d): "focus-\(d.rawValue)"
        case .focusTile(let n): "tile-\(n)"
        case .search: "search"
        case .saveWorkspace(let n): "workspace-save-\(n)"
        case .stackOnto(let d): "stack-onto-\(d.rawValue)"
        case .popOut: "pop"
        case .toggleSplit: "split"
        case .taller: "taller"
        case .shorter: "shorter"
        case .evenHeights: "even"
        case .cycleWidth: "width"
        case .togglePin: "pin"
        case .notify(let s, _): "notify-\(s)"
        case .focusApp(let a): "focus-app-\(a)"
        case .overview: "overview"
        case .loadWorkspace(let n): "workspace-\(n)"
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
        case .focus(.left): "Activate the window on the left"
        case .focus(.right): "Activate the window on the right"
        case .focus(.up): "Activate the window above"
        case .focus(.down): "Activate the window below"
        case .focusTile(1): "Activate the primary window"
        case .focusTile(let n): "Activate window \(n) on this screen"
        case .search: "Search windows"
        case .saveWorkspace(let n): "Save the workspace “\(n)”"
        case .stackOnto(.left): "Stack onto the window on the left"
        case .stackOnto(.right): "Stack onto the window on the right"
        case .stackOnto(.up): "Stack onto the window above"
        case .stackOnto(.down): "Stack onto the window below"
        case .popOut: "Take the window out of its stack"
        case .toggleSplit: "Show a stack split or as tabs"
        case .taller: "Make the window taller in its stack"
        case .shorter: "Make the window shorter in its stack"
        case .evenHeights: "Even out heights in the stack"
        case .cycleWidth: "Cycle the window's width (25–75%)"
        case .togglePin: "Pin the window to its place, or unpin it"
        case .notify(let s, _): "Flag the window: \(s)"
        case .focusApp(let a): "Go to \(a)"
        case .overview: "Overview of every window"
        case .loadWorkspace(let n): "Load the workspace “\(n)”"
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

    /// Commands that can have keys but have none by default.
    static let extras: [(Command, String)] = [
        (.toggleTiling, "More"),
        (.setLayout(.grid), "Layouts"),
        (.setLayout(.columns), "Layouts"),
        (.setLayout(.rows), "Layouts"),
        (.setLayout(.side), "Layouts"),
    ]

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
        case "focus":
            // nook://focus?app=Safari goes to an app's window; plain nook://focus is Focus mode.
            if let app = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "app" })?.value {
                self = .focusApp(app)
            } else {
                self = .focusMode
            }
        case "focus-app":
            guard let a = arg else { return nil }
            self = .focusApp(a)
        case "nopeek": self = .noPeek
        case "cleanspace": self = .cleanSpace
        case "next-screen": self = .nextScreen
        case "cycle-layout": self = .cycleLayout
        case "tabview": self = .tabView(forward: true)
        case "search": self = .search
        case "overview": self = .overview
        case "pop": self = .popOut
        case "split": self = .toggleSplit
        case "taller": self = .taller
        case "shorter": self = .shorter
        case "even": self = .evenHeights
        case "width": self = .cycleWidth
        case "pin": self = .togglePin
        case "stack-onto":
            guard let a = arg, let d = Direction(rawValue: a) else { return nil }
            self = .stackOnto(d)
        case "notify":
            // nook://notify/<success|failure|info>?pid=<a process in the job's terminal>
            let status = arg ?? "info"
            guard ["success", "failure", "info"].contains(status) else { return nil }
            let pid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pid" }?.value.flatMap { Int32($0) }
            self = .notify(status, pid: pid)
        case "workspace":
            // nook://workspace/save/<name>, nook://workspace/load/<name>
            let parts = Array(url.pathComponents.dropFirst())
            guard parts.count >= 2 else { return nil }
            let name = parts.dropFirst().joined(separator: "/")
            switch parts[0] {
            case "save": self = .saveWorkspace(name)
            case "load": self = .loadWorkspace(name)
            default: return nil
            }
        case "focus-to":
            guard let a = arg, let d = Direction(rawValue: a) else { return nil }
            self = .focus(d)
        case "tile":
            guard let a = arg, let n = Int(a), (1...5).contains(n) else { return nil }
            self = .focusTile(n)
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

import AppKit
import Carbon

struct KeyCombo: Hashable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier flags

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyCombo.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        names[Int(code)] ?? "Key \(code)"
    }

    private static let names: [Int: String] = {
        var n: [Int: String] = [
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_LeftBracket: "[", kVK_ANSI_Grave: "`",
            kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
        ]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"),
            (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
        ]
        for (k, v) in letters { n[k] = v }
        return n
    }()

    static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]

}

extension KeyCombo {
    /// A key press from the Settings recorder, or nil if it can't be a global shortcut.
    init?(event e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        // Needs ⌃, ⌥ or ⌘ (⇧ alone would eat capital letters), unless it's an F-key.
        guard m & UInt32(controlKey | optionKey | cmdKey) != 0 || Self.functionKeys.contains(Int(e.keyCode)) else { return nil }
        self.init(keyCode: UInt32(e.keyCode), modifiers: m)
    }
}

enum HotkeyState: Equatable {
    case active
    /// Another app registered these keys first.
    case inUse
    /// macOS keeps these keys for one of its own shortcuts.
    case leftToMacOS
}

struct HotkeyBinding: Identifiable {
    var command: Command
    var combo: KeyCombo
    var state: HotkeyState = .active
    var group: String

    var id: String { "\(command.name)|\(combo.keyCode)|\(combo.modifiers)" }
}

/// A command as the Shortcuts pane lists it.
struct ShortcutEntry: Identifiable {
    var command: Command
    var group: String
    var defaults: [KeyCombo]

    var id: String { command.name }
}

/// Global shortcuts through Carbon's RegisterEventHotKey: macOS delivers only
/// these combinations to Nook, and the press doesn't reach the app in front.
@MainActor
final class Hotkeys: ObservableObject {
    @Published private(set) var bindings: [HotkeyBinding] = []
    var onCommand: ((Command) -> Void)?

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var commands: [UInt32: Command] = [:]
    private var held: Set<UInt32> = []
    private var handler: EventHandlerRef?

    static func defaults(prefix: ShortcutPrefix, tabView: Bool) -> [HotkeyBinding] {
        let p: UInt32
        switch prefix {
        case .controlOption: p = UInt32(controlKey | optionKey)
        case .optionCommand: p = UInt32(optionKey | cmdKey)
        case .controlShift: p = UInt32(controlKey | shiftKey)
        }
        // Counts add ⌘ to the prefix; with a ⌘ prefix they add ⌃ instead.
        let count = p & UInt32(cmdKey) != 0 ? p | UInt32(controlKey) : p | UInt32(cmdKey)
        let shift = UInt32(shiftKey)
        // Focus by direction adds ⇧ to the prefix; with a ⇧ prefix it adds ⌘ instead.
        let toward = p & shift != 0 ? p | UInt32(cmdKey) : p | shift
        func b(_ c: Command, _ k: Int, _ m: UInt32, _ g: String) -> HotkeyBinding {
            HotkeyBinding(command: c, combo: KeyCombo(keyCode: UInt32(k), modifiers: m), group: g)
        }
        var list = [
            b(.swap(.left), kVK_LeftArrow, p, "Move"),
            b(.swap(.right), kVK_RightArrow, p, "Move"),
            b(.swap(.up), kVK_UpArrow, p, "Move"),
            b(.swap(.down), kVK_DownArrow, p, "Move"),
            b(.makePrimary, kVK_Return, p, "Activate"),
            b(.focusNext, kVK_ANSI_RightBracket, p, "Activate"),
            b(.focusPrevious, kVK_ANSI_LeftBracket, p, "Activate"),
            b(.stackNext, kVK_ANSI_Grave, p, "Activate"),
            b(.stackPrevious, kVK_ANSI_Grave, p | shift, "Activate"),
            b(.grow, kVK_ANSI_Equal, p, "Size"),
            b(.shrink, kVK_ANSI_Minus, p, "Size"),
            b(.resetSizes, kVK_ANSI_0, p, "Size"),
            b(.toggleFloat, kVK_ANSI_F, p, "More"),
            b(.alwaysFloat, kVK_ANSI_F, p | shift, "More"),
            b(.focusMode, kVK_ANSI_Z, p, "More"),
            b(.noPeek, kVK_ANSI_D, p, "More"),
            b(.cleanSpace, kVK_ANSI_P, p, "More"),
            b(.retile, kVK_ANSI_R, p, "More"),
            b(.cycleLayout, kVK_ANSI_L, p, "More"),
            b(.nextScreen, kVK_ANSI_N, p, "More"),
            b(.setCount(1), kVK_ANSI_1, count, "Windows per screen"),
            b(.setCount(2), kVK_ANSI_2, count, "Windows per screen"),
            b(.setCount(3), kVK_ANSI_3, count, "Windows per screen"),
            b(.setCount(4), kVK_ANSI_4, count, "Windows per screen"),
            b(.setCount(5), kVK_ANSI_5, count, "Windows per screen"),
        ]
        list += [
            b(.focus(.left), kVK_LeftArrow, toward, "Activate"),
            b(.focus(.right), kVK_RightArrow, toward, "Activate"),
            b(.focus(.up), kVK_UpArrow, toward, "Activate"),
            b(.focus(.down), kVK_DownArrow, toward, "Activate"),
            b(.search, kVK_ANSI_S, p, "Activate"),
        ]
        list += [
            b(.stackOnto(.left), kVK_LeftArrow, count, "Stacks"),
            b(.stackOnto(.right), kVK_RightArrow, count, "Stacks"),
            b(.stackOnto(.up), kVK_UpArrow, count, "Stacks"),
            b(.stackOnto(.down), kVK_DownArrow, count, "Stacks"),
            b(.popOut, kVK_ANSI_O, p, "Stacks"),
            b(.toggleSplit, kVK_ANSI_T, p, "Stacks"),
            b(.taller, kVK_ANSI_Equal, toward, "Stacks"),
            b(.shorter, kVK_ANSI_Minus, toward, "Stacks"),
            b(.evenHeights, kVK_ANSI_E, p, "Stacks"),
            b(.cycleWidth, kVK_ANSI_W, p, "Size"),
            b(.togglePin, kVK_ANSI_P, toward, "More"),
            b(.overview, kVK_ANSI_O, toward, "Activate"),
        ]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
        list += digits.enumerated().map { b(.focusTile($0 + 1), $1, p, "Jump to a window") }
        if tabView {
            list.insert(b(.tabView(forward: true), kVK_Tab, UInt32(optionKey), "Activate"), at: 9)
            list.insert(b(.tabView(forward: false), kVK_Tab, UInt32(optionKey) | shift, "Activate"), at: 10)
        }
        return list
    }

    /// Every command with keys, in pane order, with its default keys.
    static func catalog(prefix: ShortcutPrefix, tabView: Bool) -> [ShortcutEntry] {
        var out: [ShortcutEntry] = []
        for b in defaults(prefix: prefix, tabView: tabView) {
            if let i = out.firstIndex(where: { $0.command == b.command }) { out[i].defaults.append(b.combo) }
            else { out.append(ShortcutEntry(command: b.command, group: b.group, defaults: [b.combo])) }
        }
        for (c, g) in Command.extras { out.append(ShortcutEntry(command: c, group: g, defaults: [])) }
        return out
    }

    /// The keys in effect: chosen keys where set, else the defaults. Workspaces have keys only when chosen.
    static func bindings(prefix: ShortcutPrefix, tabView: Bool, custom: [String: [KeyCombo]], workspaces: [String]) -> [HotkeyBinding] {
        var list: [HotkeyBinding] = []
        for entry in catalog(prefix: prefix, tabView: tabView) {
            for k in custom[entry.command.name] ?? entry.defaults {
                list.append(HotkeyBinding(command: entry.command, combo: k, group: entry.group))
            }
        }
        for name in workspaces {
            let c = Command.loadWorkspace(name)
            for k in custom[c.name] ?? [] { list.append(HotkeyBinding(command: c, combo: k, group: "Workspaces")) }
        }
        return list
    }

    func install() {
        guard handler == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { hotkeys.fire(id.id, pressed: pressed) }
            return noErr
        }, specs.count, &specs, me, &handler)
    }

    /// Re-registers every shortcut, marking the ones that can't be had.
    func apply(enabled: Bool, prefix: ShortcutPrefix, tabView: Bool) {
        unregisterAll()
        let prefs = Preferences.shared
        var list = Self.bindings(prefix: prefix, tabView: tabView, custom: prefs.customShortcuts, workspaces: prefs.workspaces.map(\.name))
        let reserved = Self.systemShortcuts()
        for i in list.indices {
            let combo = list[i].combo
            if reserved.contains(combo) {
                list[i].state = .leftToMacOS
                continue
            }
            guard enabled else { continue }
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: OSType(0x4E4F4F4B), id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            if status == noErr, let ref {
                refs[id] = ref
                commands[id] = list[i].command
            } else {
                list[i].state = .inUse
            }
        }
        bindings = list
    }

    /// The keys of one command right now, active or not.
    func combos(for command: Command) -> [HotkeyBinding] {
        bindings.filter { $0.command == command }
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        commands.removeAll()
        held.removeAll()
    }

    var conflicts: [HotkeyBinding] { bindings.filter { $0.state == .inUse } }

    /// The keys for a command, only when they actually reach Nook.
    func combo(for command: Command) -> KeyCombo? {
        bindings.first { $0.command == command && $0.state == .active }?.combo
    }

    private func fire(_ id: UInt32, pressed: Bool) {
        guard pressed else { held.remove(id); return }
        guard let command = commands[id] else { return }
        // Tab View steps on every press; everything else acts once per hold.
        if case .tabView = command {} else {
            guard !held.contains(id) else { return }
            held.insert(id)
        }
        onCommand?(command)
    }

    /// Enabled macOS symbolic hotkeys (screenshots, Spaces, …).
    static func systemShortcuts() -> Set<KeyCombo> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var out = Set<KeyCombo>()
        for d in array {
            guard (d[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = d[kHISymbolicHotKeyCode as String] as? Int,
                  let mods = d[kHISymbolicHotKeyModifiers as String] as? Int else { continue }
            out.insert(KeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods) & UInt32(cmdKey | shiftKey | optionKey | controlKey)))
        }
        return out
    }

    static var secureInputActive: Bool { IsSecureEventInputEnabled() }
}

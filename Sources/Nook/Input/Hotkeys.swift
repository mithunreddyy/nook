import AppKit
import Carbon

struct KeyCombo: Hashable {
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
        switch Int(code) {
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_ANSI_RightBracket: "]"
        case kVK_ANSI_LeftBracket: "["
        case kVK_ANSI_Grave: "`"
        case kVK_ANSI_Equal: "="
        case kVK_ANSI_Minus: "-"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_N: "N"
        default: "?"
        }
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

    static func bindings(prefix: ShortcutPrefix, tabView: Bool) -> [HotkeyBinding] {
        let p: UInt32
        switch prefix {
        case .controlOption: p = UInt32(controlKey | optionKey)
        case .optionCommand: p = UInt32(optionKey | cmdKey)
        case .controlShift: p = UInt32(controlKey | shiftKey)
        }
        // Counts add ⌘ to the prefix; with a ⌘ prefix they add ⌃ instead.
        let count = p & UInt32(cmdKey) != 0 ? p | UInt32(controlKey) : p | UInt32(cmdKey)
        let shift = UInt32(shiftKey)
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
        if tabView {
            list.insert(b(.tabView(forward: true), kVK_Tab, UInt32(optionKey), "Activate"), at: 9)
            list.insert(b(.tabView(forward: false), kVK_Tab, UInt32(optionKey) | shift, "Activate"), at: 10)
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
        var list = Self.bindings(prefix: prefix, tabView: tabView)
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

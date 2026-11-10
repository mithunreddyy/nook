import AppKit
import Carbon
import SwiftUI

/// Records new keys for a command in Settings. Nook's own shortcuts are off
/// while it listens, so pressing one records it instead of running it.
@MainActor
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()

    struct Target: Equatable {
        var name: String
        var slot: Int
    }

    @Published private(set) var target: Target?
    private var defaults: [KeyCombo] = []
    private var monitor: Any?

    private var prefs: Preferences { Preferences.shared }

    func start(_ command: Command, slot: Int, defaults: [KeyCombo]) {
        stop()
        target = Target(name: command.name, slot: slot)
        self.defaults = defaults
        Engine.shared.hotkeys.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard target != nil else { return }
        target = nil
        Engine.shared.applyShortcuts()
    }

    func keys(for name: String, defaults: [KeyCombo]) -> [KeyCombo] {
        prefs.customShortcuts[name] ?? defaults
    }

    func remove(_ name: String, slot: Int, defaults: [KeyCombo]) {
        var k = keys(for: name, defaults: defaults)
        guard k.indices.contains(slot) else { return }
        k.remove(at: slot)
        prefs.customShortcuts[name] = k
    }

    func reset(_ name: String) {
        prefs.customShortcuts[name] = nil
    }

    private func handle(_ e: NSEvent) {
        guard let t = target else { return }
        let plain = e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if Int(e.keyCode) == kVK_Escape && plain { stop(); return }
        if (Int(e.keyCode) == kVK_Delete || Int(e.keyCode) == kVK_ForwardDelete) && plain {
            remove(t.name, slot: t.slot, defaults: defaults)
            stop()
            return
        }
        guard let combo = KeyCombo(event: e) else {
            NSSound.beep()
            return
        }
        // One action per key: take it from whatever had it.
        let prefixes = Preferences.shared
        for entry in Hotkeys.catalog(prefix: prefixes.prefix, tabView: prefixes.tabViewEnabled) where entry.command.name != t.name {
            let k = keys(for: entry.command.name, defaults: entry.defaults)
            if k.contains(combo) { prefs.customShortcuts[entry.command.name] = k.filter { $0 != combo } }
        }
        for (name, k) in prefs.customShortcuts where name != t.name && name.hasPrefix("workspace-") && k.contains(combo) {
            prefs.customShortcuts[name] = k.filter { $0 != combo }
        }
        var k = keys(for: t.name, defaults: defaults).filter { $0 != combo }
        if t.slot < k.count { k[t.slot] = combo } else { k.append(combo) }
        prefs.customShortcuts[t.name] = Array(k.prefix(2))
        stop()
    }
}

/// A command's keys (up to two) with ways to change, add, remove and reset them.
struct ShortcutField: View {
    var command: Command
    var defaults: [KeyCombo]
    @ObservedObject private var recorder = ShortcutRecorder.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var hotkeys = Engine.shared.hotkeys

    var body: some View {
        let keys = recorder.keys(for: command.name, defaults: defaults)
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { i, combo in
                chip(slot: i, combo: combo)
            }
            if keys.count < 2 {
                if recorder.target == .init(name: command.name, slot: keys.count) {
                    recordingChip
                } else {
                    Button {
                        recorder.start(command, slot: keys.count, defaults: defaults)
                    } label: {
                        Image(systemName: "plus").frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless)
                    .help(keys.isEmpty ? "Add a shortcut" : "Add a second shortcut")
                    .accessibilityLabel(keys.isEmpty ? "Add a shortcut for \(command.title)" : "Add a second shortcut for \(command.title)")
                }
            }
            if prefs.customShortcuts[command.name] != nil {
                Button {
                    recorder.reset(command.name)
                } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 14, height: 14)
                }
                .buttonStyle(.borderless)
                .help("Back to the default keys")
                .accessibilityLabel("Restore default keys for \(command.title)")
            }
        }
    }

    private var recordingChip: some View {
        Text("Type keys…")
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5))
            .help("Esc cancels. Delete removes the shortcut.")
    }

    @ViewBuilder
    private func chip(slot: Int, combo: KeyCombo) -> some View {
        if recorder.target == .init(name: command.name, slot: slot) {
            recordingChip
        } else {
            let state = hotkeys.bindings.first { $0.command == command && $0.combo == combo }?.state ?? .active
            HStack(spacing: 4) {
                switch state {
                case .leftToMacOS: Text("Used by macOS").font(.caption).foregroundStyle(.secondary)
                case .inUse: Text("In use").font(.caption).foregroundStyle(.orange)
                case .active: EmptyView()
                }
                Button(combo.display) { recorder.start(command, slot: slot, defaults: defaults) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .opacity(state == .active && prefs.shortcutsEnabled ? 1 : 0.5)
                    .help("Click, then type new keys")
                    .accessibilityLabel("Shortcut \(combo.display) for \(command.title). Click to change.")
                    .contextMenu {
                        Button("Remove") { recorder.remove(command.name, slot: slot, defaults: defaults) }
                    }
            }
        }
    }
}

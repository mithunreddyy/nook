import AppKit
import SwiftUI
import NookKit

/// First run: what Nook does, one permission, then your windows fall into place.
/// Nothing moves until Tidy My Workspace, and every step can be skipped.
@MainActor
final class Tour: NSObject, NSWindowDelegate {
    static let shared = Tour()
    private var window: NSWindow?
    let state = TourState()

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Welcome to Nook"
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: TourView(state: state, finish: { [weak self] in self?.finish() }))
            w.center()
            w.delegate = self
            window = w
        }
        if AX.isTrusted, state.step == .access { state.step = .ready }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Access arrived while the tour is open: move on, and bring it forward.
    func accessGranted() {
        guard isVisible || !Preferences.shared.setupComplete else { return }
        if state.step == .access || state.step == .welcome { state.step = .ready }
        show()
    }

    /// Starts tiling, then moves on to trying the keys.
    fileprivate func finish() {
        let prefs = Preferences.shared
        prefs.setupComplete = true
        prefs.tilingEnabled = true
        Haptics.success()
        Engine.shared.refreshStatus()
        state.practised = []
        state.step = .practice
    }

    fileprivate func close() {
        window?.close()
    }

    /// Ticks off a shortcut on the last step when it's used.
    func practised(_ command: Command) {
        guard isVisible, state.step == .practice, let task = PracticeTask.all.first(where: { $0.matches(command) }) else { return }
        if state.practised.insert(task.id).inserted {
            Haptics.tap()
            if state.practised.count == PracticeTask.all.count { Haptics.success() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Closing after access is granted counts as done: Nook shouldn't sit idle.
        if AX.isTrusted && !Preferences.shared.setupComplete {
            Preferences.shared.setupComplete = true
            Engine.shared.refreshStatus()
        }
        DispatchQueue.main.async {
            if !(NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

enum TourStep: Int, CaseIterable {
    case welcome, access, ready, practice
}

/// One shortcut to try on the tour's last step.
struct PracticeTask: Identifiable {
    var id: String
    var title: String
    var command: Command
    var matches: (Command) -> Bool

    static let all: [PracticeTask] = [
        PracticeTask(id: "swap", title: "Swap with a neighbour", command: .swap(.right)) { if case .swap = $0 { true } else { false } },
        PracticeTask(id: "focus", title: "Move to a neighbour", command: .focus(.right)) { if case .focus = $0 { true } else { false } },
        PracticeTask(id: "tile", title: "Jump to window 1", command: .focusTile(1)) { if case .focusTile = $0 { true } else { false } },
        PracticeTask(id: "search", title: "Search windows", command: .search) { $0 == .search },
        PracticeTask(id: "zoom", title: "Focus mode", command: .focusMode) { $0 == .focusMode },
        PracticeTask(id: "tabview", title: "See every window", command: .tabView(forward: true)) { if case .tabView = $0 { true } else { false } },
    ]
}

@MainActor
final class TourState: ObservableObject {
    @Published var step: TourStep = .welcome
    @Published var openAtLogin = true
    @Published var practised: Set<String> = []
}

struct TourView: View {
    @ObservedObject var state: TourState
    var finish: () -> Void
    @ObservedObject private var engine = Engine.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch state.step {
                case .welcome: welcome
                case .access: access
                case .ready: ready
                case .practice: practice
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 40)
            footer
        }
        .frame(width: 560, height: 470)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.2), value: state.step)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 20) {
            SettleDemo().frame(width: 300, height: 190)
            VStack(spacing: 8) {
                Text("Welcome to Nook").font(.largeTitle.weight(.semibold))
                Text("Open a window and it gets a place. Close one and the rest fill the space.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var access: some View {
        VStack(spacing: 18) {
            Image(systemName: engine.trusted ? "checkmark.circle.fill" : "hand.raised.fill")
                .font(.system(size: 48))
                .foregroundStyle(engine.trusted ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
            VStack(spacing: 8) {
                Text(engine.trusted ? "Access Allowed" : "Allow Accessibility Access").font(.title.weight(.semibold))
                Text("macOS lets an app move other apps' windows only with Accessibility access. Nook reads where windows are and how big they are. Nothing else, and nothing leaves your Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !engine.trusted {
                VStack(spacing: 10) {
                    Button("Open Privacy Settings") { AX.prompt(); AX.openSettings() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Text("Turn on Nook in the list. This window moves on by itself.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Nook is already on but nothing happens") { Permissions.reset() }
                        .buttonStyle(.link)
                        .font(.callout)
                        .help("Removes Nook's old entry and opens Nook again, so macOS asks once more.")
                }
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ready When You Are").font(.title.weight(.semibold))
                Text("Pick how windows share a screen. You can change it any time from the menu bar.")
                    .foregroundStyle(.secondary)
            }
            Form {
                LabeledContent("Layout") {
                    LayoutPicker(selection: $prefs.layout, showsTitles: true)
                }
                Picker("Windows per screen", selection: $prefs.windowsPerScreen) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Open at login", isOn: $state.openAtLogin)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            HStack(spacing: 18) {
                hint("\(prefs.prefix.title) ←→↑↓", "Swap")
                hint("\(prefs.prefix.title) Z", "Focus")
                hint("⌥ ⇥", "All windows")
                hint("⌘-drag", "Swap by mouse")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Try the Keys").font(.title.weight(.semibold))
                Text("Each one ticks off when you use it. Keep this window open, then press them anywhere.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(PracticeTask.all) { task in
                    let done = state.practised.contains(task.id)
                    HStack(spacing: 12) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(done ? Color.green : Color.secondary)
                            .font(.title3)
                            .contentTransition(.symbolEffect(.replace))
                        Text(task.title)
                        Spacer()
                        Text(engine.hotkeys.combo(for: task.command)?.display ?? "No key")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(done ? "Done" : "Not yet")
                    if task.id != PracticeTask.all.last?.id { Divider() }
                }
            }
            Text("\(state.practised.count) of \(PracticeTask.all.count) done")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func hint(_ keys: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(keys).font(.callout.weight(.medium))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(TourStep.allCases, id: \.self) { s in
                    Circle()
                        .fill(s == state.step ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(state.step.rawValue + 1) of \(TourStep.allCases.count)")
            Spacer()
            switch state.step {
            case .welcome:
                Button("Skip") { state.step = engine.trusted ? .ready : .access }
                Button("Continue") { state.step = engine.trusted ? .ready : .access }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .access:
                Button("Back") { state.step = .welcome }
                Button("Continue") { state.step = .ready }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!engine.trusted)
            case .practice:
                Button(state.practised.count == PracticeTask.all.count ? "Done" : "Finish Later") { Tour.shared.close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .ready:
                Button("Back") { state.step = engine.trusted ? .welcome : .access }
                Button("Tidy My Workspace") {
                    LoginItem.set(state.openAtLogin)
                    finish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!engine.trusted)
            }
        }
        .controlSize(.large)
        .padding(20)
    }
}

/// A pile of windows settling into the fold.
private struct SettleDemo: View {
    @State private var settled = false

    var body: some View {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 190)
        let tiles = Solver(tree: Layouts.tree(.grid, shape: .standard, count: 3, main: 0.5), rect: rect.insetBy(dx: 6, dy: 6), gap: 6).solve().frames
        let piles: [CGRect] = [
            CGRect(x: 50, y: 30, width: 160, height: 110),
            CGRect(x: 80, y: 48, width: 150, height: 105),
            CGRect(x: 110, y: 66, width: 145, height: 100),
        ]
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6))
            ForEach(0..<3, id: \.self) { i in
                let f = (settled || reduce) ? tiles[i]! : piles[i]
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            ForEach([Color.red, .yellow, .green], id: \.self) { c in
                                Circle().fill(c.opacity(0.8)).frame(width: 6, height: 6)
                            }
                        }
                        .padding(7)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(i == 0 && settled ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: i == 0 && settled ? 1.5 : 1))
                    .shadow(color: .black.opacity(settled ? 0.04 : 0.15), radius: 6, y: 3)
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .accessibilityLabel("Three windows settling side by side")
        .onAppear {
            guard !reduce else { settled = true; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { settled = true }
            }
        }
        .onTapGesture {
            guard !reduce else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { settled.toggle() }
        }
    }
}

import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import NookKit

// MARK: - General

struct GeneralPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var engine = Engine.shared
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $prefs.tilingEnabled) {
                    Text("Tile windows automatically")
                    Text("Arrange windows as they open and close. Turn off to leave them where they are.")
                }
                Toggle("Open at login", isOn: Binding(get: { loginEnabled }, set: { on in
                    LoginItem.set(on)
                    loginEnabled = SMAppService.mainApp.status == .enabled
                }))
                LabeledContent("Welcome tour") {
                    Button("Show Tour") { Tour.shared.show() }
                }
            }
            Section {
                LabeledContent {
                    if engine.trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        HStack {
                            Button("Re-add Nook") { Permissions.reset() }
                            Button("Open Privacy Settings") { AX.prompt(); AX.openSettings() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } label: {
                    Text("Accessibility access")
                    Text(engine.trusted
                         ? "Nook can move and resize windows."
                         : "Turn on Nook in Privacy & Security → Accessibility. If it's already on, choose Re-add Nook.")
                }
            }
            Section("App Icon") {
                HStack(spacing: 14) {
                    ForEach(IconStyle.allCases, id: \.self) { style in
                        let on = prefs.iconStyle == style
                        Button {
                            prefs.iconStyle = style
                            AppIcon.apply(style)
                        } label: {
                            VStack(spacing: 4) {
                                Image(nsImage: AppIcon.image(style, size: 96)).resizable().frame(width: 48, height: 48)
                                Text(style.title).font(.caption).foregroundStyle(on ? .primary : .secondary)
                            }
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.accentColor.opacity(0.15) : .clear))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(style.title) icon")
                        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
            return true
        }
    }
}

// MARK: - Layout

struct LayoutPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    LayoutPicker(selection: $prefs.layout, showsTitles: true)
                } label: {
                    Text("Layout")
                    Text("Where every screen starts. A layout chosen for one screen in the menu bar wins there.")
                }
                Picker("Main window", selection: $prefs.mainSize) {
                    ForEach(MainSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Windows per screen", selection: $prefs.windowsPerScreen) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section {
                Picker(selection: $prefs.overflow) {
                    Text("Stack in the active tile").tag(OverflowMode.stack)
                    Text("Float in the middle").tag(OverflowMode.float)
                } label: {
                    Text("When a screen is full")
                    Text("Where a window goes when every tile is taken.")
                }
                Picker(selection: $prefs.moveIntoFull) {
                    ForEach(MoveIntoFull.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Moving to a full screen")
                    Text("What ⌃⌥-arrow and Next Screen do when the other screen is full.")
                }
            }
            Section("Spacing") {
                LabeledContent("Between windows") {
                    PointSlider(value: $prefs.gap, range: 0...24)
                }
                Toggle("Separate screen margin", isOn: $prefs.separateOuterGap)
                if prefs.separateOuterGap {
                    LabeledContent("Screen margin") {
                        PointSlider(value: $prefs.outerGap, range: 0...48)
                    }
                }
                GapPreview(inner: prefs.effectiveGap, outer: prefs.effectiveOuterGap, layout: prefs.layout,
                           main: prefs.mainSize.fraction, count: prefs.windowsPerScreen)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
}

/// A slider with its value in points beside it.
struct PointSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { "\(Int($0)) pt" }

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step).frame(width: 180)
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// The default layout drawn at the current spacing.
struct GapPreview: View {
    var inner: CGFloat
    var outer: CGFloat
    var layout: LayoutKind
    var main: Double
    var count: Int

    var body: some View {
        let size = CGSize(width: 256, height: 160)
        let scale: CGFloat = 0.174 // a 1470-point-wide screen at this size
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: outer * scale, dy: outer * scale)
        let n = min(count, Layouts.capacity(layout, shape: .standard, size: CGSize(width: 1470, height: 920)))
        let frames = Solver(tree: Layouts.tree(layout, shape: .standard, count: max(n, 1), main: main), rect: rect, gap: inner * scale).solve().frames
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.7))
            ForEach(frames.keys.sorted(), id: \.self) { i in
                let f = frames[i]!
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(i == 0 ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: i == 0 ? 1.5 : 1))
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15), value: inner)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15), value: outer)
        .accessibilityLabel("Preview of \(layout.title) with \(n) windows")
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @ObservedObject private var prefs = Preferences.shared
    private let presets = ["#5E81F4", "#34C759", "#FF9F0A", "#FF375F", "#BF5AF2", "#64D2FF"]

    var body: some View {
        Form {
            Section {
                Picker(selection: $prefs.highlight) {
                    ForEach(Highlight.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Highlight")
                    Text("Drawn in the space between windows, never over them.")
                }
                if prefs.highlight != .none {
                    LabeledContent("Color") { colorRow }
                    if prefs.highlight != .glowActive {
                        LabeledContent("Thickness") {
                            PointSlider(value: $prefs.borderThickness, range: 2...6)
                        }
                    }
                    LabeledContent("Corner radius") {
                        PointSlider(value: $prefs.cornerRadius, range: 0...26)
                    }
                }
            }
            Section("No Peek") {
                Toggle(isOn: $prefs.noPeek) {
                    Text("Fade other windows")
                    Text("Keeps the window you're in bright. \(Engine.shared.hotkeys.combo(for: .noPeek)?.display ?? "")")
                }
                LabeledContent("Dim amount") {
                    PointSlider(value: $prefs.dimAmount, range: 0.1...0.9, step: 0.05) { "\(Int($0 * 100))%" }
                }
                Toggle("Blur other windows", isOn: $prefs.blurOthers)
            }
            Section("Clean Space") {
                Picker("Background", selection: $prefs.cleanBackground) {
                    ForEach(CleanBackground.allCases, id: \.self) { b in
                        Label { Text(b.title) } icon: { Image(nsImage: GeneralPane.swatch(b.color)) }.tag(b)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var colorRow: some View {
        HStack(spacing: 8) {
            swatch(nil)
            ForEach(presets, id: \.self) { swatch($0) }
            ColorPicker("Custom color", selection: Binding(
                get: { Color(nsColor: NSColor(hex: prefs.customColor) ?? .systemBlue) },
                set: { prefs.customColor = NSColor($0).hexString; prefs.useAccentColor = false }
            ), supportsOpacity: false)
            .labelsHidden()
        }
    }

    private func swatch(_ hex: String?) -> some View {
        let on = hex == nil ? prefs.useAccentColor : (!prefs.useAccentColor && prefs.customColor.uppercased() == hex)
        let color = hex.flatMap(NSColor.init(hex:)) ?? .controlAccentColor
        return Button {
            if let hex { prefs.customColor = hex; prefs.useAccentColor = false } else { prefs.useAccentColor = true }
        } label: {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.primary.opacity(on ? 0.8 : 0), lineWidth: 2).padding(-3))
                .overlay { if hex == nil { Image(systemName: "a").font(.caption2.weight(.bold)).foregroundStyle(.white) } }
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(hex == nil ? "System accent color" : hex!)
        .accessibilityLabel(hex == nil ? "System accent color" : "Color \(hex!)")
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var hotkeys = Engine.shared.hotkeys

    var body: some View {
        Form {
            Section {
                Toggle("Keyboard shortcuts", isOn: $prefs.shortcutsEnabled)
                Picker(selection: $prefs.prefix) {
                    ForEach(ShortcutPrefix.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Modifier keys")
                    Text("Every shortcut starts with these.")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $prefs.tabViewEnabled) {
                    Text("Tab View")
                    Text("⌥⇥ shows every window, screen by screen.")
                }
            }
            if !hotkeys.conflicts.isEmpty {
                Section {
                    Label("Another app already uses \(hotkeys.conflicts.map(\.combo.display).joined(separator: ", ")). Try other modifier keys.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("Mouse") {
                Toggle(isOn: $prefs.quickActions) {
                    Text("Quick actions above windows")
                    Text("Rest on the bar above the active window.")
                }
                Toggle(isOn: $prefs.hoverFocus) {
                    Text("Focus follows the pointer")
                    Text("Waits a moment, and never while you type or drag.")
                }
                Toggle("Move the pointer with keyboard focus", isOn: $prefs.mouseFollowsFocus)
            }
            ForEach(["Move", "Activate", "Size", "More", "Windows per screen"], id: \.self) { group in
                let rows = hotkeys.bindings.filter { $0.group == group }
                if !rows.isEmpty {
                    Section(group) {
                        ForEach(rows) { b in
                            LabeledContent(b.command.title) {
                                HStack(spacing: 8) {
                                    switch b.state {
                                    case .leftToMacOS: Text("Used by macOS").font(.caption).foregroundStyle(.secondary)
                                    case .inUse: Text("In use").font(.caption).foregroundStyle(.orange)
                                    case .active: EmptyView()
                                    }
                                    ShortcutText(text: b.combo.display)
                                        .opacity(b.state == .active && prefs.shortcutsEnabled ? 1 : 0.5)
                                }
                            }
                        }
                    }
                }
            }
            Section("Mouse actions") {
                LabeledContent("Swap two windows", value: "⌘-drag onto another")
                LabeledContent("Add to a stack", value: "⌥⌘-drag onto another")
                LabeledContent("Resize", value: "Drag the edge between two")
                LabeledContent("Move to another screen", value: "Drag onto it")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apps

struct AppsPane: View {
    @ObservedObject private var prefs = Preferences.shared

    private var excluded: [(id: String, name: String, isDefault: Bool)] {
        let custom = prefs.excludedApps.map { (id: $0, name: Self.name(for: $0), isDefault: false) }
        let defaults = Preferences.defaultExclusions
            .filter { !prefs.removedDefaultExclusions.contains($0.0) }
            .map { (id: $0.0, name: $0.1, isDefault: true) }
        return custom + defaults
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        Form {
            Section {
                ForEach(excluded, id: \.id) { app in
                    HStack {
                        Image(nsImage: Self.icon(for: app.id)).resizable().frame(width: 20, height: 20)
                        Text(app.name)
                        if app.isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Remove") { prefs.setExcluded(app.id, false) }.controlSize(.small)
                    }
                }
            } header: {
                Text("Don't tile these apps")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add App…") { chooseApp() }
                }
            }
            Section {
                if prefs.floatRules.isEmpty {
                    Text("Press \(Engine.shared.hotkeys.combo(for: .alwaysFloat)?.display ?? "⌃⌥⇧F") on a dialog that keeps getting tiled.")
                        .foregroundStyle(.secondary)
                }
                ForEach(prefs.floatRules) { rule in
                    LabeledContent {
                        Button("Remove") { prefs.floatRules.removeAll { $0 == rule } }.controlSize(.small)
                    } label: {
                        Text("“\(rule.words)”")
                        Text(rule.appName)
                    }
                }
            } header: {
                Text("Always float these windows")
            }
            Section {
                let learned = prefs.learnedSizes.sorted { $0.value.appName < $1.value.appName }
                if learned.isEmpty {
                    Text("None yet. Nook learns an app's smallest size when it refuses to shrink.")
                        .foregroundStyle(.secondary)
                }
                ForEach(learned, id: \.key) { item in
                    LabeledContent {
                        Button("Forget") { prefs.learnedSizes[item.key] = nil }.controlSize(.small)
                    } label: {
                        Text(item.value.appName)
                        Text("\(item.value.width.map { "\(Int($0))" } ?? "Any") × \(item.value.height.map { "\(Int($0))" } ?? "Any") pt")
                    }
                }
            } header: {
                Text("Apps that can't shrink")
            } footer: {
                if !prefs.learnedSizes.isEmpty {
                    HStack { Spacer(); Button("Forget All") { prefs.learnedSizes = [:] } }
                }
            }
            if !prefs.quietNeedsRoom.isEmpty {
                Section("“Needs more room” notices turned off") {
                    ForEach(prefs.quietNeedsRoom, id: \.self) { id in
                        LabeledContent(Self.name(for: id)) {
                            Button("Show Again") { prefs.quietNeedsRoom.removeAll { $0 == id } }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Don't Tile"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { prefs.setExcluded(id, true) }
        }
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var message: String?

    private var cliPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/nook").path }

    var body: some View {
        let a = prefs.activity
        Form {
            Section {
                LabeledContent("Windows placed this week", value: "\(a.placed)")
                LabeledContent("Time saved", value: Self.duration(a.secondsSaved))
                LabeledContent("Keyboard / mouse", value: "\(Int(a.keyboard)) / \(Int(a.mouse))")
                Toggle(isOn: $prefs.countActivity) {
                    Text("Count activity")
                    Text("Numbers only, kept on this Mac. Never window titles or app names.")
                }
            } header: {
                Text("Activity")
            } footer: {
                HStack { Spacer(); Button("Reset Activity") { prefs.activity = Activity() } }
            }
            Section("Configuration") {
                LabeledContent {
                    HStack {
                        Button("Import…") { importConfig() }
                        Button("Export…") { export() }
                    }
                } label: {
                    Text("Settings file")
                    Text("JSON, for dotfiles or another Mac.")
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Scripting") {
                Text("Every action is a URL, so launchers and scripts can drive Nook.")
                    .foregroundStyle(.secondary)
                Text("open -g nook://layout/columns\nopen -g nook://count/2\nopen -g nook://swap/left")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                LabeledContent {
                    Button("Copy Install Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("sudo ln -sf '\(cliPath)' /usr/local/bin/nook", forType: .string)
                        message = "Install command copied. Paste it into Terminal."
                    }
                } label: {
                    Text("Command-line tool")
                    Text("Then run nook retile or nook layout side.")
                }
            }
            Section("Troubleshooting") {
                LabeledContent {
                    Button("Re-add Nook…") { Permissions.reset() }
                } label: {
                    Text("Accessibility switch is on but nothing happens")
                    Text("Removes Nook's old entry and opens Nook again, so macOS asks once more.")
                }
            }
        }
        .formStyle(.grouped)
    }

    static func duration(_ s: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s < 3600 ? [.minute, .second] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: TimeInterval(s)) ?? "\(s)s"
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "nook.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try prefs.exportConfig().write(to: url)
            message = "Saved to \(url.path)."
        } catch {
            message = "Couldn't save the file: \(error.localizedDescription)"
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try prefs.importConfig(Data(contentsOf: url))
            message = "Loaded \(url.lastPathComponent)."
        } catch {
            message = "That file isn't a Nook settings file."
        }
    }
}

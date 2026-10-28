import AppKit
import SwiftUI
import NookKit

/// The menu bar panel: status, this screen's layout, quick switches, then menu-style rows.
struct PanelView: View {
    var close: () -> Void
    @ObservedObject private var engine = Engine.shared
    @ObservedObject private var prefs = Preferences.shared
    private let display: Display? = Engine.shared.display(at: Coords.mouse)

    var body: some View {
        let _ = engine.revision
        VStack(alignment: .leading, spacing: 0) {
            header
            notices
            if let d = display, engine.canTile {
                Divider().padding(.vertical, 8)
                screen(d)
            }
            Divider().padding(.vertical, 8)
            switches
            Divider().padding(.vertical, 6)
            menuRows
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: Header

    private var statusColor: Color {
        switch engine.status {
        case .tiling: .green
        case .stageManager, .waitingForSetup: .orange
        case .paused: .secondary
        case .needsPermission: .red
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nook").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(engine.status.label).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Automatic tiling", isOn: $prefs.tilingEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help("Automatic tiling")
        }
    }

    @ViewBuilder
    private var notices: some View {
        if !engine.trusted {
            notice(icon: "hand.raised.fill", tint: .orange,
                   text: "Nook needs Accessibility access to arrange windows.") {
                Button("Open Privacy Settings") { AX.prompt(); AX.openSettings(); close() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Already Allowed? Re-add Nook") { Permissions.reset() }
                    .buttonStyle(.link).controlSize(.small)
            }
        } else if !prefs.setupComplete {
            notice(icon: "sparkles", tint: .accentColor, text: "Finish setup to start tiling.") {
                Button("Continue Setup") { close(); Tour.shared.show() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        if engine.secureInput {
            notice(icon: "lock.fill", tint: .secondary,
                   text: "Shortcuts are paused while another app uses secure input.") { EmptyView() }
        }
    }

    private func notice<Actions: View>(icon: String, tint: Color, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.body).frame(width: 18)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6)))
        .padding(.top, 10)
    }

    // MARK: This screen

    private func screen(_ d: Display) -> some View {
        let requested = engine.requestedCount(for: d)
        let maxCount = Layouts.maxCount(shape: d.shape)
        let reasons = (1...maxCount).map { engine.countUnavailableReason($0, on: d) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(d.name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if engine.hasCustomSizes(d) {
                    Button("Reset Sizes") { engine.resetSizes(d) }
                        .buttonStyle(.link).font(.subheadline)
                }
            }
            LayoutPreview(display: d)
            HStack {
                LayoutPicker(selection: Binding(get: { engine.layoutKind(for: d) }, set: { engine.setLayout($0, on: d) }), shape: d.shape)
                Spacer(minLength: 8)
                Picker("Windows", selection: Binding(get: { requested }, set: { engine.setCount($0, on: d) })) {
                    ForEach(1...maxCount, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Windows on this screen")
            }
            if let reason = reasons.indices.contains(requested - 1) ? reasons[requested - 1] : nil {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if let (n, reason) = reasons.enumerated().first(where: { $0.element != nil }).map({ ($0.offset + 1, $0.element!) }) {
                Text("\(n)+ unavailable: \(reason)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Switches

    private var switches: some View {
        VStack(alignment: .leading, spacing: 6) {
            switchRow("No Peek", systemImage: "eye.slash", isOn: $prefs.noPeek, keys: engine.hotkeys.combo(for: .noPeek)?.display)
            if prefs.noPeek {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: $prefs.dimAmount, in: 0.1...0.9).controlSize(.small)
                        .accessibilityLabel("Dim amount")
                    Image(systemName: "sun.max").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .padding(.leading, 26)
            }
            switchRow("Clean Space", systemImage: "rectangle.dashed", isOn: Binding(
                get: { engine.cleanSpace != nil }, set: { engine.setCleanSpace($0) }
            ), keys: engine.hotkeys.combo(for: .cleanSpace)?.display)
            switchRow("Borders", systemImage: "square.dashed", isOn: Binding(
                get: { prefs.highlight == .borderActive || prefs.highlight == .borderAll },
                set: { prefs.highlight = $0 ? .borderActive : .none }
            ), keys: nil)
            switchRow("Hover Focus", systemImage: "cursorarrow.motionlines", isOn: $prefs.hoverFocus, keys: nil)
            if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(), let id = app.bundleIdentifier {
                switchRow("Tile \(app.localizedName ?? "This App")", systemImage: "app.dashed", isOn: Binding(
                    get: { !prefs.isExcluded(id) }, set: { prefs.setExcluded(id, !$0) }
                ), keys: nil)
            }
        }
    }

    private func switchRow(_ title: String, systemImage: String, isOn: Binding<Bool>, keys: String?) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(title)
                Spacer()
                if let keys { ShortcutText(text: keys).font(.subheadline) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    // MARK: Menu rows

    private var menuRows: some View {
        VStack(spacing: 0) {
            row("Retile Windows", keys: engine.hotkeys.combo(for: .retile)?.display) { engine.run(.retile, from: .mouse) }
            row("Settings…", keys: "⌘,") { close(); SettingsWindow.shared.show() }
            if !engine.hotkeys.conflicts.isEmpty {
                row("Shortcut Conflicts…", keys: nil, icon: "exclamationmark.triangle") { close(); SettingsWindow.shared.show(page: .shortcuts) }
            }
            Divider().padding(.vertical, 4)
            row("Quit Nook", keys: "⌘Q") { NSApp.terminate(nil) }
        }
    }

    private func row(_ title: String, keys: String?, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if let icon { Image(systemName: icon).foregroundStyle(.orange) }
                Text(title)
                Spacer()
                if let keys { Text(keys).opacity(0.6) }
            }
        }
        .buttonStyle(MenuRowStyle())
    }
}

/// A miniature of the screen with each tiled window's app icon in its place.
struct LayoutPreview: View {
    var display: Display
    var width: CGFloat = 276
    @ObservedObject private var engine = Engine.shared

    var body: some View {
        let _ = engine.revision
        let scale = width / display.frame.width
        let height = display.frame.height * scale
        let model = engine.models[display.key]
        let frames = engine.tileFrames[display.key] ?? []
        let zoomedID = engine.zoomed[display.key]
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.7))
            if let model {
                ForEach(Array(model.tiles.enumerated()), id: \.offset) { i, tile in
                    if i < frames.count, let w = engine.windows[tile.showing] {
                        let f = frames[i].offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                        let active = tile.contains(engine.activeID ?? 0)
                        let dim = zoomedID != nil && zoomedID != w.id
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(active ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: active ? 2 : 1))
                            Image(nsImage: w.icon).resizable().frame(width: 22, height: 22)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if tile.isStack {
                                Text("\(tile.count)")
                                    .font(.caption2.weight(.bold)).monospacedDigit()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .background(Capsule().fill(Color.orange))
                                    .padding(3)
                            } else if zoomedID == w.id {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                    .padding(3).background(Circle().fill(Color.accentColor)).padding(3)
                            }
                        }
                        .opacity(dim ? 0.35 : 1)
                        .frame(width: f.width * scale, height: f.height * scale)
                        .offset(x: f.minX * scale, y: f.minY * scale)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(w.appName), tile \(i + 1)\(tile.isStack ? ", \(tile.count) windows" : "")\(active ? ", active" : "")")
                    }
                }
            }
            if model?.tiles.isEmpty ?? true {
                Text("No tiled windows").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layout of \(display.name)")
    }
}

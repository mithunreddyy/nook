import AppKit
import SwiftUI
import NookKit

/// Nook's interface is stock macOS: system type, semantic colors and system
/// controls. The one thing of its own is the fold, drawn by `LayoutGlyph`.
enum Theme {
    /// Corner radius of panels Nook floats over the desktop.
    static let panelRadius: CGFloat = 12
    static let stackColor = NSColor.systemOrange

    @MainActor static var accent: Color { Color(nsColor: Preferences.shared.accentNSColor) }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// A borderless, non-activating panel that floats above windows on every Space.
class OverlayPanel: NSPanel {
    init(rect: NSRect = .zero, interactive: Bool = false, level: NSWindow.Level = .normal) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = !interactive
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Positions the panel using an AX-space rect.
    func place(ax rect: CGRect) {
        let ns = Coords.flip(rect)
        if frame != ns { setFrame(ns, display: true) }
    }
}

extension NSWindow {
    /// Hosts SwiftUI on a system material, sized to fit. Returns the content size.
    @discardableResult
    func setMaterialContent<V: View>(_ view: V, material: NSVisualEffectView.Material = .popover, radius: CGFloat = Theme.panelRadius) -> CGSize {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = .roundedMask(radius: radius)
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        contentView = effect
        hasShadow = true
        return size
    }
}

extension NSImage {
    /// A stretchable rounded-rect mask for NSVisualEffectView.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension NSHostingView {
    convenience init(transparent root: Content) {
        self.init(rootView: root)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }
}

/// A picture of a layout, drawn the way its tiles fall: Nook's signature.
struct LayoutGlyph: View {
    var layout: LayoutKind
    var shape: ScreenShape = .standard
    var selected: Bool
    var size: CGSize? = nil

    var body: some View {
        let s = size ?? (shape == .vertical ? CGSize(width: 20, height: 28) : CGSize(width: 32, height: 21))
        let n = layout == .grid ? 4 : 3
        let tree = Layouts.tree(layout, shape: shape, count: n, main: 0.5)
        let frames = Solver(tree: tree, rect: CGRect(origin: .zero, size: s), gap: 1.5).solve().frames
        ZStack(alignment: .topLeading) {
            ForEach(frames.keys.sorted(), id: \.self) { i in
                let f = frames[i]!
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(i == 0 ? 1 : 0.55)) : AnyShapeStyle(.tertiary))
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
            }
        }
        .frame(width: s.width, height: s.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// A row of layout glyphs that behaves like a segmented picker.
struct LayoutPicker: View {
    @Binding var selection: LayoutKind
    var shape: ScreenShape = .standard
    var showsTitles = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LayoutKind.allCases, id: \.self) { l in
                let disabled = shape == .vertical && l == .columns
                let on = selection == l
                Button { selection = l } label: {
                    VStack(spacing: 4) {
                        LayoutGlyph(layout: l, shape: shape, selected: on)
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(on ? Color.accentColor.opacity(0.15) : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(on ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: on ? 1.5 : 1))
                        if showsTitles {
                            Text(l.title).font(.caption).foregroundStyle(on ? .primary : .secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.35 : 1)
                .help(l.title)
                .accessibilityLabel(l.title)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
    }
}

/// Menu-style rows: full-width, highlighted in the accent color on hover.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.body)
                .foregroundStyle(hover && enabled ? Color.white : Color.primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hover && enabled ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// A key combination, shown the way macOS menus show them.
struct ShortcutText: View {
    var text: String
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Shortcut \(text)"))
    }
}

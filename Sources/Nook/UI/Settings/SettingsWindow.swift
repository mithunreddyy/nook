import AppKit
import Combine
import SwiftUI

enum SettingsPage: String, CaseIterable {
    case general, layout, appearance, shortcuts, apps, advanced

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .layout: "rectangle.split.3x1"
        case .appearance: "paintbrush"
        case .shortcuts: "keyboard"
        case .apps: "square.grid.3x3"
        case .advanced: "slider.horizontal.3"
        }
    }

    /// Every pane shares one width. Heights are measured from each pane's
    /// content (Nook --snapshot); the long lists scroll inside the window.
    static let width: CGFloat = 620

    /// Rows some settings reveal (Thickness, Corner radius…), so the window grows with them.
    private static let row: CGFloat = 44

    @MainActor var height: CGFloat {
        let prefs = Preferences.shared
        switch self {
        case .general: return 440
        case .layout: return 676 + (prefs.separateOuterGap ? Self.row : 0)
        case .appearance:
            switch prefs.highlight {
            case .none: return 416
            case .glowActive: return 416 + Self.row * 2
            case .borderActive, .borderAll: return 416 + Self.row * 3
            }
        case .shortcuts: return 640
        case .apps: return 600
        case .advanced: return 660
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralPane()
        case .layout: LayoutPane()
        case .appearance: AppearancePane()
        case .shortcuts: ShortcutsPane()
        case .apps: AppsPane()
        case .advanced: AdvancedPane()
        }
    }

    var toolbarID: NSToolbarItem.Identifier { .init(rawValue) }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage = .general
}

/// The standard macOS settings window: a preference-style toolbar of panes,
/// the title following the pane, sized to each pane, last pane restored.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindow()
    private(set) var window: NSWindow?
    private let model = SettingsModel()
    private static let lastPaneKey = "settingsLastPane"
    private var refit: AnyCancellable?

    func show(page: SettingsPage? = nil) {
        if window == nil { build() }
        let start = page ?? SettingsPage(rawValue: UserDefaults.standard.string(forKey: Self.lastPaneKey) ?? "") ?? .general
        select(start, animate: window?.isVisible == true)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Builds the window and selects a pane without showing it (for snapshots).
    func prepare(_ page: SettingsPage) {
        if window == nil { build() }
        select(page, animate: false)
    }

    private func build() {
        let first = SettingsPage.general
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsPage.width, height: first.height),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SettingsRoot(model: model))
        // The window decides the size; the SwiftUI root fills it.
        host.sizingOptions = []
        w.contentView = host

        let toolbar = NSToolbar(identifier: "NookSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        w.toolbar = toolbar
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w

        // Settings that reveal more rows resize the window to match.
        let p = Preferences.shared
        refit = Publishers.Merge(p.$highlight.map { _ in () }, p.$separateOuterGap.map { _ in () })
            .dropFirst(2)
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.select(self.model.page)
            }
    }

    /// Shows a pane and fits the window to it, keeping the top edge in place.
    func select(_ page: SettingsPage, animate: Bool = true) {
        guard let window else { return }
        model.page = page
        window.title = page.title
        window.toolbar?.selectedItemIdentifier = page.toolbarID
        UserDefaults.standard.set(page.rawValue, forKey: Self.lastPaneKey)

        // Never taller than the screen: a long pane scrolls inside the window instead.
        let room = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let chrome = window.frame.height - window.contentLayoutRect.height
        let content = NSRect(x: 0, y: 0, width: SettingsPage.width, height: min(page.height, room - chrome - 40))
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        let animated = animate && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: true, animate: animated)
    }

    @objc private func toolbarSelect(_ item: NSToolbarItem) {
        if let page = SettingsPage(rawValue: item.itemIdentifier.rawValue) { select(page) }
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPage.allCases.map(\.toolbarID)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPage.allCases.map(\.toolbarID)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPage.allCases.map(\.toolbarID)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = SettingsPage(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = page.title
        item.toolTip = page.title
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
        item.target = self
        item.action = #selector(toolbarSelect(_:))
        return item
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar-only app once nothing's open.
        DispatchQueue.main.async {
            if !Tour.shared.isVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

/// Fills the window with the current pane.
private struct SettingsRoot: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        model.page.content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(model.page)
    }
}

extension Bundle {
    var version: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev" }
}

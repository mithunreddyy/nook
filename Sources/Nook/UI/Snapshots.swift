import AppKit
import SwiftUI

/// `Nook --snapshot <dir>` renders each surface to PNG, for checking the design
/// without screen-recording access. Materials can't be captured offscreen, so
/// surfaces are drawn on the window background color instead.
@MainActor
enum Snapshots {
    static func run(into dir: String) {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            NSApp.appearance = NSAppearance(named: appearance)
            render(PanelView(close: {}), "panel-\(suffix)", dir)
            // The real window, frame and toolbar included, so clipping shows up.
            for page in SettingsPage.allCases {
                SettingsWindow.shared.prepare(page)
                guard let w = SettingsWindow.shared.window, let frameView = w.contentView?.superview else { continue }
                w.appearance = NSApp.appearance
                frameView.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/settings-\(page.rawValue)-\(suffix).png"))
                }
            }
            for step in TourStep.allCases {
                let state = TourState()
                state.step = step
                render(TourView(state: state, finish: {}), "tour-\(step.rawValue)-\(suffix)", dir)
            }
        }
    }

    private static func render<V: View>(_ view: V, _ name: String, _ dir: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let s = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: s), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApp.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: s)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}

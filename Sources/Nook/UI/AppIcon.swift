import AppKit

/// The app icon, drawn in code: the fold (one tall pane, two stacked) on a
/// flat tile. Each style is a palette.
enum AppIcon {
    private struct Palette {
        var background: NSColor
        var pane: NSColor
        var primary: NSColor
        var edge: NSColor
    }

    private static func palette(_ s: IconStyle) -> Palette {
        func c(_ hex: String) -> NSColor { NSColor(hex: hex)! }
        switch s {
        case .graphite: return Palette(background: c("#16181D"), pane: c("#2A2E37"), primary: c("#7AA2F7"), edge: c("#3B4150"))
        case .paper: return Palette(background: c("#F3F1EC"), pane: c("#DEDAD1"), primary: c("#2B2B2B"), edge: c("#C9C4B8"))
        case .terminal: return Palette(background: c("#0B0F0C"), pane: c("#14201A"), primary: c("#9ECE6A"), edge: c("#1F3328"))
        case .ink: return Palette(background: c("#1A1F3C"), pane: c("#262D57"), primary: c("#C0CAF5"), edge: c("#353E73"))
        case .ember: return Palette(background: c("#1E1714"), pane: c("#33261F"), primary: c("#F29E4C"), edge: c("#4A372C"))
        }
    }

    static func image(_ style: IconStyle, size: CGFloat) -> NSImage {
        let p = palette(style)
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            // macOS icon grid: an 824/1024 rounded square, centered.
            let inset = size * 100 / 1024
            let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
            let radius = tile.width * 0.225
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = size * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            p.background.setFill()
            NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()

            p.edge.setStroke()
            let border = NSBezierPath(roundedRect: tile.insetBy(dx: size * 0.003, dy: size * 0.003), xRadius: radius, yRadius: radius)
            border.lineWidth = size * 0.006
            border.stroke()

            let area = tile.insetBy(dx: tile.width * 0.17, dy: tile.height * 0.19)
            let gap = area.width * 0.06
            let r = area.width * 0.045
            let leftW = (area.width - gap) * 0.52
            let rightW = area.width - leftW - gap
            let halfH = (area.height - gap) / 2
            let left = NSRect(x: area.minX, y: area.minY, width: leftW, height: area.height)
            let topRight = NSRect(x: left.maxX + gap, y: area.minY, width: rightW, height: halfH)
            let bottomRight = NSRect(x: left.maxX + gap, y: topRight.maxY + gap, width: rightW, height: halfH)

            p.primary.setFill()
            NSBezierPath(roundedRect: left, xRadius: r, yRadius: r).fill()
            p.pane.setFill()
            NSBezierPath(roundedRect: topRight, xRadius: r, yRadius: r).fill()
            NSBezierPath(roundedRect: bottomRight, xRadius: r, yRadius: r).fill()

            // A cursor-like underscore in the primary pane: a terminal at heart.
            p.background.withAlphaComponent(0.85).setFill()
            let bar = NSRect(x: left.minX + left.width * 0.18, y: left.maxY - left.height * 0.2, width: left.width * 0.34, height: left.height * 0.055)
            NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
            return true
        }
    }

    /// Sets the Dock image and the icon Finder shows for the app.
    static func apply(_ style: IconStyle) {
        let img = image(style, size: 512)
        NSApp.applicationIconImage = img
        NSWorkspace.shared.setIcon(style == .graphite ? nil : img, forFile: Bundle.main.bundlePath, options: [])
    }

    /// Writes a PNG, used by the build script to produce the .icns.
    static func writePNG(_ style: IconStyle, size: Int, to path: String) throws {
        let img = image(style, size: CGFloat(size))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

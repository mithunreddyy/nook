import AppKit
import NookKit

/// Stacks shown split (rows) or as tabs, widths, pins, job flags and "go to app".
extension Engine {
    /// Most windows one tile holds when stacked on purpose.
    static let stackLimit = 5
    static let widthSteps: [CGFloat] = [0.25, 0.33, 0.5, 0.66, 0.75]

    /// The active tiled window with its screen, model and tile index.
    private var activeSpot: (w: ManagedWindow, d: Display, model: ScreenModel, i: Int)? {
        guard let w = activeTiled, let d = display(for: w.key), let model = models[w.key], let i = model.tileIndex(of: w.id) else { return nil }
        return (w, d, model, i)
    }

    // MARK: - Stacks

    /// Puts the active window into the tile that way, shown split (one above the other).
    func stackOnto(_ dir: Direction) {
        guard let (w, d, model, i) = activeSpot, let frames = tileFrames[w.key], i < frames.count else { return }
        guard let j = Self.neighbor(of: i, toward: dir, in: frames), j < model.tiles.count else {
            Toast.show("No window that way", on: d)
            return
        }
        guard model.tiles[j].count < Self.stackLimit else {
            Toast.show("That stack is full (\(Self.stackLimit) windows)", on: d)
            return
        }
        endFocusMode(on: w.key)
        var m = model
        m.stack(w.id, onto: j)
        if let t = m.tileIndex(of: w.id) { m.setSplit(tile: t, true) }
        models[w.key] = m
        retile(w.key)
        focus(w)
    }

    /// Takes the active window out of its stack into its own tile, adding a tile if the screen allows.
    func popOut() {
        guard let (w, d, model, i) = activeSpot else { return }
        guard model.tiles[i].isStack else {
            Toast.show("This window isn't in a stack", on: d)
            return
        }
        var m = model
        if !m.pop(w.id) {
            let n = m.tiles.count + 1
            if let why = countUnavailableReason(n, on: d) ?? (n > 5 ? "No room for another window" : nil) {
                Toast.show(why, on: d)
                return
            }
            var c = choice(for: d)
            c.count = n
            prefs.screenChoices[choiceKey(d)] = c
            m.setCapacity(capacity(for: d), mode: prefs.overflow)
            guard m.pop(w.id) else { return }
        }
        endFocusMode(on: w.key)
        models[w.key] = m
        retile(w.key)
        focus(w)
    }

    func toggleSplit() {
        guard let (w, d, model, i) = activeSpot else { return }
        guard model.tiles[i].isStack else {
            Toast.show("This window isn't in a stack", on: d)
            return
        }
        var m = model
        m.toggleSplit(tile: i)
        models[w.key] = m
        retile(w.key)
        if !m.tiles[i].split { raiseShowing(on: w.key) }
        Toast.show(m.tiles[i].split ? "Stack split: every window shows" : "Stack as tabs: one window shows", on: d,
                   symbol: m.tiles[i].split ? "rectangle.split.1x2" : "rectangle.stack")
    }

    func resizeRow(by step: CGFloat) {
        guard let (w, d, model, i) = activeSpot, let frames = tileFrames[w.key], i < frames.count else { return }
        guard model.tiles[i].split else {
            Toast.show("Taller and shorter work in a split stack", on: d)
            return
        }
        var m = model
        var moved = false
        m.edit(tile: i) { moved = $0.resizeRow(w.id, by: step, in: frames[i], gap: prefs.effectiveGap) }
        guard moved else {
            NSSound.beep()
            return
        }
        models[w.key] = m
        retile(w.key)
    }

    func evenHeights() {
        guard let (w, _, model, i) = activeSpot, model.tiles[i].split else { return }
        var m = model
        m.edit(tile: i) { $0.evenRows() }
        models[w.key] = m
        retile(w.key)
    }

    /// Moves the active window up or down inside its split stack. False when it can't.
    func moveInStack(_ dir: Direction) -> Bool {
        guard dir == .up || dir == .down, let (w, _, model, i) = activeSpot, model.tiles[i].split else { return false }
        var m = model
        guard m.moveInTile(w.id, by: dir == .up ? -1 : 1) else { return false }
        models[w.key] = m
        retile(w.key)
        return true
    }

    /// The window above or below the active one in its split stack.
    func rowNeighbor(_ dir: Direction) -> ManagedWindow? {
        guard dir == .up || dir == .down, let (w, _, model, i) = activeSpot, model.tiles[i].split else { return nil }
        let order = model.tiles[i].order
        guard let r = order.firstIndex(of: w.id) else { return nil }
        let next = r + (dir == .up ? -1 : 1)
        return order.indices.contains(next) ? windows[order[next]] : nil
    }

    // MARK: - Widths

    /// Steps the active window through 25, 33, 50, 66 and 75 percent of the screen's width.
    func cycleWidth() {
        guard let (w, d, _, _) = activeSpot else { return }
        let p = plan(d)
        guard let tree = p.tree, let i = p.model.tileIndex(of: w.id), i < p.frames.count else { return }
        let frame = p.frames[i]
        let now = frame.width / p.rect.width
        let next = Self.widthSteps.first { $0 > now + 0.02 } ?? Self.widthSteps[0]
        let target = (p.rect.width * next).rounded()
        let solver = Solver(tree: tree, rect: p.rect, gap: prefs.effectiveGap, weights: prefs.weights[p.weightKey] ?? [:], minimums: p.minimums)
        // Move whichever side has a neighbour.
        let (edge, x): (NookKit.Edge, CGFloat) = frame.maxX < p.rect.maxX - 1 ? (.right, frame.minX + target) : (.left, frame.maxX - target)
        let (weights, ok) = solver.moving(tile: i, edge: edge, to: x)
        guard ok else {
            Toast.show(p.frames.count == 1 ? "A single window fills the screen" : "No room to change this width", on: d)
            return
        }
        endFocusMode(on: w.key)
        prefs.weights[p.weightKey] = weights
        retile(w.key)
        Toast.show("Width \(Int((next * 100).rounded()))%", on: d, symbol: "arrow.left.and.right")
    }

    /// Gives a newly opened window's tile its app's default width, if it has one.
    func applyDefaultWidth(_ w: ManagedWindow) {
        guard let share = prefs.appRules.first(where: { $0.bundleID == w.bundleID })?.width, let d = display(for: w.key) else { return }
        let p = plan(d)
        guard let tree = p.tree, let i = p.model.tileIndex(of: w.id), i < p.frames.count, p.frames.count > 1 else { return }
        let frame = p.frames[i]
        let target = (p.rect.width * CGFloat(share)).rounded()
        let solver = Solver(tree: tree, rect: p.rect, gap: prefs.effectiveGap, weights: prefs.weights[p.weightKey] ?? [:], minimums: p.minimums)
        let (edge, x): (NookKit.Edge, CGFloat) = frame.maxX < p.rect.maxX - 1 ? (.right, frame.minX + target) : (.left, frame.maxX - target)
        let (weights, ok) = solver.moving(tile: i, edge: edge, to: x)
        if ok {
            prefs.weights[p.weightKey] = weights
            retile(w.key)
        }
    }

    // MARK: - Pins

    func togglePin() {
        guard let (w, d, model, i) = activeSpot else { return }
        var m = model
        if m.isPinned(w.id) {
            m.unpin(w.id)
            Toast.show("Unpinned", on: d, symbol: "pin.slash")
        } else {
            m.pin(w.id)
            Toast.show("Pinned to place \(i + 1) · new and closed windows go around it", on: d, symbol: "pin")
        }
        models[w.key] = m
        Visuals.shared.update()
        bump()
    }

    // MARK: - Scripting

    /// Flags a window when a job finishes: the window of the terminal that ran it if `pid` is
    /// given, else the active one. The flag stays until you go to that window.
    func notify(_ status: String, pid: Int32?) {
        var target: ManagedWindow?
        if let pid {
            for p in Self.ancestors(of: pid) {
                if let w = recent.compactMap({ windows[$0] }).first(where: { $0.pid == p }) ?? windows.values.first(where: { $0.pid == p }) {
                    target = w
                    break
                }
            }
        }
        guard let w = target ?? activeWindow else { return }
        let color: NSColor = status == "success" ? .systemGreen : status == "failure" ? .systemRed : .systemBlue
        if w.id != activeID { Visuals.shared.flag(w.id, color: color) }
        let text = status == "success" ? "Done in \(w.appName)" : status == "failure" ? "Failed in \(w.appName)" : "Finished in \(w.appName)"
        Toast.show(text, on: display(for: w.key), symbol: status == "failure" ? "xmark.circle" : "checkmark.circle")
    }

    /// A process and its parents, up to launchd.
    static func ancestors(of pid: Int32) -> [Int32] {
        var out: [Int32] = []
        var p = pid
        while p > 1 && out.count < 32 {
            out.append(p)
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, p]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            p = info.kp_eproc.e_ppid
        }
        return out
    }

    /// Goes to an app's most recent window by name or bundle ID, opening the app if it isn't running.
    func focusApp(_ query: String) {
        let q = query.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && ($0.localizedName?.lowercased() == q || $0.bundleIdentifier?.lowercased() == q)
        }
        if let app = apps.first {
            let pid = app.processIdentifier
            if let w = recent.compactMap({ windows[$0] }).first(where: { $0.pid == pid }) ?? windows.values.first(where: { $0.pid == pid }) {
                focus(w, keyboard: true)
            } else {
                app.unhide()
                app.activate(from: .current, options: [])
            }
            return
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query)
            ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
                .map { URL(fileURLWithPath: $0).appendingPathComponent(query + ".app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url else {
            Toast.show("No app named “\(query)”", on: currentDisplay)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

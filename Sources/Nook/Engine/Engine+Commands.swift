import AppKit
import NookKit

struct CleanSpaceState: Equatable {
    var key: ScreenKey
    /// Windows sharing the plain screen.
    var windows: Set<CGWindowID>
    /// The order they joined, so the first stays primary.
    var order: [CGWindowID] = []
}

extension Engine {
    var activeWindow: ManagedWindow? { activeID.flatMap { windows[$0] } }

    /// The active window if it's tiled.
    var activeTiled: ManagedWindow? {
        guard let w = activeWindow, w.mode == .tiled, models[w.key]?.tileIndex(of: w.id) != nil else { return nil }
        return w
    }

    func run(_ command: Command, from source: InputSource) {
        switch command {
        case .toggleTiling:
            prefs.tilingEnabled.toggle()
            return
        case .tabView(let forward):
            TabView.shared.press(forward: forward)
            return
        case .noPeek:
            prefs.noPeek.toggle()
            countUse(command, from: source)
            return
        case .cleanSpace:
            setCleanSpace(cleanSpace == nil)
            countUse(command, from: source)
            return
        default:
            break
        }
        guard canTile else { return }
        countUse(command, from: source)
        let keyboard = source == .keyboard

        switch command {
        case .swap(let dir): swap(toward: dir, keyboard: keyboard)
        case .makePrimary: makePrimary()
        case .focusNext: cycleFocus(by: 1, keyboard: keyboard)
        case .focusPrevious: cycleFocus(by: -1, keyboard: keyboard)
        case .stackNext: cycleStack(by: 1)
        case .stackPrevious: cycleStack(by: -1)
        case .grow: resizeActive(by: 48)
        case .shrink: resizeActive(by: -48)
        case .resetSizes: if let d = currentDisplay { resetSizes(d) }
        case .toggleFloat: toggleFloat()
        case .alwaysFloat: alwaysFloat()
        case .focusMode: toggleFocusMode()
        case .retile: retileCommand()
        case .setCount(let n): if let d = currentDisplay { setCount(n, on: d) }
        case .setLayout(let l): if let d = currentDisplay { setLayout(l, on: d) }
        case .cycleLayout:
            if let d = currentDisplay {
                var next = layoutKind(for: d).next
                if d.shape == .vertical && next == .columns { next = next.next }
                setLayout(next, on: d)
                Toast.show("\(next.title) · \(capacity(for: d)) windows", on: d)
            }
        case .nextScreen: moveActiveToNextScreen()
        case .noPeek, .cleanSpace, .toggleTiling, .tabView: break
        }
    }

    // MARK: - Focus

    func focus(_ w: ManagedWindow, keyboard: Bool = false) {
        AX.focus(w.element, pid: w.pid, wid: w.id)
        // Act on it straight away; a stale focus report won't undo this.
        focusRequest = (w.id, Date().addingTimeInterval(0.6))
        becameActive(w.id, element: w.element, pid: w.pid)
        if keyboard, prefs.mouseFollowsFocus, let f = w.element.frame {
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
        }
    }

    /// Visits tiled windows in layout order, screen by screen, left to right.
    func cycleFocus(by offset: Int, keyboard: Bool) {
        let order = displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
            .flatMap { models[$0.key]?.showing ?? [] }
        guard !order.isEmpty else { return }
        let i = activeID.flatMap { order.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        let next = order[((i + offset) % order.count + order.count) % order.count]
        if let w = windows[next] { focus(w, keyboard: keyboard) }
    }

    func cycleStack(by offset: Int) {
        guard let w = activeTiled, var model = models[w.key], let i = model.tileIndex(of: w.id) else { return }
        guard let next = model.cycle(tile: i, by: offset), let target = windows[next] else { return }
        models[w.key] = model
        focus(target)
        Visuals.shared.update()
        bump()
    }

    /// Shows a specific window of a stack (grip segments, chips, dots).
    func show(_ id: CGWindowID) {
        guard let w = windows[id] else { return }
        if var model = models[w.key] {
            model.show(id)
            models[w.key] = model
        }
        focus(w)
        Visuals.shared.update()
        bump()
    }

    // MARK: - Swapping

    func swap(toward dir: Direction, keyboard: Bool) {
        guard let w = activeTiled, let frames = tileFrames[w.key], let model = models[w.key],
              let i = model.tileIndex(of: w.id), i < frames.count else { return }
        endFocusMode(on: w.key)
        if let j = Self.neighbor(of: i, toward: dir, in: frames) {
            var m = model
            m.swap(i, j)
            models[w.key] = m
            retile(w.key)
            return
        }
        // Nothing that way on this screen: cross to the next screen.
        guard let d = display(for: w.key), let target = Displays.neighbor(of: d, toward: dir, in: displays) else { return }
        move(w, to: target, toward: dir, viaDrag: false)
    }

    /// The tile next to `i` in a direction: overlapping on the cross axis, nearest edge first,
    /// top-most (or left-most) on a tie.
    static func neighbor(of i: Int, toward dir: Direction, in frames: [CGRect]) -> Int? {
        let a = frames[i]
        let candidates = frames.indices.filter { j in
            guard j != i else { return false }
            let b = frames[j]
            switch dir {
            case .left: return b.midX < a.minX && b.maxY > a.minY + 1 && b.minY < a.maxY - 1
            case .right: return b.midX > a.maxX && b.maxY > a.minY + 1 && b.minY < a.maxY - 1
            case .up: return b.midY < a.minY && b.maxX > a.minX + 1 && b.minX < a.maxX - 1
            case .down: return b.midY > a.maxY && b.maxX > a.minX + 1 && b.minX < a.maxX - 1
            }
        }
        return candidates.min { x, y in
            let bx = frames[x], by = frames[y]
            func gap(_ b: CGRect) -> CGFloat {
                switch dir {
                case .left: a.minX - b.maxX
                case .right: b.minX - a.maxX
                case .up: a.minY - b.maxY
                case .down: b.minY - a.maxY
                }
            }
            let gx = gap(bx), gy = gap(by)
            if abs(gx - gy) > 1 { return gx < gy }
            return dir == .left || dir == .right ? bx.minY < by.minY : bx.minX < by.minX
        }
    }

    func makePrimary() {
        guard let w = activeTiled, var model = models[w.key], let i = model.tileIndex(of: w.id), i != 0 else { return }
        endFocusMode(on: w.key)
        model.swap(i, 0)
        models[w.key] = model
        retile(w.key)
    }

    /// Exchanges two tiled windows, on the same screen or across screens.
    func exchange(_ a: ManagedWindow, _ b: ManagedWindow) {
        guard var ma = models[a.key], let ia = ma.tileIndex(of: a.id) else { return }
        if a.key == b.key {
            guard let ib = ma.tileIndex(of: b.id) else { return }
            ma.swap(ia, ib)
            models[a.key] = ma
            retile(a.key)
            return
        }
        guard var mb = models[b.key], let ib = mb.tileIndex(of: b.id) else { return }
        _ = ma.replaceShowing(in: ia, with: b.id)
        _ = mb.replaceShowing(in: ib, with: a.id)
        let ka = a.key
        a.key = b.key
        b.key = ka
        models[a.key] = mb
        models[b.key] = ma
        retile(a.key)
        retile(b.key)
    }

    // MARK: - Moving between screens

    func moveActiveToNextScreen() {
        guard let w = activeTiled, let d = display(for: w.key), displays.count > 1 else { return }
        let sorted = displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        let i = sorted.firstIndex { $0.id == d.id } ?? 0
        let target = sorted[(i + 1) % sorted.count]
        let dir: Direction = target.frame.midX >= d.frame.midX ? .right : .left
        move(w, to: target, toward: dir, viaDrag: false)
    }

    /// Room left on a screen, for "Move to" menus.
    func roomDescription(_ d: Display) -> String {
        let used = models[d.key]?.tiles.count ?? 0
        let cap = capacity(for: d)
        return used >= cap ? "full" : "\(cap - used) free"
    }

    /// Moves a window into another screen's layout. Returns false if it stays put.
    @discardableResult
    func move(_ w: ManagedWindow, to target: Display, toward dir: Direction?, viaDrag: Bool, landing: CGPoint? = nil) -> Bool {
        guard w.key != target.key else { return false }
        endFocusMode(on: w.key)
        endFocusMode(on: target.key)
        var model = models[target.key] ?? ScreenModel(capacity: capacity(for: target))
        model.setCapacity(capacity(for: target), mode: prefs.overflow)

        if model.isFull && !model.tiles.isEmpty {
            if viaDrag {
                Toast.show("\(target.name) is full", on: target)
                return false
            }
            let frames = tileFrames[target.key] ?? plan(target).frames
            let source = w.element.frame ?? .zero
            let entry = landing ?? Self.entryPoint(into: target, from: source, toward: dir)
            let landed = frames.indices.min { Displays.distance(frames[$0], entry) < Displays.distance(frames[$1], entry) } ?? 0
            guard landed < model.tiles.count, let other = windows[model.tiles[landed].showing] else { return false }
            if prefs.moveIntoFull == .swap {
                exchange(w, other)
            } else {
                detach(w)
                w.key = target.key
                model.stack(w.id, onto: landed)
                models[target.key] = model
                retile(target.key)
            }
            return true
        }

        // Room in the count, but maybe not for this app at its minimum size.
        var trial = model
        trial.add(w.id, active: nil, mode: .float)
        let probe = plan(target, model: trial)
        if probe.floatOut.contains(w.id) {
            Toast.show("Not enough room on \(target.name) for \(w.appName)", on: target)
            return false
        }
        detach(w)
        w.key = target.key
        models[target.key] = trial
        retile(target.key)
        return true
    }

    static func entryPoint(into d: Display, from source: CGRect, toward dir: Direction?) -> CGPoint {
        let v = d.visible
        let y = min(max(source.midY, v.minY), v.maxY)
        let x = min(max(source.midX, v.minX), v.maxX)
        switch dir {
        case .left: return CGPoint(x: v.maxX, y: y)
        case .right: return CGPoint(x: v.minX, y: y)
        case .up: return CGPoint(x: x, y: v.maxY)
        case .down: return CGPoint(x: x, y: v.minY)
        case nil: return CGPoint(x: v.midX, y: v.midY)
        }
    }

    // MARK: - Sizes

    func resizeActive(by step: CGFloat) {
        guard let w = activeTiled, let d = display(for: w.key) else { return }
        let p = plan(d)
        guard let tree = p.tree, let i = p.model.tileIndex(of: w.id) else { return }
        let solver = Solver(tree: tree, rect: p.rect, gap: prefs.effectiveGap, weights: prefs.weights[p.weightKey] ?? [:], minimums: p.minimums)
        let (weights, moved) = solver.resizing(tile: i, by: step)
        guard moved else {
            NSSound.beep()
            Toast.show(step > 0 ? "Maximum size reached" : "Minimum size reached", on: d)
            return
        }
        endFocusMode(on: w.key)
        prefs.weights[p.weightKey] = weights
        retile(w.key)
    }

    /// Edge dragged by the mouse: move the matching boundaries to follow it.
    func resizeFromDrag(_ w: ManagedWindow, to frame: CGRect, live: Bool) {
        guard let d = display(for: w.key), let old = w.assigned else { return }
        let p = plan(d)
        guard let tree = p.tree, let i = p.model.tileIndex(of: w.id) else { return }
        var solver = Solver(tree: tree, rect: p.rect, gap: prefs.effectiveGap, weights: prefs.weights[p.weightKey] ?? [:], minimums: p.minimums)
        var moved = false
        for (edge, coordinate) in Solver.changedEdges(from: old, to: frame) {
            let (weights, ok) = solver.moving(tile: i, edge: edge, to: coordinate)
            if ok { solver.weights = weights; moved = true }
        }
        guard moved else {
            if !live { retile(w.key) }
            return
        }
        prefs.weights[p.weightKey] = solver.weights
        if live {
            layout(w.key, skipping: w.id)
            w.assigned = frame
            Visuals.shared.update()
        } else {
            retile(w.key)
        }
    }

    func resetSizes(_ d: Display) {
        let prefix = weightPrefix(d)
        prefs.weights = prefs.weights.filter { !$0.key.hasPrefix(prefix) }
        endFocusMode(on: d.key)
        retile(d.key)
    }

    // MARK: - Counts and layouts

    func setCount(_ n: Int, on d: Display) {
        let n = min(max(n, 1), 5)
        var c = choice(for: d)
        c.count = n
        prefs.screenChoices[choiceKey(d)] = c
        endFocusMode(on: d.key)
        retile(d.key)
    }

    func setLayout(_ l: LayoutKind, on d: Display) {
        guard !(d.shape == .vertical && l == .columns) else { return }
        var c = choice(for: d)
        c.layout = l
        prefs.screenChoices[choiceKey(d)] = c
        endFocusMode(on: d.key)
        retile(d.key)
    }

    /// Why a count isn't available on a screen, or nil when it fits.
    func countUnavailableReason(_ n: Int, on d: Display) -> String? {
        let kind = layoutKind(for: d)
        if n > Layouts.maxCount(shape: d.shape) || (n == 5 && kind != .side) {
            return n == 5 ? "5 needs Side on an ultrawide or vertical screen" : nil
        }
        let size = d.visible.insetBy(dx: prefs.effectiveOuterGap, dy: prefs.effectiveOuterGap).size
        if n > Layouts.capacity(kind, shape: d.shape, size: size) {
            return kind == .columns ? "Too narrow for \(n) columns" : "Too small for \(n) \(kind == .rows ? "rows" : "windows")"
        }
        // An app that needs more room than that many windows leave.
        if let model = models[d.key], model.windows.count >= n {
            var trial = ScreenModel(capacity: n)
            for id in model.showing.prefix(n) { trial.add(id, active: nil, mode: .float) }
            let p = plan(d, model: trial, count: n)
            if let id = p.floatOut.first, let w = windows[id] {
                return "\(w.appName) needs more room"
            }
        }
        return nil
    }

    // MARK: - Floating

    func toggleFloat() {
        guard let w = activeWindow else { return }
        switch w.mode {
        case .tiled:
            endFocusMode(on: w.key)
            w.mode = .floated
            detach(w)
            if let d = display(for: w.key) { centerOnce(w, on: d) }
        case .floated, .autoFloated, .ruleFloated:
            guard let f = w.element.frame, let d = Displays.containing(f, in: displays) else { return }
            w.key = d.key
            place(w, on: d, fresh: false)
        case .closing:
            break
        }
    }

    func alwaysFloat() {
        guard let w = activeWindow, let d = display(for: w.key) else { return }
        guard let title = w.element.title, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            Toast.show("This window has no title", on: d)
            return
        }
        if floatRule(for: w) != nil {
            Toast.show("Already floats every time", on: d)
            return
        }
        let words = title.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
        let rule = FloatRule(bundleID: w.bundleID ?? w.appName, appName: w.appName, words: words)
        Cards.confirmAlwaysFloat(rule, for: w, on: d) { [weak self] in
            guard let self else { return }
            self.prefs.floatRules.append(rule)
        }
    }

    // MARK: - Focus mode

    func toggleFocusMode() {
        guard let w = activeTiled, let d = display(for: w.key) else { return }
        if zoomed[w.key] == w.id {
            endFocusMode(on: w.key)
            return
        }
        zoomed[w.key] = w.id
        let rect = d.visible.insetBy(dx: prefs.effectiveOuterGap, dy: prefs.effectiveOuterGap)
        apply(rect, to: w)
        w.element.perform(kAXRaiseAction)
        Visuals.shared.update()
        bump()
    }

    func endFocusMode(on key: ScreenKey) {
        guard zoomed.removeValue(forKey: key) != nil else { return }
        retile(key)
        bump()
    }

    // MARK: - Clean Space

    func setCleanSpace(_ on: Bool) {
        if !on {
            guard let state = cleanSpace else { return }
            cleanSpace = nil
            Visuals.shared.update()
            retile(state.key)
            StatusItem.shared?.refresh()
            return
        }
        guard cleanSpace == nil else { return }
        let d: Display?
        if let w = activeWindow, w.mode == .tiled { d = display(for: w.key) } else { d = display(at: Coords.mouse) }
        guard let d else { return }
        var state = CleanSpaceState(key: d.key, windows: [])
        if let w = activeWindow, w.key == d.key {
            state.windows = [w.id]
            state.order = [w.id]
        }
        cleanSpace = state
        layoutCleanSpace(raise: true)
        StatusItem.shared?.refresh()
    }

    /// Lays the windows sharing a clean screen out over the whole screen.
    func layoutCleanSpace(raise: Bool) {
        guard var state = cleanSpace, let d = display(for: state.key) else { return }
        state.order = state.order.filter { state.windows.contains($0) && windows[$0] != nil }
        for id in state.windows where !state.order.contains(id) && windows[id] != nil { state.order.append(id) }
        cleanSpace = state
        let rect = d.visible.insetBy(dx: prefs.effectiveOuterGap, dy: prefs.effectiveOuterGap)
        let n = state.order.count
        if n > 0 {
            let tree = Layouts.tree(.grid, shape: d.shape, count: min(n, 4), main: 0.5)
            let s = Solver(tree: tree, rect: rect, gap: prefs.effectiveGap).solve()
            for (i, id) in state.order.enumerated() {
                guard let w = windows[id] else { continue }
                apply(s.frames[min(i, 3)] ?? rect, to: w)
            }
            if raise { for id in state.order { windows[id]?.element.perform(kAXRaiseAction) } }
        }
        if raise { Visuals.shared.update() }
    }

    // MARK: - Retile

    func retileCommand() {
        var movedBack = 0
        for key in visibleKeys {
            guard let model = models[key] else { continue }
            for id in model.windows {
                guard let w = windows[id], let a = w.assigned, let f = w.element.frame else { continue }
                if !Self.same(a, f) { movedBack += 1 }
            }
        }
        reconcile(retileAll: true)
        if let d = currentDisplay {
            Toast.show(movedBack == 0 ? "Everything was in place" : "Put \(movedBack) window\(movedBack == 1 ? "" : "s") back", on: d)
        }
    }
}

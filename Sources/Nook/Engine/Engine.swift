import AppKit
import Combine
import NookKit

final class ManagedWindow {
    enum Mode: Equatable {
        /// In its screen's model: a tile, a stack, or waiting in overflow.
        case tiled
        /// Floated by the user (⌃⌥F); stays where it's put.
        case floated
        /// Floated because its app can't shrink enough for the layout.
        case autoFloated
        /// Matches an "Always float" rule.
        case ruleFloated
        /// Its close button was just clicked; out of the layout until it's gone or back.
        case closing
    }

    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let bundleID: String?
    let appName: String
    var key: ScreenKey
    var mode: Mode = .tiled
    /// The frame Nook last gave it, AX coordinates.
    var assigned: CGRect?
    var lastSet = Date.distantPast
    var refusals = 0

    init(id: CGWindowID, pid: pid_t, element: AXUIElement, app: NSRunningApplication?, key: ScreenKey) {
        self.id = id
        self.pid = pid
        self.element = element
        self.bundleID = app?.bundleIdentifier
        self.appName = app?.localizedName ?? "App"
        self.key = key
    }

    var appKey: String { bundleID ?? appName }
    var icon: NSImage { NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(named: NSImage.applicationIconName)! }
}

enum EngineStatus: Equatable {
    case tiling(windows: Int, focus: Bool)
    case paused // the main switch is off
    case stageManager
    case waitingForSetup
    case needsPermission

    var label: String {
        switch self {
        case .tiling(let n, let focus):
            let w = n == 1 ? "1 window" : "\(n) windows"
            return focus ? "Focus mode · \(w)" : "Tiling \(w)"
        case .paused: return "Automatic tiling is off"
        case .stageManager: return "Paused while Stage Manager is on"
        case .waitingForSetup: return "Waiting for setup to finish"
        case .needsPermission: return "Needs Accessibility access"
        }
    }

    var isActive: Bool { if case .tiling = self { true } else { false } }
}

/// The result of planning one screen's layout without touching any window.
struct Plan {
    var display: Display
    var layout: LayoutKind
    var model: ScreenModel
    var tree: SplitNode?
    var rect: CGRect
    var frames: [CGRect]
    /// Windows that can't fit at their app's minimum size and must float.
    var floatOut: [CGWindowID]
    var weightKey: String
    var minimums: [Int: CGSize]
}

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    let prefs = Preferences.shared
    let tracker = WindowTracker()
    let hotkeys = Hotkeys()

    @Published private(set) var status: EngineStatus = .needsPermission
    /// Bumps whenever anything visible changes, so the panel can redraw.
    @Published private(set) var revision = 0
    @Published private(set) var secureInput = false
    @Published private(set) var trusted = AX.isTrusted
    @Published var cleanSpace: CleanSpaceState?

    private(set) var displays: [Display] = []
    var windows: [CGWindowID: ManagedWindow] = [:]
    var models: [ScreenKey: ScreenModel] = [:]
    /// Last frames per tile, for drop targets, grips and the panel preview.
    var tileFrames: [ScreenKey: [CGRect]] = [:]
    var zoomed: [ScreenKey: CGWindowID] = [:]
    /// Where minimized or hidden windows came from, so they can return there.
    var parked: [CGWindowID: (key: ScreenKey, tile: Int, stacked: Bool)] = [:]
    var activeID: CGWindowID?
    /// The focused window of the frontmost app, managed or not.
    var focusedID: CGWindowID?
    /// A window Nook just asked to activate, until macOS confirms it.
    var focusRequest: (id: CGWindowID, until: Date)?
    /// Every window recently activated, newest first (for Tab View).
    var recent: [CGWindowID] = []
    var stageManagerOn = false
    var shownStackNotice = false

    private var pending: Set<ScreenKey> = []
    private var flushScheduled = false
    private var verifyScheduled: Set<ScreenKey> = []
    private var cancellables: Set<AnyCancellable> = []
    private var timers: [Timer] = []
    var started = false

    var canTile: Bool { status.isActive }

    // MARK: - Lifecycle

    func boot() {
        AX.configureTimeouts()
        tracker.delegate = self
        hotkeys.onCommand = { [weak self] in self?.run($0, from: .keyboard) }
        hotkeys.install()
        applyShortcuts()
        observeSystem()
        observePreferences()
        refreshStatus()
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile(retileAll: false) }
        })
    }

    /// Starts managing windows: called once access is granted and setup is done.
    func startTiling() {
        guard !started else { return }
        started = true
        displays = Displays.all()
        tracker.start()
        reconcile(retileAll: true)
    }

    func stopTiling() {
        guard started else { return }
        started = false
        tracker.stop()
        windows.removeAll()
        models.removeAll()
        tileFrames.removeAll()
        zoomed.removeAll()
        parked.removeAll()
        Visuals.shared.hideAll()
        bump()
    }

    private func tick() {
        let wasTrusted = trusted
        trusted = AX.isTrusted
        if trusted != wasTrusted {
            if trusted {
                Haptics.success()
                Tour.shared.accessGranted()
            }
            refreshStatus()
        }
        let secure = Hotkeys.secureInputActive
        if secure != secureInput { secureInput = secure }
        let stage = StageManager.isOn
        if stage != stageManagerOn {
            stageManagerOn = stage
            refreshStatus()
        }
        // Catches closes no notification reported. Right after a Space switch the
        // cached keys are stale; reconcile handles that case.
        if started, canTile, Displays.all() == displays { dropVanished() }
    }

    func refreshStatus() {
        let next: EngineStatus
        if !trusted { next = .needsPermission }
        else if !prefs.setupComplete { next = .waitingForSetup }
        else if !prefs.tilingEnabled { next = .paused }
        else if stageManagerOn { next = .stageManager }
        else { next = .tiling(windows: tiledCount, focus: !zoomed.isEmpty) }
        if next != status { status = next }

        if trusted && prefs.setupComplete {
            startTiling()
        } else if !trusted {
            stopTiling()
        }
        if !status.isActive {
            Visuals.shared.hideAll()
        } else {
            reconcile(retileAll: true)
        }
        StatusItem.shared?.refresh()
    }

    var tiledCount: Int {
        visibleKeys.reduce(0) { $0 + (models[$1]?.tiles.count ?? 0) }
    }

    func bump() {
        revision &+= 1
        if case .tiling = status {
            let next = EngineStatus.tiling(windows: tiledCount, focus: !zoomed.isEmpty)
            if next != status { status = next; StatusItem.shared?.refresh() }
        }
    }

    // MARK: - System observation

    private func observeSystem() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = Set(self.displays.map(\.uuid))
                self.displays = Displays.all()
                if let clean = self.cleanSpace, !self.displays.contains(where: { $0.uuid == clean.key.display }) {
                    self.setCleanSpace(false)
                }
                if before != Set(self.displays.map(\.uuid)) { Visuals.shared.hideAll() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.reconcile(retileAll: true) }
            }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Visuals.shared.restack() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setCleanSpace(false) }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setCleanSpace(false) }
        }
    }

    private func observePreferences() {
        // Anything affecting layout: retile shortly after it settles.
        let p = prefs
        Publishers.MergeMany(
            p.$layout.map { _ in () }.eraseToAnyPublisher(),
            p.$mainSize.map { _ in () }.eraseToAnyPublisher(),
            p.$windowsPerScreen.map { _ in () }.eraseToAnyPublisher(),
            p.$overflow.map { _ in () }.eraseToAnyPublisher(),
            p.$gap.map { _ in () }.eraseToAnyPublisher(),
            p.$separateOuterGap.map { _ in () }.eraseToAnyPublisher(),
            p.$outerGap.map { _ in () }.eraseToAnyPublisher(),
            p.$highlight.map { _ in () }.eraseToAnyPublisher(),
            p.$borderThickness.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(9)
        .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
        .sink { [weak self] in self?.retileAll() }
        .store(in: &cancellables)

        Publishers.MergeMany(
            p.$tilingEnabled.map { _ in () }.eraseToAnyPublisher(),
            p.$setupComplete.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(2)
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refreshStatus() }
        .store(in: &cancellables)

        Publishers.MergeMany(
            p.$shortcutsEnabled.map { _ in () }.eraseToAnyPublisher(),
            p.$prefix.map { _ in () }.eraseToAnyPublisher(),
            p.$tabViewEnabled.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(3)
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.applyShortcuts() }
        .store(in: &cancellables)

        Publishers.MergeMany(
            p.$excludedApps.map { _ in () }.eraseToAnyPublisher(),
            p.$removedDefaultExclusions.map { _ in () }.eraseToAnyPublisher(),
            p.$floatRules.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(3)
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rulesChanged() }
        .store(in: &cancellables)

        p.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in
                Visuals.shared.update()
                self?.bump()
            }
            .store(in: &cancellables)
    }

    func applyShortcuts() {
        // Defer so @Published values have landed.
        DispatchQueue.main.async { [self] in
            hotkeys.apply(enabled: prefs.shortcutsEnabled, prefix: prefs.prefix, tabView: prefs.tabViewEnabled)
            bump()
        }
    }

    // MARK: - Screens

    var visibleKeys: [ScreenKey] { displays.map(\.key) }

    func display(for key: ScreenKey) -> Display? {
        displays.first { $0.key == key }
    }

    func display(at point: CGPoint) -> Display? {
        Displays.at(point, in: displays)
    }

    /// The screen the user is working on: the active window's, else the pointer's.
    var currentDisplay: Display? {
        if let id = activeID, let w = windows[id], let d = display(for: w.key) { return d }
        return display(at: Coords.mouse)
    }

    func choiceKey(_ d: Display) -> String {
        "\(d.uuid)#\(d.space)" + (d.shape == .vertical ? "|v" : "")
    }

    func choice(for d: Display) -> ScreenChoice {
        prefs.screenChoices[choiceKey(d)] ?? ScreenChoice()
    }

    func layoutKind(for d: Display) -> LayoutKind {
        if let l = choice(for: d).layout { return l }
        // A portrait screen stacks rows until a layout is picked on it.
        return d.shape == .vertical ? .rows : prefs.layout
    }

    func requestedCount(for d: Display) -> Int {
        choice(for: d).count ?? prefs.windowsPerScreen
    }

    func capacity(for d: Display, layout: LayoutKind? = nil, count: Int? = nil) -> Int {
        let kind = layout ?? layoutKind(for: d)
        let size = d.visible.insetBy(dx: prefs.effectiveOuterGap, dy: prefs.effectiveOuterGap).size
        return min(count ?? requestedCount(for: d), Layouts.capacity(kind, shape: d.shape, size: size))
    }

    func weightPrefix(_ d: Display) -> String { "\(d.uuid)#\(d.space)|" }

    func hasCustomSizes(_ d: Display) -> Bool {
        let prefix = weightPrefix(d)
        return prefs.weights.keys.contains { $0.hasPrefix(prefix) }
    }

    // MARK: - Managing windows

    /// Base rule for which windows join the layout at all.
    func isTileable(_ e: AXUIElement, app: NSRunningApplication?) -> Bool {
        guard let app, app.activationPolicy == .regular, app.processIdentifier != getpid() else { return false }
        guard e.role == kAXWindowRole, e.subrole == kAXStandardWindowSubrole else { return false }
        guard !e.isMinimized, !e.isFullScreen else { return false }
        guard e.isSettable(kAXSizeAttribute), e.isSettable(kAXPositionAttribute) else { return false }
        guard let f = e.frame, f.width >= 120, f.height >= 80 else { return false }
        // The end-to-end tests limit Nook to their own fixture apps.
        if let only = UserDefaults.standard.stringArray(forKey: "debugOnlyApps"), !only.isEmpty,
           !only.contains(app.bundleIdentifier ?? "") { return false }
        return !prefs.isExcluded(app.bundleIdentifier)
    }

    func floatRule(for w: ManagedWindow) -> FloatRule? {
        guard !prefs.floatRules.isEmpty, let title = w.element.title, !title.isEmpty else { return nil }
        return prefs.floatRules.first { $0.matches(bundleID: w.bundleID, title: title) }
    }

    /// Takes a window into management if it qualifies. `fresh` is true for newly opened windows.
    @discardableResult
    func consider(_ e: AXUIElement, pid: pid_t, fresh: Bool, onScreen: Set<CGWindowID>? = nil) -> ManagedWindow? {
        guard started, let wid = e.windowID, windows[wid] == nil else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        guard isTileable(e, app: app) else { return nil }
        let visible = onScreen ?? WindowServer.onScreenIDs()
        guard visible.contains(wid), let frame = e.frame else { return nil }
        guard let d = Displays.containing(frame, in: displays) else { return nil }

        let w = ManagedWindow(id: wid, pid: pid, element: e, app: app, key: d.key)
        windows[wid] = w
        tracker.watch(window: e, pid: pid)

        if floatRule(for: w) != nil {
            w.mode = .ruleFloated
            return w
        }
        place(w, on: d, fresh: fresh)
        return w
    }

    /// Adds a managed window to its screen's model and retiles.
    func place(_ w: ManagedWindow, on d: Display, fresh: Bool) {
        w.mode = .tiled
        var model = models[d.key] ?? ScreenModel(capacity: capacity(for: d))
        model.setCapacity(capacity(for: d), mode: prefs.overflow)

        // A window opened exactly over a sibling of the same app is a native
        // tab: it shares its window's tile instead of taking a new one.
        if fresh, let sibling = model.windows.compactMap({ windows[$0] }).first(where: {
            $0.pid == w.pid && $0.id != w.id && ($0.element.frame.map { f in Self.same(f, w.element.frame) } ?? false)
        }), let tile = model.tileIndex(of: sibling.id) {
            model.stack(w.id, onto: tile)
            models[d.key] = model
            endFocusMode(on: d.key)
            retile(d.key)
            return
        }

        let active = activeID.flatMap { id in windows[id]?.key == d.key ? model.tileIndex(of: id) : nil }
        if let slot = parked.removeValue(forKey: w.id), slot.key == d.key, slot.stacked, slot.tile < model.tiles.count {
            model.stack(w.id, onto: slot.tile)
        } else {
            switch model.add(w.id, active: active, mode: prefs.overflow) {
            case .stacked(let i):
                if !shownStackNotice {
                    shownStackNotice = true
                    let other = windows[model.tiles[i].recent.dropFirst().first ?? 0]?.appName ?? "a window"
                    Toast.show("Stacked on top of \(other) · \(hotkeys.combo(for: .stackNext)?.display ?? "") to switch", on: d)
                }
            case .overflow:
                centerOnce(w, on: d)
                Toast.show("This Space is full", on: d)
            case .tiled:
                break
            }
        }
        models[d.key] = model
        if fresh {
            countPlaced()
            endFocusMode(on: d.key)
            if let clean = cleanSpace, clean.key == d.key { cleanSpace?.windows.insert(w.id) }
        }
        retile(d.key)
    }

    static func same(_ a: CGRect, _ b: CGRect?) -> Bool {
        guard let b else { return false }
        return abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// Stops managing a window entirely.
    func forget(_ id: CGWindowID) {
        guard let w = windows.removeValue(forKey: id) else { return }
        tracker.unwatch(window: w.element, pid: w.pid)
        detach(w)
        recent.removeAll { $0 == id }
        cleanSpace?.windows.remove(id)
        if activeID == id { activeID = nil }
    }

    /// Takes a window out of its model (it stays managed).
    func detach(_ w: ManagedWindow) {
        if var model = models[w.key], model.contains(w.id) {
            let wasShowing = model.tiles.first { $0.contains(w.id) }?.showing == w.id
            model.remove(w.id, mode: prefs.overflow)
            models[w.key] = model
            if wasShowing { raiseShowing(on: w.key) }
        }
        if zoomed[w.key] == w.id { zoomed[w.key] = nil }
        retile(w.key)
    }

    /// Remembers a window's tile while it's minimized or hidden.
    func park(_ w: ManagedWindow) {
        if let model = models[w.key], let i = model.tileIndex(of: w.id) {
            parked[w.id] = (w.key, i, model.tiles[i].isStack)
        }
        forget(w.id)
    }

    func managed(_ e: AXUIElement) -> ManagedWindow? {
        if let id = e.windowID, let w = windows[id] { return w }
        return windows.values.first { CFEqual($0.element, e) }
    }

    /// Floats a window in the middle of its screen at a comfortable size, once.
    func centerOnce(_ w: ManagedWindow, on d: Display, keepSize: Bool = false) {
        guard let f = w.element.frame else { return }
        let v = d.visible
        let size = keepSize
            ? CGSize(width: min(f.width, v.width), height: min(f.height, v.height))
            : CGSize(width: min(max(f.width, v.width * 0.5), v.width * 0.62), height: min(max(f.height, v.height * 0.5), v.height * 0.7))
        let r = CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height).integral
        w.lastSet = Date()
        w.element.setFrame(r)
        w.assigned = nil
        w.element.perform(kAXRaiseAction)
    }

    func rulesChanged() {
        for w in Array(windows.values) {
            if prefs.isExcluded(w.bundleID) {
                forget(w.id)
                continue
            }
            let rule = floatRule(for: w)
            if rule != nil, w.mode == .tiled {
                w.mode = .ruleFloated
                detach(w)
            } else if rule == nil, w.mode == .ruleFloated, let d = display(for: w.key) {
                place(w, on: d, fresh: false)
            }
        }
        reconcile(retileAll: true)
    }

    // MARK: - Reconciling with the window server

    /// Brings the models in line with what's actually on screen: windows that
    /// left for another Space, windows that arrived, displays that changed.
    func reconcile(retileAll all: Bool) {
        guard started, canTile else { return }
        let fresh = Displays.all()
        let changed = fresh != displays
        displays = fresh
        let onScreen = WindowServer.onScreenIDs()
        let visible = Set(visibleKeys)
        var dirty = changed || all
        if dropVanished(onScreen: onScreen) { dirty = true }

        for w in Array(windows.values) where !visible.contains(w.key) {
            if onScreen.contains(w.id), let f = w.element.frame, let d = Displays.containing(f, in: displays) {
                // Its display or Space went away, or it shows on every Space.
                let mode = w.mode
                detach(w)
                w.key = d.key
                if mode == .tiled { place(w, on: d, fresh: false) }
                dirty = true
            }
        }

        for pid in tracker.observedPIDs {
            let app = AXUIElementCreateApplication(pid)
            for e in app.windows {
                if let id = e.windowID, windows[id] == nil, onScreen.contains(id) {
                    if consider(e, pid: pid, fresh: false, onScreen: onScreen) != nil { dirty = true }
                }
            }
        }
        if dirty { retileAll() }
    }

    /// Forgets windows on visible screens that left the window server without
    /// a destroyed notification: many apps close a window by hiding it, and a
    /// window moved to another Space rejoins when seen there. Cheap enough to
    /// run every second.
    @discardableResult
    func dropVanished(pid: pid_t? = nil, onScreen: Set<CGWindowID>? = nil) -> Bool {
        guard started, canTile else { return false }
        let onScreen = onScreen ?? WindowServer.onScreenIDs()
        let visible = Set(visibleKeys)
        var dropped = false
        for w in Array(windows.values) where (pid == nil || w.pid == pid) && visible.contains(w.key) && !onScreen.contains(w.id) {
            let gone = w.element.role == nil
            let parkedElsewhere = w.element.isMinimized || (NSRunningApplication(processIdentifier: w.pid)?.isHidden ?? false)
            if gone || (!parkedElsewhere && w.mode != .closing) {
                forget(w.id)
                dropped = true
            }
        }
        return dropped
    }

    // MARK: - Layout

    func retile(_ key: ScreenKey) {
        pending.insert(key)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let keys = self.pending
            self.pending.removeAll()
            for k in keys { self.layout(k) }
            Visuals.shared.update()
            self.bump()
        }
    }

    func retileAll() {
        for k in visibleKeys { retile(k) }
        if visibleKeys.isEmpty { Visuals.shared.update() }
    }

    func minimums(for model: ScreenModel) -> [Int: CGSize] {
        var out: [Int: CGSize] = [:]
        for (i, tile) in model.tiles.enumerated() {
            var m = CGSize.zero
            for id in tile.recent {
                guard let w = windows[id], let learned = prefs.learnedSizes[w.appKey] else { continue }
                m.width = max(m.width, learned.width ?? 0)
                m.height = max(m.height, learned.height ?? 0)
            }
            if m != .zero { out[i] = m }
        }
        return out
    }

    /// Works out where every tile on a screen goes, floating out windows that can't fit.
    func plan(_ d: Display, model input: ScreenModel? = nil, layout: LayoutKind? = nil, count: Int? = nil) -> Plan {
        let kind = layout ?? layoutKind(for: d)
        var model = input ?? models[d.key] ?? ScreenModel(capacity: 1)
        model.setCapacity(capacity(for: d, layout: kind, count: count), mode: prefs.overflow)
        let gap = prefs.effectiveGap
        let rect = d.visible.insetBy(dx: prefs.effectiveOuterGap, dy: prefs.effectiveOuterGap)
        var floatOut: [CGWindowID] = []

        while true {
            let n = model.tiles.count
            let wkey = weightPrefix(d) + "\(kind.rawValue)|\(n)"
            guard n > 0 else {
                return Plan(display: d, layout: kind, model: model, tree: nil, rect: rect, frames: [], floatOut: floatOut, weightKey: wkey, minimums: [:])
            }
            let tree = Layouts.tree(kind, shape: d.shape, count: n, main: prefs.mainSize.fraction)
            let mins = minimums(for: model)
            let solution = Solver(tree: tree, rect: rect, gap: gap, weights: prefs.weights[wkey] ?? [:], minimums: mins).solve()
            if !solution.fits, n > 1 {
                // Float the newest tile whose app needs more room than it can have.
                let culprit = solution.cramped.filter { mins[$0] != nil }.max()
                    ?? mins.keys.max()
                if let i = culprit {
                    let id = model.tiles[i].showing
                    model.remove(id, mode: prefs.overflow)
                    floatOut.append(id)
                    continue
                }
            }
            let frames = (0..<n).map { solution.frames[$0] ?? rect }
            return Plan(display: d, layout: kind, model: model, tree: tree, rect: rect, frames: frames, floatOut: floatOut, weightKey: wkey, minimums: mins)
        }
    }

    func layout(_ key: ScreenKey, skipping: CGWindowID? = nil) {
        guard canTile, let d = display(for: key) else { return }
        let p = plan(d)
        models[key] = p.model
        tileFrames[key] = p.frames

        for id in p.floatOut {
            guard let w = windows[id] else { continue }
            w.mode = .autoFloated
            centerOnce(w, on: d, keepSize: true)
            Cards.needsRoom(for: w, on: d)
        }
        // Windows waiting in overflow float in the middle; give newly waiting ones a spot.
        for id in p.model.overflow {
            if let w = windows[id], w.assigned != nil { centerOnce(w, on: d) }
        }

        let zoomedID = zoomed[key]
        let clean = cleanSpace?.key == key ? cleanSpace?.windows ?? [] : []
        for (i, tile) in p.model.tiles.enumerated() {
            for id in tile.recent where id != skipping && !clean.contains(id) {
                guard let w = windows[id] else { continue }
                let target = id == zoomedID ? p.rect : p.frames[i]
                apply(target, to: w)
            }
        }
        // A zoomed window that left the layout ends focus mode.
        if let z = zoomedID, !p.model.windows.contains(z) { zoomed[key] = nil }
        if !clean.isEmpty { layoutCleanSpace(raise: false) }

        // Auto-floated windows rejoin when there's room again.
        retryAutoFloated(on: d)
        scheduleVerify(key)
    }

    func apply(_ frame: CGRect, to w: ManagedWindow) {
        w.assigned = frame
        if let current = w.element.frame, Self.same(current, frame) { return }
        w.lastSet = Date()
        AnimationGuard.without(pid: w.pid) {
            w.element.setFrame(frame)
        }
    }

    private func retryAutoFloated(on d: Display) {
        let candidates = windows.values.filter { $0.mode == .autoFloated && $0.key == d.key }
        guard !candidates.isEmpty, var model = models[d.key], !model.isFull else { return }
        for w in candidates {
            var trial = model
            trial.add(w.id, active: nil, mode: .float)
            let p = plan(d, model: trial)
            if p.floatOut.isEmpty, p.model.tileIndex(of: w.id) != nil {
                model = trial
                w.mode = .tiled
                models[d.key] = model
                retile(d.key)
                return
            }
        }
    }

    // MARK: - Learning minimum sizes

    private func scheduleVerify(_ key: ScreenKey) {
        guard !verifyScheduled.contains(key) else { return }
        verifyScheduled.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.verifyScheduled.remove(key)
            self?.verify(key)
        }
    }

    /// Checks each window took the size it was given. A window that refuses
    /// twice teaches Nook its app's minimum size.
    private func verify(_ key: ScreenKey) {
        guard canTile, !Mouse.shared.isDragging, let d = display(for: key), let model = models[key] else { return }
        var relayout = false
        for id in model.windows {
            guard let w = windows[id], w.mode == .tiled, let target = w.assigned, let actual = w.element.frame else { continue }
            if zoomed[key] == id { continue }
            let wider = actual.width > target.width + 2
            let taller = actual.height > target.height + 2
            if wider || taller {
                w.refusals += 1
                if w.refusals == 1 {
                    // Ask again: apps often resize themselves right after opening.
                    w.assigned = nil
                    apply(target, to: w)
                    scheduleVerify(key)
                    continue
                }
                w.refusals = 0
                // A "minimum" of nearly the whole screen is never remembered.
                if actual.width > d.visible.width * 0.92 && actual.height > d.visible.height * 0.92 { continue }
                var learned = prefs.learnedSizes[w.appKey] ?? LearnedSize(appName: w.appName)
                if wider { learned.width = max(learned.width ?? 0, actual.width) }
                if taller { learned.height = max(learned.height ?? 0, actual.height) }
                prefs.learnedSizes[w.appKey] = learned
                relayout = true
            } else {
                w.refusals = 0
                // The app took a smaller size than remembered: lower the record.
                if var learned = prefs.learnedSizes[w.appKey] {
                    var lowered = false
                    if let lw = learned.width, actual.width < lw - 2 { learned.width = actual.width; lowered = true }
                    if let lh = learned.height, actual.height < lh - 2 { learned.height = actual.height; lowered = true }
                    if lowered { prefs.learnedSizes[w.appKey] = learned }
                }
                if !Self.same(actual, target) && Date().timeIntervalSince(w.lastSet) > 0.3 {
                    apply(target, to: w)
                }
            }
        }
        if relayout { retile(key) }
    }

    // MARK: - Stacks

    /// Brings each stacked tile's showing window above its siblings.
    func raiseShowing(on key: ScreenKey) {
        guard let model = models[key] else { return }
        for tile in model.tiles where tile.isStack {
            windows[tile.showing]?.element.perform(kAXRaiseAction)
        }
    }

    // MARK: - Activity

    func countPlaced() {
        guard prefs.countActivity else { return }
        prefs.activity.rollIfNeeded()
        prefs.activity.placed += 1
    }

    func countUse(_ command: Command, from source: InputSource) {
        guard prefs.countActivity else { return }
        prefs.activity.rollIfNeeded()
        switch source {
        case .keyboard: prefs.activity.keyboard += 1
        case .mouse: prefs.activity.mouse += 1
        case .both:
            prefs.activity.keyboard += 0.5
            prefs.activity.mouse += 0.5
        case .script: break
        }
        prefs.activity.uses[command.name, default: 0] += 1
    }
}

// MARK: - Tracker events

extension Engine: WindowTrackerDelegate {
    func tracker(_ event: WindowEvent, pid: pid_t) {
        guard started else { return }
        switch event {
        case .created(let e):
            // Some apps finish setting a window up just after announcing it.
            if consider(e, pid: pid, fresh: true) == nil {
                for delay in [0.08, 0.3, 0.8] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.consider(e, pid: pid, fresh: true)
                    }
                }
            }
        case .destroyed(let e):
            if let w = managed(e) { forget(w.id) } else { sweepSoon(pid) }
        case .minimized(let e):
            if let w = managed(e) { park(w) }
        case .restored(let e):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.consider(e, pid: pid, fresh: false)
            }
        case .moved(let e), .resized(let e):
            guard let w = managed(e) else { return }
            windowChangedFrame(w)
        case .titleChanged(let e):
            guard let w = managed(e), w.mode == .tiled, floatRule(for: w) != nil else { return }
            w.mode = .ruleFloated
            detach(w)
        case .focusChanged(let pid):
            focusChanged(pid: pid)
            // Focus moves when a window closes, even one the app only hides.
            sweepSoon(pid)
        case .appHidden(let pid):
            for w in windows.values where w.pid == pid { park(w) }
        case .appShown(let pid):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                for e in AXUIElementCreateApplication(pid).windows { self.consider(e, pid: pid, fresh: false) }
            }
        }
    }

    /// Checks an app's windows once its close animation has had time to finish.
    private func sweepSoon(_ pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.dropVanished(pid: pid)
        }
    }

    func trackerAppLaunched(_ app: NSRunningApplication) {}

    func trackerAppTerminated(_ pid: pid_t) {
        for w in windows.values where w.pid == pid { forget(w.id) }
    }

    func trackerAppActivated(_ pid: pid_t) {
        focusChanged(pid: pid)
    }

    func trackerSpaceChanged() {
        setCleanSpace(false)
        Visuals.shared.hideAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reconcile(retileAll: true)
        }
    }

    func focusChanged(pid: pid_t) {
        guard started else { return }
        let app = AXUIElementCreateApplication(pid)
        guard let e = app.focusedWindow, let id = e.windowID else {
            if focusRequest == nil { focusedID = nil }
            Visuals.shared.update()
            return
        }
        // Right after Nook activates a window, apps can still report the old one
        // for a moment. Trust the request until it lands or times out.
        if let request = focusRequest {
            if id == request.id || Date() > request.until {
                focusRequest = nil
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.focusChanged(pid: pid) }
                return
            }
        }
        becameActive(id, element: e, pid: pid)
    }

    /// Records `id` as the focused window and updates stacks, focus mode and Clean Space.
    func becameActive(_ id: CGWindowID, element e: AXUIElement, pid: pid_t) {
        focusedID = id
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 64 { recent.removeLast() }

        guard let w = windows[id] else {
            // Maybe a window we haven't seen yet (another Space, a late arrival).
            if consider(e, pid: pid, fresh: false) == nil { activeID = nil }
            Visuals.shared.update()
            bump()
            return
        }
        let previous = activeID
        activeID = id
        if w.mode == .tiled, var model = models[w.key] {
            let before = model.tiles.first { $0.contains(id) }?.showing
            model.show(id)
            models[w.key] = model
            if before != id { bump() }
            // Switching to another tiled window on a zoomed screen ends focus mode.
            if let z = zoomed[w.key], z != id { endFocusMode(on: w.key) }
        }
        if let clean = cleanSpace, clean.key == w.key, !clean.windows.contains(id) {
            cleanSpace?.windows.insert(id)
            layoutCleanSpace(raise: true)
        }
        if previous != id { Visuals.shared.update() }
    }

    private func windowChangedFrame(_ w: ManagedWindow) {
        guard canTile, w.mode == .tiled else { return }
        // Our own change echoing back.
        if Date().timeIntervalSince(w.lastSet) < 0.5 { return }
        if Mouse.shared.buttonDown {
            Mouse.shared.windowIsMoving(w)
            return
        }
        // Moved by something else (macOS, another tool). If it changed screens, follow it.
        guard let f = w.element.frame, let d = Displays.containing(f, in: displays) else { return }
        if d.key != w.key {
            detach(w)
            w.key = d.key
            place(w, on: d, fresh: false)
        } else {
            scheduleVerify(w.key)
        }
    }
}

enum StageManager {
    static var isOn: Bool {
        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        return (CFPreferencesCopyAppValue("GlobalEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false
    }
}

/// Some apps animate frame changes while VoiceOver-style enhanced UI is on;
/// turning it off for the duration makes moves instant.
enum AnimationGuard {
    static func without(pid: pid_t, _ body: () -> Void) {
        let app = AXUIElementCreateApplication(pid)
        let enhanced: Bool = app.attribute("AXEnhancedUserInterface") ?? false
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        body()
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) }
    }
}

enum Haptics {
    static func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

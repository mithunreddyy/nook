import AppKit
import NookKit

/// An arrangement waiting for its windows: after a restart, after sleep, or
/// while a workspace's apps open. Saved tiles by display UUID.
struct PendingArrangement {
    var screens: [String: [[SavedWindow]]]
    var until: Date
}

extension Engine {
    // MARK: - Window references

    func ref(_ w: ManagedWindow) -> SavedWindow {
        SavedWindow(id: w.id, app: w.appKey, title: Fingerprint.of(w.element.title ?? ""))
    }

    /// One screen's tiles as saved references, oldest window of each stack first.
    func refs(_ key: ScreenKey) -> [[SavedWindow]] {
        guard let model = models[key] else { return [] }
        return model.tiles.map { tile in
            tile.order.compactMap { id in
                windows[id].map {
                    var r = ref($0)
                    if tile.split { r.split = true }
                    if model.isPinned(id) { r.pinned = true }
                    return r
                }
            }
        }.filter { !$0.isEmpty }
    }

    /// Every visible screen's arrangement, by display UUID.
    func snapshot() -> [String: [[SavedWindow]]] {
        var out: [String: [[SavedWindow]]] = [:]
        for d in displays { out[d.uuid] = refs(d.key) }
        return out
    }

    // MARK: - Session restore

    /// Saves the arrangement a moment after it settles, so a restart can bring it back.
    func scheduleSessionSave() {
        if let w = waitingArrangement, Date() > w.until { waitingArrangement = nil }
        guard started, canTile, waitingArrangement == nil, !sessionSaveScheduled else { return }
        sessionSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.sessionSaveScheduled = false
            guard self.started, self.canTile, self.waitingArrangement == nil else { return }
            var next = self.prefs.session
            for (uuid, tiles) in self.snapshot() { next[uuid] = tiles }
            if next != self.prefs.session { self.prefs.session = next }
        }
    }

    /// At launch: windows arriving in the next minute go back to last session's places.
    func beginSessionRestore() {
        guard !prefs.session.isEmpty else { return }
        waitingArrangement = PendingArrangement(screens: prefs.session, until: Date().addingTimeInterval(60))
    }

    /// Re-sorts a screen's tiles to match the waiting arrangement.
    func arrangeFromWaiting(_ key: ScreenKey) {
        guard let p = waitingArrangement else { return }
        if Date() > p.until {
            waitingArrangement = nil
            return
        }
        guard let saved = p.screens[key.display], !saved.isEmpty, var model = models[key] else { return }
        let live = model.windows.compactMap { windows[$0] }.map(ref)
        let slots = SavedWindow.match(saved: saved, live: live)
        let before = model
        model.arrange(slot: { slots[$0] }, mode: prefs.overflow)
        SavedWindow.restoreExtras(&model, saved: saved, slots: slots)
        if model != before {
            models[key] = model
            retile(key)
        }
    }

    /// A window that belongs on another screen in the waiting arrangement: its display.
    func waitingHome(for w: ManagedWindow) -> Display? {
        guard let p = waitingArrangement, Date() <= p.until else { return nil }
        let app = w.appKey
        let homes = p.screens.filter { $0.value.contains { $0.contains { $0.app == app } } }.map(\.key)
        guard !homes.contains(w.key.display), homes.count == 1 else { return nil }
        return displays.first { $0.uuid == homes[0] }
    }

    // MARK: - Sleep, lock and displays

    func willSleep() {
        guard started, canTile else { return }
        waitingArrangement = PendingArrangement(screens: snapshot(), until: .distantFuture)
    }

    func didWake() {
        guard waitingArrangement != nil else { return }
        waitingArrangement?.until = Date().addingTimeInterval(20)
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.reconcile(retileAll: true)
                for key in self.visibleKeys { self.arrangeFromWaiting(key) }
            }
        }
    }

    /// A display went away: remember its arrangement so its windows can go back.
    func rememberLostScreens() {
        let present = Set(displays.map(\.uuid))
        for (key, model) in models where !present.contains(key.display) && !model.tiles.isEmpty {
            if lostScreens[key.display] == nil { lostScreens[key.display] = refs(key) }
        }
    }

    /// A display came back: move its windows home and put them in order.
    func returnToReconnectedScreens() {
        for d in displays {
            guard let saved = lostScreens.removeValue(forKey: d.uuid) else { continue }
            let live = windows.values.filter { $0.mode == .tiled && $0.key != d.key }
            let slots = SavedWindow.match(saved: saved, live: live.map(ref))
            for w in live where slots[w.id] != nil {
                detach(w)
                w.key = d.key
                place(w, on: d, fresh: false)
            }
            if var model = models[d.key] {
                model.arrange(slot: { slots[$0] }, mode: prefs.overflow)
                SavedWindow.restoreExtras(&model, saved: saved, slots: slots)
                models[d.key] = model
            }
            retileAll()
        }
    }

    // MARK: - Workspaces

    func saveWorkspace(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let screens = displays.map { d in
            WorkspaceScreen(display: d.uuid, name: d.name, layout: layoutKind(for: d), count: requestedCount(for: d), tiles: refs(d.key))
        }
        let ws = Workspace(name: name, screens: screens, saved: Date())
        if let i = prefs.workspaces.firstIndex(where: { $0.name == name }) {
            prefs.workspaces[i] = ws
        } else {
            prefs.workspaces.append(ws)
        }
        if let d = currentDisplay { Toast.show("Saved “\(name)” · \(ws.windowCount) windows", on: d, symbol: "square.and.arrow.down") }
    }

    /// Puts open windows where the workspace had them, and opens apps it needs.
    func loadWorkspace(_ name: String, openApps: Bool = true) {
        guard let ws = prefs.workspaces.first(where: { $0.name == name }) else {
            if let d = currentDisplay { Toast.show("No workspace named “\(name)”", on: d) }
            return
        }
        let sorted = displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        var targets: [(Display, WorkspaceScreen)] = []
        for (i, screen) in ws.screens.enumerated() {
            // The same display if it's here, else the one in the same place in the row.
            let d = displays.first { $0.uuid == screen.display } ?? (i < sorted.count && !ws.screens.contains { $0.display == sorted[i].uuid } ? sorted[i] : nil)
            if let d, !targets.contains(where: { $0.0.id == d.id }) { targets.append((d, screen)) }
        }
        endFocusModes()
        var waiting: [String: [[SavedWindow]]] = [:]
        var placed = 0
        var pool = windows.values.filter { $0.mode == .tiled }
        for (d, screen) in targets {
            var c = choice(for: d)
            c.layout = screen.layout
            c.count = screen.count
            if d.shape == .vertical && c.layout == .columns { c.layout = nil }
            prefs.screenChoices[choiceKey(d)] = c
            let slots = SavedWindow.match(saved: screen.tiles, live: pool.map(ref))
            for w in pool where slots[w.id] != nil && w.key != d.key {
                detach(w)
                w.key = d.key
                place(w, on: d, fresh: false)
            }
            pool.removeAll { slots[$0.id] != nil }
            placed += slots.count
            if var model = models[d.key] {
                model.setCapacity(capacity(for: d), mode: prefs.overflow)
                model.arrange(slot: { slots[$0] }, mode: prefs.overflow)
                SavedWindow.restoreExtras(&model, saved: screen.tiles, slots: slots)
                models[d.key] = model
            }
            waiting[d.uuid] = screen.tiles
        }
        retileAll()

        var opened = 0
        if openApps {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            for app in ws.apps where !running.contains(app) {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { continue }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config)
                opened += 1
            }
        }
        // Windows still to come (apps opening, slow windows) find their places too.
        waitingArrangement = PendingArrangement(screens: waiting, until: Date().addingTimeInterval(opened > 0 ? 30 : 5))
        if let d = currentDisplay {
            let more = opened > 0 ? " · opening \(opened) app\(opened == 1 ? "" : "s")" : ""
            Toast.show("Loaded “\(name)” · \(placed) window\(placed == 1 ? "" : "s")\(more)", on: d, symbol: "square.and.arrow.up")
        }
    }

    private func endFocusModes() {
        for key in Array(zoomed.keys) { endFocusMode(on: key) }
    }

    func exportWorkspace(_ name: String, to url: URL) throws {
        guard let ws = prefs.workspaces.first(where: { $0.name == name }) else { throw CocoaError(.fileNoSuchFile) }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try e.encode(ws).write(to: url)
    }

    @discardableResult
    func importWorkspace(from url: URL) throws -> Workspace {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let ws = try d.decode(Workspace.self, from: Data(contentsOf: url))
        if let i = prefs.workspaces.firstIndex(where: { $0.name == ws.name }) { prefs.workspaces[i] = ws } else { prefs.workspaces.append(ws) }
        return ws
    }
}

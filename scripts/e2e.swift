#!/usr/bin/env swift
// End-to-end tests: drives the installed Nook.app with real windows from the
// fixture apps, through the same command path its shortcuts use.
//
//   scripts/bundle.sh --fixtures --install && swift scripts/e2e.swift
//
// Nook is limited to the fixture apps while this runs (your own windows aren't
// touched), and your Nook settings are restored afterwards.

import AppKit
import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().path
let nookApp = "/Applications/Nook.app"
let domain = "dev.mithun.nook"
let fixtureID = "dev.mithun.nook.fixture"
let bigID = "dev.mithun.nook.fixture.big"
let work = NSTemporaryDirectory() + "nook-e2e"
let dumpPath = work + "/state.json"
try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)

// MARK: - Plumbing

@discardableResult
func sh(_ args: String...) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }

// Aimed at the installed copy, so another registered build never takes the link.
func nook(_ path: String) { sh("open", "-g", "-a", nookApp, "nook://" + path) }

typealias JSON = [String: Any]

func dump() -> JSON {
    try? FileManager.default.removeItem(atPath: dumpPath)
    nook("debug/dump?path=" + dumpPath)
    for _ in 0..<60 {
        if let d = FileManager.default.contents(atPath: dumpPath), let j = try? JSONSerialization.jsonObject(with: d) as? JSON { return j }
        pause(0.05)
    }
    return [:]
}

func fixture(_ cmd: String, _ title: String? = nil, big: Bool = false) {
    var info = ["cmd": cmd]
    if let title { info["title"] = title }
    DistributedNotificationCenter.default().postNotificationName(.init(big ? bigID : fixtureID), object: nil, userInfo: info, deliverImmediately: true)
}

struct Rect: CustomStringConvertible {
    var x, y, w, h: Double
    init(_ a: Any?) {
        let v = (a as? [Double]) ?? (a as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0, 0]
        (x, y, w, h) = (v[0], v[1], v[2], v[3])
    }
    init(x: Double, y: Double, w: Double, h: Double) { (self.x, self.y, self.w, self.h) = (x, y, w, h) }
    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var mid: (Double, Double) { (x + w / 2, y + h / 2) }
    func inset(_ d: Double) -> Rect { Rect(x: x + d, y: y + d, w: w - 2 * d, h: h - 2 * d) }
    func near(_ o: Rect, _ tol: Double = 3) -> Bool { abs(x - o.x) <= tol && abs(y - o.y) <= tol && abs(w - o.w) <= tol && abs(h - o.h) <= tol }
    var description: String { "(\(Int(x)),\(Int(y)) \(Int(w))×\(Int(h)))" }
}

/// The screen the fixture windows tile on, and helpers over the dump.
struct State {
    var j: JSON
    var windows: [JSON] { j["windows"] as? [JSON] ?? [] }
    var screens: [JSON] { j["screens"] as? [JSON] ?? [] }
    var screen: JSON {
        let ids = Set(windows.compactMap { $0["id"] as? Int })
        return screens.first { s in (s["tiles"] as? [JSON] ?? []).contains { t in (t["windows"] as? [Int] ?? []).contains(where: ids.contains) } }
            ?? screens.first ?? [:]
    }
    var tiles: [JSON] { screen["tiles"] as? [JSON] ?? [] }
    var tileFrames: [Rect] { tiles.map { Rect($0["frame"]) } }
    var visible: Rect { Rect(screen["visible"]) }
    func id(_ title: String) -> Int? { windows.first { $0["title"] as? String == title }?["id"] as? Int }
    func window(_ title: String) -> JSON? { windows.first { $0["title"] as? String == title } }
    func showing(_ i: Int) -> String? {
        guard i < tiles.count, let sid = tiles[i]["showing"] as? Int else { return nil }
        return windows.first { $0["id"] as? Int == sid }?["title"] as? String
    }
    var order: [String] { (0..<tiles.count).compactMap(showing) }
    func tileOf(_ title: String) -> Int? {
        guard let id = id(title) else { return nil }
        return tiles.firstIndex { ($0["windows"] as? [Int] ?? []).contains(id) }
    }
    func mode(_ title: String) -> String? { window(title)?["mode"] as? String }
    var visuals: [String: Int] { j["visuals"] as? [String: Int] ?? [:] }
}

func state() -> State { State(j: dump()) }

/// Polls until `cond` holds (or times out) and returns the last state.
@discardableResult
func await_(_ timeout: Double = 3, _ cond: (State) -> Bool) -> State {
    let end = Date().addingTimeInterval(timeout)
    var s = state()
    while !cond(s) && Date() < end {
        pause(0.15)
        s = state()
    }
    return s
}

var passed = 0
var failed: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed.append(name)
        print("  ✗ \(name)  \(detail())")
    }
}

func section(_ s: String) { print("\n// \(s)") }

/// Every tiled window sits exactly where Nook put it.
func framesMatch(_ s: State) -> Bool {
    s.windows.filter { ($0["mode"] as? String) == "tiled" }.allSatisfy { w in
        Rect(w["actual"]).near(Rect(w["assigned"]))
    }
}

func focus(_ title: String) {
    nook("debug/focus?title=" + (title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title))
    pause(0.35)
}

/// Screen-level commands act on the active window's screen (else the pointer's),
/// so make a fixture window active first.
func onFixtureScreen(_ path: String) {
    if let title = state().windows.first(where: { ($0["mode"] as? String) == "tiled" })?["title"] as? String { focus(title) }
    nook(path)
}

func drag(_ from: (Double, Double), _ to: (Double, Double), mods: String = "") {
    nook("debug/drag?from=\(from.0),\(from.1)&to=\(to.0),\(to.1)&mods=\(mods)")
    pause(1.6)
}

// MARK: - Setup

let backup = work + "/prefs-backup.plist"
sh("defaults", "export", domain, backup)

func setJSON(_ key: String, _ json: String) {
    let hex = json.utf8.map { String(format: "%02x", $0) }.joined()
    sh("defaults", "write", domain, key, "-data", hex)
}

func restore() {
    sh("pkill", "-x", "NookFixture")
    sh("pkill", "-x", "NookFixtureBig")
    sh("pkill", "-x", "Nook")
    pause(0.5)
    sh("defaults", "delete", domain)
    sh("defaults", "import", domain, backup)
    sh("open", nookApp)
}

print("nook e2e — \(nookApp)")
sh("pkill", "-x", "Nook")
sh("pkill", "-x", "NookFixture")
sh("pkill", "-x", "NookFixtureBig")
pause(0.6)
for key in ["screenChoices", "weights", "learnedSizes", "floatRules", "quietNeedsRoom", "excludedApps"] {
    sh("defaults", "delete", domain, key)
}
setJSON("setupComplete", "true")
setJSON("tilingEnabled", "true")
setJSON("layout", "\"grid\"")
setJSON("windowsPerScreen", "3")
setJSON("overflow", "\"stack\"")
setJSON("mainSize", "\"half\"")
setJSON("gap", "8")
setJSON("separateOuterGap", "false")
setJSON("highlight", "\"none\"")
setJSON("noPeek", "false")
setJSON("quickActions", "true")
sh("defaults", "write", domain, "debugOnlyApps", "-array", fixtureID, bigID)

sh("open", nookApp)
var s = await_(6) { ($0.j["started"] as? Bool) == true || ($0.j["trusted"] as? Bool) == false }
guard (s.j["trusted"] as? Bool) == true else {
    print("\nNook doesn't have Accessibility access. Turn it on in System Settings → Privacy & Security → Accessibility, then run again.")
    restore()
    exit(2)
}
check("Nook is running and tiling", (s.j["status"] as? String)?.hasPrefix("Tiling") == true, "\(s.j["status"] ?? "?")")

sh("open", "-g", root + "/build/NookFixture.app")
sh("open", "-g", root + "/build/NookFixtureBig.app")
pause(1.5)

// MARK: - Tests

section("the fold")
fixture("open", "A")
s = await_ { $0.tiles.count == 1 && framesMatch($0) }
let rect = s.visible.inset(8)
check("one window fills the screen inside the gaps", s.tileFrames.first?.near(rect) == true, "\(s.tileFrames) vs \(rect)")
check("the window really is there", framesMatch(s))

fixture("open", "B")
s = await_ { $0.tiles.count == 2 && framesMatch($0) }
let half = (rect.w - 8) / 2
check("two windows share side by side", s.tileFrames.count == 2 && abs(s.tileFrames[0].w - half) < 2 && abs(s.tileFrames[1].x - (rect.x + half + 8)) < 2, "\(s.tileFrames)")
check("first window stays primary on the left", s.order == ["A", "B"], "\(s.order)")

fixture("open", "C")
s = await_ { $0.tiles.count == 3 && framesMatch($0) }
let f3 = s.tileFrames
check("three: the right half folds top and bottom", f3.count == 3 && abs(f3[1].x - f3[2].x) < 1 && f3[1].maxY < f3[2].y && abs(f3[0].h - rect.h) < 1, "\(f3)")
check("windows moved to their tiles", framesMatch(s))

onFixtureScreen("count/4")
fixture("open", "D")
s = await_ { $0.tiles.count == 4 && framesMatch($0) }
let f4 = s.tileFrames
check("four: a 2×2 grid, the fourth bottom-left", f4.count == 4 && abs(f4[3].x - f4[0].x) < 1 && f4[3].y > f4[0].y && abs(f4[2].y - f4[3].y) < 1, "\(f4)")

fixture("close", "B")
s = await_ { $0.tiles.count == 3 && framesMatch($0) }
check("closing one reflows the rest, order kept", s.order == ["A", "C", "D"], "\(s.order)")

section("layouts")
onFixtureScreen("layout/columns")
s = await_ { ($0.screen["layout"] as? String) == "columns" && framesMatch($0) }
check("columns: every window full height", s.tileFrames.allSatisfy { abs($0.h - rect.h) < 1 }, "\(s.tileFrames)")
onFixtureScreen("layout/rows")
s = await_ { ($0.screen["layout"] as? String) == "rows" && framesMatch($0) }
check("rows: every window full width", !s.tileFrames.isEmpty && s.tileFrames.allSatisfy { abs($0.w - rect.w) < 1 }, "\(s.tileFrames)")
onFixtureScreen("layout/side")
s = await_ { ($0.screen["layout"] as? String) == "side" && framesMatch($0) }
check("side: primary keeps full height", abs((s.tileFrames.first?.h ?? 0) - rect.h) < 1, "\(s.tileFrames)")
onFixtureScreen("cycle-layout")
s = await_ { ($0.screen["layout"] as? String) == "grid" }
check("cycle-layout wraps from side to grid", (s.screen["layout"] as? String) == "grid")
onFixtureScreen("count/3")
s = await_ { $0.tiles.count == 3 && framesMatch($0) }

section("stacks")
focus("C")
onFixtureScreen("count/2")
s = await_ { $0.tiles.count == 2 && framesMatch($0) }
let stacked = s.tiles.first { ($0["windows"] as? [Int] ?? []).count > 1 }
check("lowering the count stacks the last tile into the one before", s.tiles.count == 2 && stacked != nil, "\(s.tiles)")
fixture("open", "E")
s = await_ { $0.tileOf("E") != nil }
check("a new window on a full screen stacks in the active tile", s.tiles.count == 2 && s.showing(s.tileOf("E") ?? 9) == "E", "\(s.tiles)")
focus("E")
let before = s.showing(s.tileOf("E") ?? 0)
nook("stack-next")
s = await_ { $0.showing($0.tileOf("E") ?? 0) != before }
check("stack-next shows another window of the tile", s.showing(s.tileOf("E") ?? 0) != before, "still \(before ?? "-")")
check("stacked windows share their tile's frame", framesMatch(s))
onFixtureScreen("count/3")
s = await_ { $0.tiles.count == 3 && framesMatch($0) }
check("raising the count gives a waiting window its own tile", s.tiles.count == 3, "\(s.tiles.count)")
fixture("close", "E")
onFixtureScreen("count/3")
s = await_ { $0.tiles.count == 3 && $0.id("E") == nil && framesMatch($0) }

section("swapping")
s = state()
let first = s.showing(0) ?? "", second = s.showing(1) ?? ""
focus(first)
nook("swap/right")
s = await_ { $0.showing(0) == second }
check("swap/right trades the primary with the top of the right column", s.showing(0) == second && s.showing(1) == first, "\(s.order)")
check("swapped windows physically moved", framesMatch(await_ { framesMatch($0) }))
let third = s.showing(2) ?? ""
focus(third)
nook("primary")
s = await_ { $0.showing(0) == third }
check("primary moves the active window into tile 0", s.showing(0) == third, "\(s.order)")
focus(third)
nook("swap/left")
s = await_(1.5) { $0.showing(0) != third }
check("swap past the screen edge with one screen does nothing", s.showing(0) == third || (s.screens.count > 1), "\(s.order)")

section("sizes")
s = state()
let w0 = s.tileFrames[0].w
focus(s.showing(0) ?? "")
nook("grow")
s = await_ { $0.tileFrames.first.map { $0.w > w0 + 20 } ?? false }
check("grow widens the active window", s.tileFrames[0].w > w0 + 20, "\(w0) → \(s.tileFrames[0].w)")
check("custom sizes are noted for the panel", (s.screen["customSizes"] as? Bool) == true)
nook("shrink"); nook("shrink")
s = await_ { $0.tileFrames.first.map { $0.w < w0 - 20 } ?? false }
check("shrink narrows it", s.tileFrames[0].w < w0 - 20, "\(w0) → \(s.tileFrames[0].w)")
onFixtureScreen("reset")
s = await_ { $0.tileFrames.first.map { abs($0.w - w0) < 2 } ?? false }
check("reset returns to the starting sizes", abs(s.tileFrames[0].w - w0) < 2 && (s.screen["customSizes"] as? Bool) == false, "\(s.tileFrames[0].w)")

section("focus mode")
let primary = s.showing(0) ?? ""
focus(primary)
nook("focus")
s = await_ { ($0.screen["zoomed"] as? Int) != nil }
let zoomedActual = Rect(s.window(primary)?["actual"])
check("focus mode fills the screen with the active window", zoomedActual.near(rect), "\(zoomedActual) vs \(rect)")
nook("focus")
s = await_ { ($0.screen["zoomed"] as? Int) == nil && framesMatch($0) }
check("focus again puts it back", s.screen["zoomed"] == nil || s.screen["zoomed"] is NSNull, "\(s.screen["zoomed"] ?? "-")")

section("floating")
let floater = s.showing(2) ?? ""
focus(floater)
nook("float")
s = await_ { $0.mode(floater) == "floated" }
check("float takes the window out of the layout", s.mode(floater) == "floated" && s.tiles.count == 2, "\(s.mode(floater) ?? "-") tiles=\(s.tiles.count)")
let fr = Rect(s.window(floater)?["actual"])
check("a floated window sits in the middle", abs(fr.mid.0 - s.visible.mid.0) < 4 && abs(fr.mid.1 - s.visible.mid.1) < 4, "\(fr)")
nook("float")
s = await_ { $0.mode(floater) == "tiled" && $0.tiles.count == 3 }
check("float again tiles it at the end", s.showing(2) == floater, "\(s.order)")

fixture("dialog", "Inspector")
pause(1)
s = state()
check("panels and dialogs are never tiled", s.id("Inspector") == nil && s.tiles.count == 3)

section("minimize")
let mini = s.showing(1) ?? ""
fixture("minimize", mini)
s = await_ { $0.tiles.count == 2 }
check("minimizing a window reflows the others", s.tiles.count == 2 && s.id(mini) == nil, "\(s.order)")

section("an app that won't shrink")
onFixtureScreen("count/3")
fixture("open", "Big 1", big: true)
s = await_(6) { st in
    st.mode("Big 1") == "autoFloated" || ((st.j["prefs"] as? JSON)?["learned"] as? JSON)?["dev.mithun.nook.fixture.big"] != nil && framesMatch(st)
}
let learned = ((s.j["prefs"] as? JSON)?["learned"] as? JSON)?[bigID] as? [Double]
check("Nook learns the app's minimum size", learned.map { $0[0] >= 899 && $0[1] >= 649 } ?? false, "\(String(describing: learned))")
let bigMode = s.mode("Big 1") ?? "-"
let bigActual = Rect(s.window("Big 1")?["actual"])
check("it either gets room in the layout or floats", (bigMode == "tiled" && bigActual.w >= 899 && framesMatch(s)) || bigMode == "autoFloated",
      "mode=\(bigMode) actual=\(bigActual)")
check("nothing hangs off the screen", s.tileFrames.allSatisfy { $0.x >= s.visible.x - 1 && $0.maxX <= s.visible.maxX + 1 }, "\(s.tileFrames)")
fixture("closeAll", big: true)
s = await_ { $0.id("Big 1") == nil && framesMatch($0) }

section("mouse")
s = await_ { $0.tiles.count >= 2 && framesMatch($0) }
let a = s.showing(0) ?? "", b = s.showing(1) ?? ""
let t0 = s.tileFrames[0], t1 = s.tileFrames[1]
drag((t0.mid.0, t0.y + 12), (t1.mid.0, t1.mid.1), mods: "cmd")
s = await_ { $0.showing(0) == b }
check("⌘-drag a title bar onto another window swaps them", s.showing(0) == b && s.showing(1) == a, "\(s.order)")
s = await_ { framesMatch($0) }
let p0 = s.tileFrames[0]
drag((p0.mid.0, p0.y + 12), (p0.mid.0 + 60, p0.mid.1))
s = await_ { framesMatch($0) && $0.showing(0) == b }
check("a plain drag on the same screen snaps back", s.showing(0) == b && framesMatch(s), "\(s.order)")
let r0 = s.tileFrames[0]
drag((r0.maxX - 2, r0.mid.1), (r0.maxX + 140, r0.mid.1))
s = await_(3) { $0.tileFrames.first.map { $0.w > r0.w + 60 } ?? false }
check("dragging the edge between two windows resizes both", s.tileFrames[0].w > r0.w + 60 && abs(s.tileFrames[1].x - (s.tileFrames[0].maxX + 8)) < 2,
      "\(r0.w) → \(s.tileFrames.first?.w ?? 0)")
check("neighbours land exactly", framesMatch(await_ { framesMatch($0) }))
onFixtureScreen("reset")

section("overlays")
nook("debug/pref?key=highlight&value=borderAll")
s = await_ { ($0.visuals["borders"] ?? 0) == $0.tiles.count }
check("border on all draws one per tiled window", s.visuals["borders"] == s.tiles.count, "\(s.visuals)")
nook("debug/pref?key=highlight&value=glowActive")
s = await_ { ($0.visuals["glow"] ?? 0) == 1 }
check("glow on active draws one glow", s.visuals["glow"] == 1 && s.visuals["borders"] == 0, "\(s.visuals)")
nook("debug/pref?key=highlight&value=none")
nook("nopeek")
s = await_ { ($0.visuals["dimmers"] ?? 0) == $0.screens.count }
check("no peek shades every screen", s.visuals["dimmers"] == s.screens.count, "\(s.visuals)")
nook("nopeek")
s = await_ { ($0.visuals["dimmers"] ?? 1) == 0 }
check("no peek turns off", s.visuals["dimmers"] == 0, "\(s.visuals)")
focus(s.showing(0) ?? "")
nook("cleanspace")
s = await_ { ($0.visuals["cleanBackdrop"] ?? 0) == 1 }
let cleanActual = Rect(s.window(s.showing(0) ?? "")?["actual"])
check("clean space puts up a plain background", s.visuals["cleanBackdrop"] == 1, "\(s.visuals)")
check("clean space fills the screen with the active window", cleanActual.near(rect), "\(cleanActual)")
nook("cleanspace")
s = await_ { ($0.visuals["cleanBackdrop"] ?? 1) == 0 && framesMatch($0) }
check("clean space off puts everything back", s.visuals["cleanBackdrop"] == 0 && framesMatch(s), "\(s.visuals)")
check("a grip sits above the active tile", (s.visuals["grips"] ?? 0) >= 1, "\(s.visuals)")

section("overflow: float in the middle")
nook("debug/pref?key=overflow&value=float")
onFixtureScreen("count/2")
s = await_ { $0.tiles.count == 2 }
fixture("open", "F")
s = await_ { ($0.screen["overflow"] as? [Int] ?? []).contains($0.id("F") ?? -1) }
check("a window beyond the count waits in the middle", (s.screen["overflow"] as? [Int] ?? []).contains(s.id("F") ?? -1), "\(s.screen["overflow"] ?? "-")")
fixture("close", s.showing(1) ?? "")
s = await_ { $0.tileOf("F") != nil }
check("it joins when a tiled window closes", s.tileOf("F") != nil, "\(s.order)")
nook("debug/pref?key=overflow&value=stack")

section("shortcuts")
s = state()
let hotkeys = s.j["hotkeys"] as? [JSON] ?? []
let inUse = hotkeys.filter { ($0["state"] as? String) == "inUse" }.compactMap { $0["keys"] as? String }
let reserved = hotkeys.filter { ($0["state"] as? String) == "leftToMacOS" }.compactMap { $0["keys"] as? String }
check("all \(hotkeys.count) shortcuts registered", !hotkeys.isEmpty && inUse.isEmpty, "in use elsewhere: \(inUse)")
if !reserved.isEmpty { print("    note: left to macOS: \(reserved.joined(separator: " "))") }

section("interface")
let shots = work + "/shots"
try? FileManager.default.removeItem(atPath: shots)
nook("debug/panel?open=1")
pause(0.8)
nook("debug/snapshot?path=" + shots)
pause(0.8)
nook("debug/panel?open=0")
let files = (try? FileManager.default.contentsOfDirectory(atPath: shots)) ?? []
check("menu bar panel renders with live state", files.contains { $0.contains("KeyPanel") }, "\(files)")
print("    snapshots: \(shots)")

nook("retile")
s = await_ { framesMatch($0) }
check("retile leaves every window where it belongs", framesMatch(s))

// MARK: - Done

print("\n\(passed) passed, \(failed.count) failed")
if !failed.isEmpty { print("failed: " + failed.joined(separator: "; ")) }
restore()
exit(failed.isEmpty ? 0 : 1)

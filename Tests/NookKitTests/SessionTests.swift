import Testing
@testable import NookKit

@Suite struct Placing {
    func model(_ n: Int, capacity: Int = 4) -> ScreenModel {
        var m = ScreenModel(capacity: capacity)
        for w in 1...UInt32(n) { m.add(w, active: nil, mode: .stack) }
        return m
    }

    @Test func endIsTheDefault() {
        var m = model(2)
        #expect(m.add(9, active: 0, mode: .stack) == .tiled(2))
        #expect(m.showing == [1, 2, 9])
    }

    @Test func besideTheActiveTile() {
        var m = model(3)
        #expect(m.add(9, active: 0, mode: .stack, at: .afterActive) == .tiled(1))
        #expect(m.showing == [1, 9, 2, 3])
    }

    @Test func besideWithNothingActiveGoesLast() {
        var m = model(2)
        m.add(9, active: nil, mode: .stack, at: .afterActive)
        #expect(m.showing == [1, 2, 9])
    }

    @Test func firstBecomesPrimary() {
        var m = model(2)
        #expect(m.add(9, active: 1, mode: .stack, at: .first) == .tiled(0))
        #expect(m.showing == [9, 1, 2])
    }

    @Test func aFullScreenStillStacks() {
        var m = model(2, capacity: 2)
        #expect(m.add(9, active: 0, mode: .stack, at: .first) == .stacked(0))
    }
}

@Suite struct Arranging {
    @Test func ordersTilesBySlot() {
        var m = ScreenModel(capacity: 3)
        for w: UInt32 in [1, 2, 3] { m.add(w, active: nil, mode: .stack) }
        m.arrange(slot: [1: 2, 2: 0, 3: 1].index, mode: .stack)
        #expect(m.showing == [2, 3, 1])
    }

    @Test func windowsSharingASlotStack() {
        var m = ScreenModel(capacity: 3)
        for w: UInt32 in [1, 2, 3] { m.add(w, active: nil, mode: .stack) }
        m.arrange(slot: [1: 0, 2: 1, 3: 1].index, mode: .stack)
        #expect(m.tiles.count == 2)
        #expect(m.tiles[1].order.sorted() == [2, 3])
    }

    @Test func unknownWindowsKeepTheirOrderAfterKnownOnes() {
        var m = ScreenModel(capacity: 4)
        for w: UInt32 in [1, 2, 3, 4] { m.add(w, active: nil, mode: .stack) }
        m.arrange(slot: [4: 0].index, mode: .stack)
        #expect(m.showing == [4, 1, 2, 3])
    }

    @Test func neverMoreTilesThanCapacity() {
        var m = ScreenModel(capacity: 2)
        for w: UInt32 in [1, 2, 3] { m.add(w, active: 1, mode: .stack) }
        m.arrange(slot: [1: 0, 2: 1, 3: 2].index, mode: .stack)
        #expect(m.tiles.count == 2)
        #expect(m.windows.count == 3)
    }
}

@Suite struct Matching {
    let saved: [[SavedWindow]] = [
        [SavedWindow(id: 10, app: "com.term", title: Fingerprint.of("server"))],
        [SavedWindow(id: 11, app: "com.code", title: Fingerprint.of("nook")),
         SavedWindow(id: 12, app: "com.code", title: Fingerprint.of("other"))],
    ]

    @Test func sameIDWinsFirst() {
        let live = [SavedWindow(id: 10, app: "com.term", title: Fingerprint.of("renamed"))]
        #expect(SavedWindow.match(saved: saved, live: live) == [10: 0])
    }

    @Test func thenAppAndTitle() {
        let live = [SavedWindow(id: 99, app: "com.code", title: Fingerprint.of("other")),
                    SavedWindow(id: 98, app: "com.term", title: Fingerprint.of("server"))]
        #expect(SavedWindow.match(saved: saved, live: live) == [99: 1, 98: 0])
    }

    @Test func thenAnySavedWindowOfTheSameApp() {
        let live = [SavedWindow(id: 50, app: "com.code", title: Fingerprint.of("new")),
                    SavedWindow(id: 51, app: "com.code", title: Fingerprint.of("nook"))]
        // 51 takes its exact match; 50 takes the code window left over.
        #expect(SavedWindow.match(saved: saved, live: live) == [51: 1, 50: 1])
    }

    @Test func eachSavedWindowIsUsedOnce() {
        let live = [SavedWindow(id: 1, app: "com.term", title: "a"), SavedWindow(id: 2, app: "com.term", title: "b")]
        #expect(SavedWindow.match(saved: saved, live: live).count == 1)
    }

    @Test func otherAppsDoNotMatch() {
        #expect(SavedWindow.match(saved: saved, live: [SavedWindow(id: 7, app: "com.mail", title: "x")]).isEmpty)
    }

    @Test func fingerprintsAreStableAndHideTheTitle() {
        #expect(Fingerprint.of("Inbox") == Fingerprint.of("Inbox"))
        #expect(Fingerprint.of("Inbox") != Fingerprint.of("Outbox"))
        #expect(!Fingerprint.of("Inbox").contains("Inbox"))
    }
}

@Suite struct Versions {
    @Test func comparesPartByPart() {
        #expect(Version.isNewer("1.2.0", than: "1.1.9"))
        #expect(Version.isNewer("1.10", than: "1.9"))
        #expect(!Version.isNewer("1.0", than: "1.0.0"))
        #expect(!Version.isNewer("0.9", than: "1.0"))
    }

    @Test func ignoresALeadingV() {
        #expect(Version.isNewer("v2.0", than: "1.5"))
    }
}

private extension Dictionary where Key == UInt32, Value == Int {
    func index(_ w: UInt32) -> Int? { self[w] }
}

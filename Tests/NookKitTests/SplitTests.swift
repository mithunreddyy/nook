import CoreGraphics
import Foundation
import Testing
@testable import NookKit

@Suite struct SplitStacks {
    func stacked() -> ScreenModel {
        var m = ScreenModel(capacity: 2)
        for w: UInt32 in [1, 2] { m.add(w, active: nil, mode: .stack) }
        m.stack(3, onto: 1)
        return m
    }

    @Test func tabbedByDefault() {
        let m = stacked()
        #expect(m.tiles[1].split == false)
        #expect(m.visible == [1, 3])
    }

    @Test func splitShowsEveryWindowTopToBottom() {
        var m = stacked()
        m.toggleSplit(tile: 1)
        #expect(m.tiles[1].split)
        #expect(m.visible == [1, 2, 3])
        let rows = m.tiles[1].rows(in: CGRect(x: 0, y: 0, width: 100, height: 210), gap: 10)
        #expect(rows.map(\.0) == [2, 3])
        #expect(rows[0].1 == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(rows[1].1 == CGRect(x: 0, y: 110, width: 100, height: 100))
    }

    @Test func aSingleWindowIsNeverSplit() {
        var m = stacked()
        m.toggleSplit(tile: 0)
        #expect(m.tiles[0].split == false)
    }

    @Test func movingABoundaryChangesBothRows() {
        var t = stacked().tiles[1]
        t.split = true
        let r = CGRect(x: 0, y: 0, width: 100, height: 210)
        t.moveBoundary(after: 0, to: 140, in: r, gap: 10)
        let rows = t.rows(in: r, gap: 10)
        #expect(abs(rows[0].1.height - 140) < 0.5)
        #expect(abs(rows[1].1.minY - 150) < 0.5)
        #expect(abs(rows[1].1.maxY - 210) < 0.5)
    }

    @Test func rowsNeverGetTooShort() {
        var t = stacked().tiles[1]
        t.split = true
        let r = CGRect(x: 0, y: 0, width: 100, height: 410)
        t.moveBoundary(after: 0, to: 400, in: r, gap: 10)
        #expect(t.rows(in: r, gap: 10)[1].1.height >= Tile.minRow - 0.5)
    }

    @Test func evenRowsResetsHeights() {
        var t = stacked().tiles[1]
        t.split = true
        let r = CGRect(x: 0, y: 0, width: 100, height: 210)
        t.moveBoundary(after: 0, to: 140, in: r, gap: 10)
        t.evenRows()
        #expect(t.rows(in: r, gap: 10)[0].1.height == 100)
    }

    @Test func moveWithinTheStack() {
        var m = stacked()
        m.toggleSplit(tile: 1)
        let down = m.moveInTile(2, by: 1)
        #expect(down)
        #expect(m.tiles[1].order == [3, 2])
        let past = m.moveInTile(2, by: 1)
        #expect(!past)
    }

    @Test func popOutTakesTheNextTileWhenThereIsRoom() {
        var m = stacked()
        m.capacity = 3
        let popped = m.pop(3)
        #expect(popped)
        #expect(m.showing == [1, 2, 3])
    }

    @Test func popOutNeedsRoom() {
        var m = stacked()
        let popped = m.pop(3)
        #expect(!popped)
        #expect(m.tiles.count == 2)
    }

    @Test func stackingOntoALaterTileFindsIt() {
        var m = ScreenModel(capacity: 3)
        for w: UInt32 in [1, 2, 3] { m.add(w, active: nil, mode: .stack) }
        // Window 1's tile goes away, so tile 2 becomes tile 1.
        m.stack(1, onto: 2)
        #expect(m.tiles.count == 2)
        #expect(m.tileIndex(of: 1) == m.tileIndex(of: 3))
    }

    @Test func stackingSkipsOverTheTileThatGoesAway() {
        var m = ScreenModel(capacity: 4)
        for w: UInt32 in [1, 2, 3, 4] { m.add(w, active: nil, mode: .stack) }
        m.stack(1, onto: 2)
        #expect(m.tileIndex(of: 1) == m.tileIndex(of: 3))
        #expect(m.tiles.count == 3)
    }

    @Test func splitSurvivesEncoding() throws {
        var m = stacked()
        m.toggleSplit(tile: 1)
        let data = try JSONEncoder().encode(m)
        #expect(try JSONDecoder().decode(ScreenModel.self, from: data) == m)
    }
}

@Suite struct Pins {
    func model() -> ScreenModel {
        var m = ScreenModel(capacity: 4)
        for w: UInt32 in [1, 2, 3] { m.add(w, active: nil, mode: .stack) }
        return m
    }

    @Test func aPinnedWindowKeepsItsTileWhenANewOneGoesFirst() {
        var m = model()
        m.pin(2)
        m.add(9, active: nil, mode: .stack, at: .first)
        #expect(m.showing[1] == 2)
        #expect(Set(m.showing) == [1, 2, 3, 9])
    }

    @Test func swappingAPinnedWindowIsRefused() {
        var m = model()
        m.pin(1)
        m.swap(0, 2)
        #expect(m.showing == [1, 2, 3])
    }

    @Test func closingAWindowBeforeItKeepsThePinWhereItCan() {
        var m = model()
        m.pin(3)
        m.remove(1, mode: .stack)
        // Only two tiles left: the pinned window takes the last one.
        #expect(m.showing == [2, 3])
        m.add(4, active: nil, mode: .stack)
        #expect(m.showing == [2, 4, 3])
    }

    @Test func unpinAndForgetOnClose() {
        var m = model()
        m.pin(2)
        #expect(m.isPinned(2))
        m.unpin(2)
        #expect(!m.isPinned(2))
        m.pin(3)
        m.remove(3, mode: .stack)
        #expect(m.pinned.isEmpty)
    }
}

@Suite struct RestoringExtras {
    @Test func splitAndPinComeBack() {
        let saved: [[SavedWindow]] = [
            [SavedWindow(id: 1, app: "a", title: "x", pinned: true)],
            [SavedWindow(id: 2, app: "b", title: "y", split: true), SavedWindow(id: 3, app: "c", title: "z", split: true)],
        ]
        var m = ScreenModel(capacity: 3)
        for w: UInt32 in [3, 1, 2] { m.add(w, active: nil, mode: .stack) }
        let slots = SavedWindow.match(saved: saved, live: [SavedWindow(id: 1, app: "a", title: "x"),
                                                         SavedWindow(id: 2, app: "b", title: "y"),
                                                         SavedWindow(id: 3, app: "c", title: "z")])
        m.arrange(slot: { slots[$0] }, mode: .stack)
        SavedWindow.restoreExtras(&m, saved: saved, slots: slots)
        #expect(m.tiles.count == 2)
        #expect(m.tiles[1].split)
        #expect(m.isPinned(1))
    }
}

import Testing
@testable import NookKit

@Suite struct Stacks {
    func full(_ n: Int = 3) -> ScreenModel {
        var m = ScreenModel(capacity: n)
        for w in 1...UInt32(n) { m.add(w, active: nil, mode: .stack) }
        return m
    }

    @Test func windowsTakeTilesInOrder() {
        #expect(full().showing == [1, 2, 3])
    }

    @Test func overflowStacksOnTheActiveTile() {
        var m = full()
        #expect(m.add(4, active: 1, mode: .stack) == .stacked(1))
        #expect(m.showing == [1, 4, 3])
        #expect(m.tiles[1].order == [2, 4])
    }

    @Test func closingTheShowingWindowRevealsTheMostRecent() {
        var m = full()
        m.add(4, active: 0, mode: .stack)
        m.add(5, active: 0, mode: .stack)
        m.show(4)
        m.remove(4, mode: .stack)
        #expect(m.showing == [5, 2, 3])
    }

    @Test func closingATileReflowsAndPullsAWaitingWindowOut() {
        var m = full()
        m.add(4, active: 0, mode: .stack)
        m.remove(2, mode: .stack)
        #expect(m.tiles.count == 3)
        #expect(Set(m.windows) == [1, 3, 4])
    }

    @Test func closingThePrimaryPromotesTheNext() {
        var m = full()
        m.remove(1, mode: .stack)
        #expect(m.showing == [2, 3])
    }

    @Test func loweringTheCountMergesTheLastTile() {
        var m = full()
        m.setCapacity(2, mode: .stack)
        #expect(m.tiles.count == 2)
        #expect(m.showing == [1, 3])
        #expect(m.tiles[1].contains(2))
    }

    @Test func raisingTheCountGivesWaitingWindowsTiles() {
        var m = full()
        m.add(4, active: 0, mode: .stack)
        m.setCapacity(4, mode: .stack)
        #expect(m.tiles.count == 4)
    }

    @Test func swapMovesOnlyShowingWindows() {
        var m = full()
        m.add(4, active: 1, mode: .stack)
        m.swap(0, 1)
        #expect(m.showing == [4, 1, 3])
        #expect(m.tiles[1].contains(2))
        #expect(!m.tiles[0].contains(2))
    }

    @Test func cyclingWalksTheStack() {
        var m = full()
        m.add(4, active: 2, mode: .stack)
        #expect(m.cycle(tile: 2, by: 1) == 3)
        #expect(m.cycle(tile: 2, by: 1) == 4)
        #expect(m.cycle(tile: 2, by: -1) == 3)
    }

    @Test func floatModeQueuesAndRejoins() {
        var m = full(2)
        #expect(m.add(3, active: 0, mode: .float) == .overflow)
        m.remove(1, mode: .float)
        #expect(m.showing == [2, 3])
        #expect(m.overflow.isEmpty)
    }

    @Test func stackingOntoATileMovesTheWindow() {
        var m = full()
        m.stack(3, onto: 0)
        #expect(m.tiles.count == 2)
        #expect(m.tiles[0].showing == 3)
    }
}

import CoreGraphics

/// A tile holds one or more windows. Tabbed, one of them shows; split, they all
/// show, one above the other.
public struct Tile: Equatable, Codable, Sendable {
    /// Windows in this tile, most recently shown first.
    public private(set) var recent: [UInt32]

    public init(_ window: UInt32) {
        recent = [window]
        order = [window]
    }

    /// Every window shows, top to bottom in `order`, instead of one at a time.
    public var split = false
    /// Row heights in a split tile, as weights by window. Missing means 1.
    public private(set) var heights: [UInt32: Double] = [:]

    /// The shortest a row of a split tile gets, in points.
    public static let minRow: CGFloat = 50

    public var showing: UInt32 { recent[0] }
    public var count: Int { recent.count }
    public var isStack: Bool { recent.count > 1 }
    /// Stable order for the grip and chips: oldest first.
    public private(set) var order: [UInt32] = []

    public func contains(_ w: UInt32) -> Bool { recent.contains(w) }

    mutating func push(_ w: UInt32) {
        recent.removeAll { $0 == w }
        recent.insert(w, at: 0)
        if !order.contains(w) { order.append(w) }
    }

    mutating func show(_ w: UInt32) {
        guard let i = recent.firstIndex(of: w) else { return }
        recent.remove(at: i)
        recent.insert(w, at: 0)
    }

    mutating func remove(_ w: UInt32) {
        recent.removeAll { $0 == w }
        order.removeAll { $0 == w }
        heights[w] = nil
        if recent.count < 2 { split = false }
    }

    /// Each window's frame in a split tile, top to bottom.
    public func rows(in rect: CGRect, gap: CGFloat) -> [(UInt32, CGRect)] {
        let n = order.count
        guard n > 0 else { return [] }
        let total = max(rect.height - gap * CGFloat(n - 1), 0)
        let weights = order.map { max(heights[$0] ?? 1, 0.0001) }
        let sum = weights.reduce(0, +)
        var y = rect.minY
        var out: [(UInt32, CGRect)] = []
        for (i, w) in order.enumerated() {
            let h = i == n - 1 ? rect.maxY - y : total * CGFloat(weights[i] / sum)
            out.append((w, CGRect(x: rect.minX, y: y, width: rect.width, height: h)))
            y += h + gap
        }
        return out
    }

    /// Moves the line between row `i` and the row below it to `y`.
    public mutating func moveBoundary(after i: Int, to y: CGFloat, in rect: CGRect, gap: CGFloat) {
        let rows = rows(in: rect, gap: gap)
        guard i >= 0, i + 1 < rows.count else { return }
        let pair = rows[i].1.height + rows[i + 1].1.height
        let top = min(max(y - rows[i].1.minY, Self.minRow), pair - Self.minRow)
        // Weights become point heights, so the other rows keep theirs.
        for (w, r) in rows { heights[w] = Double(r.height) }
        heights[rows[i].0] = Double(top)
        heights[rows[i + 1].0] = Double(pair - top)
    }

    /// Grows (or shrinks) one row by `step` points, taking the room from its neighbours.
    public mutating func resizeRow(_ w: UInt32, by step: CGFloat, in rect: CGRect, gap: CGFloat) -> Bool {
        guard let i = order.firstIndex(of: w), order.count > 1 else { return false }
        let before = rows(in: rect, gap: gap)
        if i + 1 < order.count {
            moveBoundary(after: i, to: before[i].1.maxY + step, in: rect, gap: gap)
        } else {
            moveBoundary(after: i - 1, to: before[i - 1].1.maxY - step, in: rect, gap: gap)
        }
        let after = rows(in: rect, gap: gap)
        return abs(after[i].1.height - before[i].1.height) > 0.5
    }

    public mutating func evenRows() { heights = [:] }

    /// Moves `w` up (-1) or down (+1) among the rows.
    mutating func move(_ w: UInt32, by offset: Int) -> Bool {
        guard let i = order.firstIndex(of: w), order.indices.contains(i + offset) else { return false }
        order.swapAt(i, i + offset)
        return true
    }

    /// The window `offset` steps from the showing one in stable order.
    func neighbor(_ offset: Int) -> UInt32 {
        guard let i = order.firstIndex(of: showing), !order.isEmpty else { return showing }
        return order[((i + offset) % order.count + order.count) % order.count]
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recent = try c.decode([UInt32].self, forKey: .recent)
        order = try c.decode([UInt32].self, forKey: .order)
        split = try c.decodeIfPresent(Bool.self, forKey: .split) ?? false
        heights = try c.decodeIfPresent([UInt32: Double].self, forKey: .heights) ?? [:]
    }
}

public enum OverflowMode: String, Codable, CaseIterable, Sendable {
    case stack, float

    public var title: String {
        switch self {
        case .stack: "Stack in the active tile"
        case .float: "Float in the middle"
        }
    }
}

/// Where a new window's tile goes while the screen has room.
public enum InsertPosition: String, Codable, CaseIterable, Sendable {
    /// After every other tile: each new window takes half of the newest space.
    case end
    /// Right after the tile the user is working in.
    case afterActive
    /// In front, as the primary window.
    case first
}

public enum Placement: Equatable, Sendable {
    case tiled(Int)
    case stacked(Int)
    case overflow
}

/// The ordered tiles of one screen in one Space. Tile 0 is the primary.
public struct ScreenModel: Equatable, Codable, Sendable {
    public private(set) var tiles: [Tile] = []
    /// Windows waiting for room when the overflow mode is `.float`.
    public private(set) var overflow: [UInt32] = []
    public var capacity: Int
    /// Windows pinned to a tile position, by window: opens, closes and swaps leave them there.
    public private(set) var pinned: [UInt32: Int] = [:]

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    /// Every window that shows: the top of each tabbed tile, every window of a split one.
    public var visible: [UInt32] { tiles.flatMap { $0.split ? $0.order : [$0.showing] } }

    public var windows: [UInt32] { tiles.flatMap(\.recent) }
    public var showing: [UInt32] { tiles.map(\.showing) }

    public func contains(_ w: UInt32) -> Bool { tileIndex(of: w) != nil || overflow.contains(w) }

    public func tileIndex(of w: UInt32) -> Int? { tiles.firstIndex { $0.contains(w) } }

    /// Adds a window. `active` is the tile the user is working in, used when stacking.
    @discardableResult
    public mutating func add(_ w: UInt32, active: Int?, mode: OverflowMode, at position: InsertPosition = .end) -> Placement {
        if let i = tileIndex(of: w) { return .tiled(i) }
        if tiles.count < capacity {
            let i: Int
            switch position {
            case .end: i = tiles.count
            case .first: i = 0
            case .afterActive: i = active.map { min(max($0 + 1, 0), tiles.count) } ?? tiles.count
            }
            tiles.insert(Tile(w), at: i)
            reseat()
            return .tiled(tileIndex(of: w) ?? i)
        }
        switch mode {
        case .stack:
            let i = min(max(active ?? tiles.count - 1, 0), tiles.count - 1)
            tiles[i].push(w)
            return .stacked(i)
        case .float:
            if !overflow.contains(w) { overflow.append(w) }
            return .overflow
        }
    }

    /// Inserts a window into a specific tile's stack (⌥⌘-drag, chip drag).
    public mutating func stack(_ w: UInt32, onto tile: Int) {
        guard tiles.indices.contains(tile) else { return }
        pinned[w] = nil
        // Find the target by its window: taking `w` out can shift the tiles.
        let anchor = tiles[tile].showing
        if let from = tileIndex(of: w) {
            if from == tile { tiles[tile].show(w); return }
            detach(w, from: from)
        }
        overflow.removeAll { $0 == w }
        guard let target = tileIndex(of: anchor) else { add(w, active: nil, mode: .stack); return }
        tiles[target].push(w)
        reseat()
    }

    /// Removes a window. Returns true when the set of tiles changed shape.
    @discardableResult
    public mutating func remove(_ w: UInt32, mode: OverflowMode) -> Bool {
        overflow.removeAll { $0 == w }
        pinned[w] = nil
        guard let i = tileIndex(of: w) else { return false }
        let reshaped = detach(w, from: i)
        refill(mode: mode)
        reseat()
        return reshaped
    }

    @discardableResult
    private mutating func detach(_ w: UInt32, from i: Int) -> Bool {
        tiles[i].remove(w)
        if tiles[i].recent.isEmpty {
            tiles.remove(at: i)
            return true
        }
        return false
    }

    /// Gives waiting windows their own tiles while there's room.
    mutating func refill(mode: OverflowMode) {
        while tiles.count < capacity {
            if !overflow.isEmpty {
                let w = overflow.removeFirst()
                tiles.append(Tile(w))
                continue
            }
            // Pull the least recently shown waiting window out of the biggest tabbed stack.
            // Split stacks were made on purpose and stay together.
            guard let donor = tiles.indices.filter({ tiles[$0].isStack && !tiles[$0].split }).max(by: { tiles[$0].count < tiles[$1].count }) else { break }
            let w = tiles[donor].recent.last!
            tiles[donor].remove(w)
            tiles.append(Tile(w))
        }
    }

    /// Changes how many tiles this screen holds. Lowering merges the last
    /// tiles into the one before; raising gives waiting windows their own tile.
    public mutating func setCapacity(_ n: Int, mode: OverflowMode) {
        capacity = max(1, n)
        while tiles.count > capacity {
            let last = tiles.removeLast()
            switch mode {
            case .stack:
                // Keep the showing window on top of the merged tile.
                for w in last.recent.reversed() { tiles[tiles.count - 1].push(w) }
                tiles[tiles.count - 1].show(last.showing)
            case .float:
                overflow.insert(contentsOf: last.recent, at: 0)
            }
        }
        refill(mode: mode)
        reseat()
    }

    /// Swaps the showing windows of two tiles; stacks stay with their tiles.
    /// Tiles holding a pinned window don't swap.
    public mutating func swap(_ a: Int, _ b: Int) {
        guard a != b, tiles.indices.contains(a), tiles.indices.contains(b),
              !hasPin(a), !hasPin(b) else { return }
        let wa = tiles[a].showing, wb = tiles[b].showing
        tiles[a].replaceShowing(with: wb)
        tiles[b].replaceShowing(with: wa)
    }

    /// Notes that `w` is now the visible window of its tile.
    public mutating func show(_ w: UInt32) {
        guard let i = tileIndex(of: w) else { return }
        tiles[i].show(w)
    }

    /// The window shown after cycling tile `i`'s stack by `offset`.
    public mutating func cycle(tile i: Int, by offset: Int) -> UInt32? {
        guard tiles.indices.contains(i), tiles[i].isStack else { return nil }
        let w = tiles[i].neighbor(offset)
        tiles[i].show(w)
        return w
    }

    /// Moves window `w` out of tiling into another model (used across screens).
    public mutating func take(_ w: UInt32, mode: OverflowMode) -> Bool {
        remove(w, mode: mode)
    }

    /// Puts `w` into tile `i` replacing the showing window, which is returned.
    public mutating func replaceShowing(in i: Int, with w: UInt32) -> UInt32? {
        guard tiles.indices.contains(i) else { return nil }
        let old = tiles[i].showing
        tiles[i].replaceShowing(with: w)
        return old
    }

    public var isFull: Bool { tiles.count >= capacity }

    // MARK: - Split stacks

    /// Switches a stack between tabs (one shows) and split (all show, top to bottom).
    public mutating func toggleSplit(tile i: Int) {
        guard tiles.indices.contains(i), tiles[i].isStack else { return }
        tiles[i].split.toggle()
    }

    public mutating func setSplit(tile i: Int, _ on: Bool) {
        guard tiles.indices.contains(i), tiles[i].isStack || !on else { return }
        tiles[i].split = on
    }

    /// Moves `w` up or down inside its split tile. False at the top or bottom.
    public mutating func moveInTile(_ w: UInt32, by offset: Int) -> Bool {
        guard let i = tileIndex(of: w), tiles[i].split else { return false }
        return tiles[i].move(w, by: offset)
    }

    /// Takes `w` out of its stack into its own tile, right after it. Needs a free tile.
    public mutating func pop(_ w: UInt32) -> Bool {
        guard let i = tileIndex(of: w), tiles[i].isStack, tiles.count < capacity else { return false }
        tiles[i].remove(w)
        tiles.insert(Tile(w), at: i + 1)
        reseat()
        return true
    }

    public mutating func edit(tile i: Int, _ change: (inout Tile) -> Void) {
        guard tiles.indices.contains(i) else { return }
        change(&tiles[i])
    }

    // MARK: - Pins

    public func isPinned(_ w: UInt32) -> Bool { pinned[w] != nil }

    func hasPin(_ i: Int) -> Bool { tiles[i].recent.contains { pinned[$0] != nil } }

    public mutating func pin(_ w: UInt32) {
        guard let i = tileIndex(of: w) else { return }
        pinned[w] = i
    }

    public mutating func unpin(_ w: UInt32) { pinned[w] = nil }

    /// Puts pinned windows' tiles back at their positions, or as near as the tile count allows.
    mutating func reseat() {
        pinned = pinned.filter { tileIndex(of: $0.key) != nil }
        for (w, slot) in pinned.sorted(by: { $0.value < $1.value }) {
            guard let i = tileIndex(of: w) else { continue }
            let target = min(slot, tiles.count - 1)
            if i != target {
                let t = tiles.remove(at: i)
                tiles.insert(t, at: target)
            }
        }
    }

    /// Rebuilds the tiles from saved slots (session restore, workspaces).
    /// Windows sharing a slot stack together; tiles follow slot order; windows
    /// with no slot keep their tiles, in order, after the rest.
    public mutating func arrange(slot: (UInt32) -> Int?, mode: OverflowMode) {
        var groups: [Int: Tile] = [:]
        var rest: [Tile] = []
        for tile in tiles {
            var leftover: Tile?
            // Oldest shown first, so the most recent ends up showing.
            for w in tile.recent.reversed() {
                if let s = slot(w) {
                    if groups[s] == nil { groups[s] = Tile(w) } else { groups[s]!.push(w) }
                } else if leftover == nil {
                    leftover = Tile(w)
                } else {
                    leftover!.push(w)
                }
            }
            if let leftover { rest.append(leftover) }
        }
        tiles = groups.keys.sorted().compactMap { groups[$0] } + rest
        // Too many tiles for the screen: merge from the end, as lowering the count does.
        while tiles.count > capacity {
            let last = tiles.removeLast()
            switch mode {
            case .stack:
                for w in last.recent.reversed() { tiles[tiles.count - 1].push(w) }
                tiles[tiles.count - 1].show(last.showing)
            case .float:
                overflow.insert(contentsOf: last.recent, at: 0)
            }
        }
        reseat()
    }
}

extension Tile {
    /// Swaps in `w` (from elsewhere) as the showing window, in the same slot.
    mutating func replaceShowing(with w: UInt32) {
        let old = showing
        recent[0] = w
        if let o = order.firstIndex(of: old) { order[o] = w }
    }
}

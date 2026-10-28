/// A tile holds one or more windows; one of them shows.
public struct Tile: Equatable, Codable, Sendable {
    /// Windows in this tile, most recently shown first.
    public private(set) var recent: [UInt32]

    public init(_ window: UInt32) {
        recent = [window]
        order = [window]
    }

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

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public var windows: [UInt32] { tiles.flatMap(\.recent) }
    public var showing: [UInt32] { tiles.map(\.showing) }

    public func contains(_ w: UInt32) -> Bool { tileIndex(of: w) != nil || overflow.contains(w) }

    public func tileIndex(of w: UInt32) -> Int? { tiles.firstIndex { $0.contains(w) } }

    /// Adds a window. `active` is the tile the user is working in, used when stacking.
    @discardableResult
    public mutating func add(_ w: UInt32, active: Int?, mode: OverflowMode) -> Placement {
        if let i = tileIndex(of: w) { return .tiled(i) }
        if tiles.count < capacity {
            tiles.append(Tile(w))
            return .tiled(tiles.count - 1)
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
        if let from = tileIndex(of: w) {
            if from == tile { tiles[tile].show(w); return }
            detach(w, from: from)
        }
        overflow.removeAll { $0 == w }
        let target = min(tile, tiles.count - 1)
        guard target >= 0 else { add(w, active: nil, mode: .stack); return }
        tiles[target].push(w)
    }

    /// Removes a window. Returns true when the set of tiles changed shape.
    @discardableResult
    public mutating func remove(_ w: UInt32, mode: OverflowMode) -> Bool {
        overflow.removeAll { $0 == w }
        guard let i = tileIndex(of: w) else { return false }
        let reshaped = detach(w, from: i)
        refill(mode: mode)
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
            // Pull the least recently shown waiting window out of the biggest stack.
            guard let donor = tiles.indices.filter({ tiles[$0].isStack }).max(by: { tiles[$0].count < tiles[$1].count }) else { break }
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
    }

    /// Swaps the showing windows of two tiles; stacks stay with their tiles.
    public mutating func swap(_ a: Int, _ b: Int) {
        guard a != b, tiles.indices.contains(a), tiles.indices.contains(b) else { return }
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
}

extension Tile {
    /// Swaps in `w` (from elsewhere) as the showing window, in the same slot.
    mutating func replaceShowing(with w: UInt32) {
        let old = showing
        recent[0] = w
        if let o = order.firstIndex(of: old) { order[o] = w }
    }
}

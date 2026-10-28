import CoreGraphics

/// Custom split weights, keyed by node path ("" is the root, "/1" its second child, …).
public typealias SplitWeights = [String: [Double]]

public enum Edge: CaseIterable, Sendable {
    case left, right, top, bottom
}

/// The outcome of laying a split tree into a rectangle.
/// Rects use a top-left origin: `minY` is the top edge.
public struct Solution: Equatable, Sendable {
    public var frames: [Int: CGRect]
    /// False when the minimum sizes can't all be honored in the space available.
    public var fits: Bool
    /// Tiles whose minimum size couldn't be honored.
    public var cramped: Set<Int>
}

public struct Solver: Sendable {
    public var tree: SplitNode
    public var rect: CGRect
    public var gap: CGFloat
    public var weights: SplitWeights
    /// Per-tile minimum size (from the app, or the usable minimum).
    public var minimums: [Int: CGSize]

    public init(tree: SplitNode, rect: CGRect, gap: CGFloat, weights: SplitWeights = [:], minimums: [Int: CGSize] = [:]) {
        self.tree = tree
        self.rect = rect
        self.gap = gap
        self.weights = weights
        self.minimums = minimums
    }

    public func solve() -> Solution {
        var out = Solution(frames: [:], fits: true, cramped: [])
        place(tree, in: rect, path: "", into: &out)
        return out
    }

    // MARK: - Minimums

    func minimum(of node: SplitNode) -> CGSize {
        switch node {
        case .leaf(let i):
            let m = minimums[i] ?? .zero
            return CGSize(width: max(m.width, Layouts.usableMinimum.width),
                          height: max(m.height, Layouts.usableMinimum.height))
        case .split(let axis, let children, _):
            let mins = children.map(minimum(of:))
            let gaps = gap * CGFloat(children.count - 1)
            switch axis {
            case .horizontal:
                return CGSize(width: mins.map(\.width).reduce(0, +) + gaps, height: mins.map(\.height).max() ?? 0)
            case .vertical:
                return CGSize(width: mins.map(\.width).max() ?? 0, height: mins.map(\.height).reduce(0, +) + gaps)
            }
        }
    }

    func effectiveWeights(_ path: String, defaults: [Double]) -> [Double] {
        if let custom = weights[path], custom.count == defaults.count, custom.allSatisfy({ $0 > 0 }) {
            return custom
        }
        return defaults
    }

    // MARK: - Placement

    private func place(_ node: SplitNode, in r: CGRect, path: String, into out: inout Solution) {
        switch node {
        case .leaf(let i):
            out.frames[i] = r.integral
            let need = minimum(of: node)
            if r.width + 0.5 < need.width || r.height + 0.5 < need.height {
                out.fits = false
                out.cramped.insert(i)
            }
        case .split(let axis, let children, let defaults):
            let w = effectiveWeights(path, defaults: defaults)
            let mins = children.map(minimum(of:)).map { axis == .horizontal ? $0.width : $0.height }
            let total = (axis == .horizontal ? r.width : r.height) - gap * CGFloat(children.count - 1)
            let (lengths, ok) = Solver.distribute(total, weights: w, minimums: mins)
            if !ok { out.fits = false }
            var cursor = axis == .horizontal ? r.minX : r.minY
            for (idx, child) in children.enumerated() {
                let len = lengths[idx]
                let childRect = axis == .horizontal
                    ? CGRect(x: cursor, y: r.minY, width: len, height: r.height)
                    : CGRect(x: r.minX, y: cursor, width: r.width, height: len)
                place(child, in: childRect, path: path + "/\(idx)", into: &out)
                cursor += len + gap
            }
        }
    }

    /// Splits `total` by `weights`, giving every share at least its minimum
    /// by taking room from the others in proportion to their weights.
    static func distribute(_ total: CGFloat, weights: [Double], minimums: [CGFloat]) -> ([CGFloat], Bool) {
        let n = weights.count
        if minimums.reduce(0, +) > total + 0.5 {
            // Can't honor everyone: share proportionally to the minimums.
            let sum = max(minimums.reduce(0, +), 1)
            return (minimums.map { total * $0 / sum }, false)
        }
        var fixed = [CGFloat?](repeating: nil, count: n)
        while true {
            let free = (0..<n).filter { fixed[$0] == nil }
            let remaining = total - fixed.compactMap { $0 }.reduce(0, +)
            let wsum = free.map { weights[$0] }.reduce(0, +)
            var changed = false
            for i in free {
                let share = remaining * CGFloat(weights[i] / max(wsum, .ulpOfOne))
                if share < minimums[i] {
                    fixed[i] = minimums[i]
                    changed = true
                }
            }
            if !changed {
                return ((0..<n).map { i in
                    fixed[i] ?? remaining * CGFloat(weights[i] / max(wsum, .ulpOfOne))
                }, true)
            }
        }
    }

    // MARK: - Resizing

    /// The split that owns `edge` of tile `tile`: its path, axis, children, the
    /// child index on the tile's side of the boundary, and the split's rect.
    struct Boundary {
        var path: String
        var axis: Axis
        var children: [SplitNode]
        var defaults: [Double]
        var index: Int // boundary sits between `index` and `index + 1`
        var rect: CGRect
    }

    func boundary(of tile: Int, edge: Edge) -> Boundary? {
        var found: Boundary?
        func walk(_ node: SplitNode, _ r: CGRect, _ path: String) -> Bool {
            switch node {
            case .leaf(let i):
                return i == tile
            case .split(let axis, let children, let defaults):
                let w = effectiveWeights(path, defaults: defaults)
                let mins = children.map(minimum(of:)).map { axis == .horizontal ? $0.width : $0.height }
                let total = (axis == .horizontal ? r.width : r.height) - gap * CGFloat(children.count - 1)
                let (lengths, _) = Solver.distribute(total, weights: w, minimums: mins)
                var cursor = axis == .horizontal ? r.minX : r.minY
                for (idx, child) in children.enumerated() {
                    let childRect = axis == .horizontal
                        ? CGRect(x: cursor, y: r.minY, width: lengths[idx], height: r.height)
                        : CGRect(x: r.minX, y: cursor, width: r.width, height: lengths[idx])
                    cursor += lengths[idx] + gap
                    guard walk(child, childRect, path + "/\(idx)") else { continue }
                    if found == nil {
                        let matches: Bool
                        var at = idx
                        switch (axis, edge) {
                        case (.horizontal, .right), (.vertical, .bottom):
                            matches = idx < children.count - 1
                        case (.horizontal, .left), (.vertical, .top):
                            matches = idx > 0
                            at = idx - 1
                        default:
                            matches = false
                        }
                        if matches {
                            found = Boundary(path: path, axis: axis, children: children, defaults: defaults, index: at, rect: r)
                        }
                    }
                    return true
                }
                return false
            }
        }
        _ = walk(tree, rect, "")
        return found
    }

    /// Moves the boundary on `edge` of `tile` so that it sits at `coordinate`
    /// (an x for left/right, a y for top/bottom). Returns the new weights and
    /// whether anything moved. Minimum sizes clamp the move.
    public func moving(tile: Int, edge: Edge, to coordinate: CGFloat) -> (SplitWeights, Bool) {
        guard let b = boundary(of: tile, edge: edge) else { return (weights, false) }
        let horizontal = b.axis == .horizontal
        let w = effectiveWeights(b.path, defaults: b.defaults)
        let mins = b.children.map(minimum(of:)).map { horizontal ? $0.width : $0.height }
        let total = (horizontal ? b.rect.width : b.rect.height) - gap * CGFloat(b.children.count - 1)
        var (lengths, _) = Solver.distribute(total, weights: w, minimums: mins)

        let i = b.index
        let start = (horizontal ? b.rect.minX : b.rect.minY)
            + lengths[..<i].reduce(0, +) + gap * CGFloat(i)
        let pair = lengths[i] + lengths[i + 1]
        // The boundary is the far edge of child i; `coordinate` is that edge
        // (or, for a left/top edge drag, the near edge of child i+1).
        let target: CGFloat = (edge == .left || edge == .top) ? coordinate - gap - start : coordinate - start
        let a = min(max(target, mins[i]), pair - mins[i + 1])
        guard abs(a - lengths[i]) >= 1 else { return (weights, false) }
        lengths[i] = a
        lengths[i + 1] = pair - a
        let sum = lengths.reduce(0, +)
        var next = weights
        next[b.path] = lengths.map { Double($0 / sum) }
        return (next, true)
    }

    /// Grows (positive `step`) or shrinks the tile by moving each of its shared
    /// edges by `step` points. Returns the new weights and whether anything moved.
    public func resizing(tile: Int, by step: CGFloat) -> (SplitWeights, Bool) {
        var solver = self
        var moved = false
        for edge in Edge.allCases {
            guard let frame = solver.solve().frames[tile] else { break }
            let coordinate: CGFloat
            switch edge {
            case .left: coordinate = frame.minX - step
            case .right: coordinate = frame.maxX + step
            case .top: coordinate = frame.minY - step
            case .bottom: coordinate = frame.maxY + step
            }
            let (w, ok) = solver.moving(tile: tile, edge: edge, to: coordinate)
            if ok {
                solver.weights = w
                moved = true
            }
        }
        return (solver.weights, moved)
    }

    /// Which edges of `old` changed in `new`, past a small tolerance.
    public static func changedEdges(from old: CGRect, to new: CGRect, tolerance: CGFloat = 2) -> [(Edge, CGFloat)] {
        var edges: [(Edge, CGFloat)] = []
        if abs(new.minX - old.minX) > tolerance { edges.append((.left, new.minX)) }
        if abs(new.maxX - old.maxX) > tolerance { edges.append((.right, new.maxX)) }
        if abs(new.minY - old.minY) > tolerance { edges.append((.top, new.minY)) }
        if abs(new.maxY - old.maxY) > tolerance { edges.append((.bottom, new.maxY)) }
        return edges
    }
}

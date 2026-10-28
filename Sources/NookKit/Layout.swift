import CoreGraphics

/// How a screen shares its room between tiled windows.
public enum LayoutKind: String, CaseIterable, Codable, Sendable {
    case grid, columns, rows, side

    public var title: String {
        switch self {
        case .grid: "Grid"
        case .columns: "Columns"
        case .rows: "Rows"
        case .side: "Side"
        }
    }

    public var next: LayoutKind {
        let all = LayoutKind.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Screens that get layout variants of their own.
public enum ScreenShape: String, Codable, Sendable {
    case standard, ultrawide, vertical

    public init(size: CGSize) {
        if size.height > size.width {
            self = .vertical
        } else if size.width >= size.height * 2 {
            self = .ultrawide
        } else {
            self = .standard
        }
    }
}

/// How much room the primary window starts with.
public enum MainSize: String, CaseIterable, Codable, Sendable {
    case half, sixty, twoThirds

    public var fraction: Double {
        switch self {
        case .half: 0.5
        case .sixty: 0.6
        case .twoThirds: 2.0 / 3.0
        }
    }

    public var title: String {
        switch self {
        case .half: "Half"
        case .sixty: "60%"
        case .twoThirds: "Two-thirds"
        }
    }
}

public enum Axis: Sendable {
    /// Children sit side by side; boundaries are vertical lines.
    case horizontal
    /// Children are stacked top to bottom; boundaries are horizontal lines.
    case vertical
}

/// A layout is a tree of splits whose leaves are tile indices (0 = primary).
public indirect enum SplitNode: Equatable, Sendable {
    case leaf(Int)
    case split(Axis, [SplitNode], weights: [Double])

    public var leaves: [Int] {
        switch self {
        case .leaf(let i): [i]
        case .split(_, let children, _): children.flatMap(\.leaves)
        }
    }
}

public enum Layouts {
    /// Smallest size a tile is allowed to be, whatever the app says.
    public static let usableMinimum = CGSize(width: 200, height: 140)

    /// The most tiles `layout` can hold on a screen of `size` at a usable size.
    public static func capacity(_ layout: LayoutKind, shape: ScreenShape, size: CGSize) -> Int {
        switch (layout, shape) {
        case (.grid, _): return 4
        case (.side, .ultrawide), (.side, .vertical): return 5
        case (.rows, .vertical), (.columns, .vertical): return 3
        case (.columns, _): return clamp(Int(size.width / 450), 1, 4)
        case (.rows, _): return clamp(Int(size.height / 400), 1, 3)
        case (.side, .standard): return 1 + clamp(Int(size.height / 400), 1, 3)
        }
    }

    /// Highest count the window-count picker offers on this screen.
    public static func maxCount(shape: ScreenShape) -> Int {
        shape == .standard ? 4 : 5
    }

    /// Columns makes no sense on a portrait screen; it falls back to rows there.
    public static func effective(_ layout: LayoutKind, shape: ScreenShape) -> LayoutKind {
        (layout == .columns && shape == .vertical) ? .rows : layout
    }

    public static func tree(_ layout: LayoutKind, shape: ScreenShape, count n: Int, main: Double) -> SplitNode {
        precondition(n >= 1)
        if n == 1 { return .leaf(0) }
        let layout = effective(layout, shape: shape)
        let rest = { (k: Int) in Array(repeating: (1 - main) / Double(k), count: k) }
        let equal = { (k: Int) in Array(repeating: 1.0 / Double(k), count: k) }
        let leaves = { (r: Range<Int>) in r.map { SplitNode.leaf($0) } }

        if shape == .vertical {
            switch layout {
            case .grid:
                switch n {
                case 2: return .split(.vertical, leaves(0..<2), weights: [main, 1 - main])
                case 3: return .split(.vertical, [.leaf(0), .split(.horizontal, leaves(1..<3), weights: equal(2))], weights: [main, 1 - main])
                default:
                    return .split(.vertical, [
                        .split(.horizontal, [.leaf(0), .leaf(1)], weights: equal(2)),
                        .split(.horizontal, [.leaf(3), .leaf(2)], weights: equal(2)),
                    ], weights: [main, 1 - main])
                }
            case .side:
                let others = n - 1
                let bottom: SplitNode = others == 1 ? .leaf(1)
                    : .split(others <= 2 ? .horizontal : .vertical, leaves(1..<n), weights: equal(others))
                return .split(.vertical, [.leaf(0), bottom], weights: [main, 1 - main])
            case .rows, .columns:
                return .split(.vertical, leaves(0..<n), weights: [main] + rest(n - 1))
            }
        }

        switch layout {
        case .grid:
            switch n {
            case 2: return .split(.horizontal, leaves(0..<2), weights: [main, 1 - main])
            case 3: return .split(.horizontal, [.leaf(0), .split(.vertical, leaves(1..<3), weights: equal(2))], weights: [main, 1 - main])
            default:
                return .split(.horizontal, [
                    .split(.vertical, [.leaf(0), .leaf(3)], weights: equal(2)),
                    .split(.vertical, [.leaf(1), .leaf(2)], weights: equal(2)),
                ], weights: [main, 1 - main])
            }
        case .columns:
            return .split(.horizontal, leaves(0..<n), weights: [main] + rest(n - 1))
        case .rows:
            return .split(.vertical, leaves(0..<n), weights: [main] + rest(n - 1))
        case .side:
            if n == 2 { return .split(.horizontal, leaves(0..<2), weights: [main, 1 - main]) }
            if shape == .ultrawide {
                // Two big windows, the rest in a quarter-width column.
                let column: SplitNode = n == 3 ? .leaf(2) : .split(.vertical, leaves(2..<n), weights: equal(n - 2))
                return .split(.horizontal, [.leaf(0), .leaf(1), column], weights: [0.75 * main, 0.75 * (1 - main), 0.25])
            }
            return .split(.horizontal, [.leaf(0), .split(.vertical, leaves(1..<n), weights: equal(n - 1))], weights: [main, 1 - main])
        }
    }

    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}

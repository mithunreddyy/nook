import CoreGraphics
import Testing
@testable import NookKit

let laptop = CGRect(x: 0, y: 0, width: 1470, height: 920)

func frames(_ layout: LayoutKind, _ n: Int, rect: CGRect = laptop, gap: CGFloat = 0, shape: ScreenShape = .standard, main: Double = 0.5) -> [Int: CGRect] {
    Solver(tree: Layouts.tree(layout, shape: shape, count: n, main: main), rect: rect, gap: gap).solve().frames
}

@Suite struct GridFold {
    @Test func oneWindowFillsTheScreen() {
        #expect(frames(.grid, 1)[0] == laptop)
    }

    @Test func twoSideBySidePrimaryLeft() {
        let f = frames(.grid, 2)
        #expect(f[0] == CGRect(x: 0, y: 0, width: 735, height: 920))
        #expect(f[1] == CGRect(x: 735, y: 0, width: 735, height: 920))
    }

    @Test func threeFoldsTheRightHalf() {
        let f = frames(.grid, 3)
        #expect(f[1] == CGRect(x: 735, y: 0, width: 735, height: 460))
        #expect(f[2] == CGRect(x: 735, y: 460, width: 735, height: 460))
    }

    @Test func fourthTakesBottomOfPrimaryColumn() {
        let f = frames(.grid, 4)
        #expect(f[0] == CGRect(x: 0, y: 0, width: 735, height: 460))
        #expect(f[3] == CGRect(x: 0, y: 460, width: 735, height: 460))
        #expect(f[2] == CGRect(x: 735, y: 460, width: 735, height: 460))
    }

    @Test func gapsSeparateTiles() {
        let f = frames(.grid, 2, gap: 8)
        #expect(f[1]!.minX - f[0]!.maxX == 8)
    }

    @Test func mainSizeWidensPrimary() {
        let f = frames(.grid, 2, main: 2.0 / 3.0)
        #expect(f[0]!.width == 980)
    }
}

@Suite struct OtherLayouts {
    @Test func columnsAreFullHeight() {
        let f = frames(.columns, 3)
        #expect(f.values.allSatisfy { $0.height == 920 })
        #expect(f[0]!.minX < f[1]!.minX && f[1]!.minX < f[2]!.minX)
    }

    @Test func rowsAreFullWidth() {
        let f = frames(.rows, 2)
        #expect(f.values.allSatisfy { $0.width == 1470 })
    }

    @Test func sideKeepsPrimaryBig() {
        let f = frames(.side, 4)
        #expect(f[0]!.width == 735 && f[0]!.height == 920)
        #expect(f[1]!.minX == 735 && f[3]!.minX == 735)
    }

    @Test func ultrawideSideHasNarrowColumn() {
        let wide = CGRect(x: 0, y: 0, width: 3440, height: 1400)
        let f = frames(.side, 5, rect: wide, shape: .ultrawide)
        #expect(f[4]!.width == 860)
        #expect(f[0]!.width == f[1]!.width)
    }

    @Test func verticalGridStacksTopBottom() {
        let tall = CGRect(x: 0, y: 0, width: 1080, height: 1900)
        let f = frames(.grid, 2, rect: tall, shape: .vertical)
        #expect(f[0]!.width == 1080 && f[1]!.minY == 950)
    }

    @Test func capacityMatchesScreenSize() {
        let mac = laptop.size, big = CGSize(width: 2560, height: 1415)
        #expect(Layouts.capacity(.columns, shape: .standard, size: mac) == 3)
        #expect(Layouts.capacity(.columns, shape: .standard, size: big) == 4)
        #expect(Layouts.capacity(.rows, shape: .standard, size: mac) == 2)
        #expect(Layouts.capacity(.rows, shape: .standard, size: big) == 3)
        #expect(Layouts.capacity(.side, shape: .standard, size: mac) == 3)
        #expect(Layouts.capacity(.side, shape: .standard, size: big) == 4)
    }

    @Test func shapes() {
        #expect(ScreenShape(size: CGSize(width: 3440, height: 1440)) == .ultrawide)
        #expect(ScreenShape(size: CGSize(width: 1080, height: 1920)) == .vertical)
        #expect(ScreenShape(size: laptop.size) == .standard)
    }
}

@Suite struct Minimums {
    @Test func boundaryMovesToHonorAMinimum() {
        let tree = Layouts.tree(.grid, shape: .standard, count: 2, main: 0.5)
        let s = Solver(tree: tree, rect: laptop, gap: 0, minimums: [0: CGSize(width: 952, height: 732)]).solve()
        #expect(s.fits)
        #expect(s.frames[0]!.width == 952)
        #expect(s.frames[1]!.width == 518)
    }

    @Test func reportsWhenItCannotFit() {
        let tree = Layouts.tree(.grid, shape: .standard, count: 3, main: 0.5)
        let s = Solver(tree: tree, rect: laptop, gap: 0, minimums: [2: CGSize(width: 952, height: 800)]).solve()
        #expect(!s.fits)
        #expect(s.cramped.contains(2))
    }
}

@Suite struct Resizing {
    @Test func draggingAnEdgeMovesTheBoundary() {
        let tree = Layouts.tree(.grid, shape: .standard, count: 3, main: 0.5)
        let solver = Solver(tree: tree, rect: laptop, gap: 8)
        let (w, moved) = solver.moving(tile: 0, edge: .right, to: 900)
        #expect(moved)
        var next = solver
        next.weights = w
        let f = next.solve().frames
        #expect(abs(f[0]!.maxX - 900) <= 1)
        #expect(abs(f[1]!.minX - 908) <= 1)
    }

    @Test func draggingALeftEdgeMovesTheSameBoundary() {
        let tree = Layouts.tree(.grid, shape: .standard, count: 2, main: 0.5)
        let solver = Solver(tree: tree, rect: laptop, gap: 8)
        let (w, _) = solver.moving(tile: 1, edge: .left, to: 600)
        var next = solver
        next.weights = w
        #expect(abs(next.solve().frames[1]!.minX - 600) <= 1)
    }

    @Test func outerEdgesDoNothing() {
        let tree = Layouts.tree(.grid, shape: .standard, count: 2, main: 0.5)
        let (_, moved) = Solver(tree: tree, rect: laptop, gap: 0).moving(tile: 0, edge: .left, to: 100)
        #expect(!moved)
    }

    @Test func growingStopsAtTheMinimum() {
        let tree = Layouts.tree(.grid, shape: .standard, count: 2, main: 0.5)
        var solver = Solver(tree: tree, rect: laptop, gap: 0)
        for _ in 0..<100 { solver.weights = solver.resizing(tile: 0, by: 40).0 }
        #expect(solver.solve().frames[1]!.width == Layouts.usableMinimum.width)
        #expect(!solver.resizing(tile: 0, by: 40).1)
    }
}

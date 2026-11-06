import Testing
@testable import TermquiltCore

/// Cells must cover their regions exactly: no overlap, no gaps, nothing outside.
func expectExactFill(_ cells: [Rect], of regions: [Rect], sourceLocation: SourceLocation = #_sourceLocation) {
    for (index, cell) in cells.enumerated() {
        #expect(!cells[(index + 1)...].contains { $0.intersects(cell) }, "cells overlap", sourceLocation: sourceLocation)
        #expect(regions.contains { cell.clipped(to: $0) == cell }, "cell outside regions", sourceLocation: sourceLocation)
    }
    let usedRegions = regions.filter { region in cells.contains { $0.intersects(region) } }
    #expect(cells.map(\.area).reduce(0, +) == usedRegions.map(\.area).reduce(0, +), "gaps", sourceLocation: sourceLocation)
}

@Suite struct ApportionTests {
    @Test func splitsInProportionToWeight() {
        #expect(apportion(12, weights: [1, 1], capacities: [12, 12]) == [6, 6])
        #expect(apportion(9, weights: [2, 1], capacities: [9, 9]) == [6, 3])
    }

    @Test func alwaysHandsOutExactlyTheCount() {
        for count in 1...30 {
            let shares = apportion(count, weights: [3, 5, 7], capacities: [30, 30, 30])
            #expect(shares.reduce(0, +) == count)
        }
    }

    @Test func respectsCapacities() {
        #expect(apportion(5, weights: [100, 1], capacities: [2, 10]) == [2, 3])
    }
}

@Suite struct TileGridTests {
    let metrics = TerminalMetrics(scale: 1)

    @Test func perfectGridsFillEveryCellEqually() {
        let region = Rect(x: 0, y: 0, width: 1200, height: 800)
        let cells = cells(count: 6, grid: TileGrid(columns: 3, rows: 2), in: region)
        #expect(Set(cells.map { Size(width: $0.width, height: $0.height) }) == [Size(width: 400, height: 400)])
        expectExactFill(cells, of: [region])
    }

    @Test func oddCountsStretchTheShorterRowSoNoSpaceIsWasted() {
        let region = Rect(x: 0, y: 0, width: 1200, height: 800)
        let cells = cells(count: 5, grid: TileGrid(columns: 3, rows: 2), in: region)
        #expect(cells.prefix(3).allSatisfy { $0.width == 400 })
        #expect(cells.suffix(2).allSatisfy { $0.width == 600 })
        expectExactFill(cells, of: [region])
    }

    @Test func rowsDifferByAtMostOneWindow() {
        let region = Rect(x: 0, y: 0, width: 1200, height: 900)
        let cells = cells(count: 7, grid: TileGrid(columns: 3, rows: 3), in: region)
        let counts = Dictionary(grouping: cells, by: \.y).values.map(\.count).sorted()
        #expect(counts == [2, 2, 3])
    }

    @Test func unevenPixelsAreDistributedWithoutGaps() {
        let region = Rect(x: 7, y: 11, width: 1001, height: 703)
        expectExactFill(cells(count: 7, grid: TileGrid(columns: 3, rows: 3), in: region), of: [region])
    }

    @Test func ultrawideDisplaysPreferSideBySideColumns() {
        let region = Rect(x: 0, y: 30, width: 5120, height: 1332)
        let grid = chooseTileGrid(count: 4, in: region, font: 18, metrics: metrics, minimum: .readable)
        #expect(grid == TileGrid(columns: 4, rows: 1))
    }

    @Test func squarishDisplaysStackInBothDirections() {
        let region = Rect(x: 0, y: 25, width: 1728, height: 1040)
        let grid = chooseTileGrid(count: 4, in: region, font: 11, metrics: metrics, minimum: .readable)
        #expect(grid == TileGrid(columns: 2, rows: 2))
    }
}

@Suite struct PlanLayoutTests {
    let metrics = TerminalMetrics(scale: 1)
    let odyssey = Rect(x: 0, y: 30, width: 5120, height: 1332)

    @Test func twelveTerminalsOnTheBareUltrawideGetALargeFont() {
        let plan = planLayout(windowCount: 12, regions: [odyssey], font: .automatic, metrics: metrics)
        #expect(plan.fontSize == 16)
        #expect(plan.grids == [TileGrid(columns: 6, rows: 2)])
        #expect(plan.meetsMinimum)
        expectExactFill(plan.cells, of: [odyssey])
    }

    @Test func twelveTerminalsAroundTheBrowserSplitEvenlyLeftAndRight() {
        let left = Rect(x: 0, y: 30, width: 1671, height: 1332)
        let right = Rect(x: 3646, y: 30, width: 1474, height: 1332)
        let plan = planLayout(windowCount: 12, regions: [left, right], font: .automatic, metrics: metrics)
        #expect(plan.fontSize == 13)
        #expect(plan.grids == [TileGrid(columns: 2, rows: 3), TileGrid(columns: 2, rows: 3)])
        #expect(plan.meetsMinimum)
        expectExactFill(plan.cells, of: [left, right])
    }

    @Test func autoFontStopsAtTheCeilingForASingleWindow() {
        let plan = planLayout(windowCount: 1, regions: [odyssey], font: .automatic, metrics: metrics)
        #expect(plan.fontSize == FontLimits.autoMaximum)
        #expect(plan.cells == [odyssey])
    }

    @Test func tooManyWindowsStayReadableAndAdmitTheyMissTheMinimum() {
        let laptop = Rect(x: 0, y: 25, width: 1728, height: 1040)
        let plan = planLayout(windowCount: 12, regions: [laptop], font: .automatic, metrics: TerminalMetrics(scale: 2))
        #expect(plan.fontSize == FontLimits.autoMinimum)
        #expect(!plan.meetsMinimum)
        #expect(plan.cells.count == 12)
        expectExactFill(plan.cells, of: [laptop])
    }

    @Test func aFixedFontIsAlwaysHonoured() {
        let tooBig = planLayout(windowCount: 12, regions: [odyssey], font: .fixed(30), metrics: metrics)
        #expect(tooBig.fontSize == 30)
        #expect(!tooBig.meetsMinimum)
        #expect(tooBig.cells.count == 12)

        let fits = planLayout(windowCount: 12, regions: [odyssey], font: .fixed(13), metrics: metrics)
        #expect(fits.fontSize == 13)
        #expect(fits.meetsMinimum)
    }

    @Test func everyWindowCountFillsItsRegionsExactly() {
        let regions = [
            Rect(x: 0, y: 30, width: 1671, height: 1332),
            Rect(x: 3646, y: 30, width: 1474, height: 1332),
        ]
        for count in 1...30 {
            let plan = planLayout(windowCount: count, regions: regions, font: .automatic, metrics: metrics)
            #expect(plan.cells.count == count, "count \(count)")
            expectExactFill(plan.cells, of: regions)
        }
    }

    @Test func noWindowsMeansAnEmptyPlan() {
        let plan = planLayout(windowCount: 0, regions: [odyssey], font: .automatic, metrics: metrics)
        #expect(plan.cells.isEmpty)
    }
}

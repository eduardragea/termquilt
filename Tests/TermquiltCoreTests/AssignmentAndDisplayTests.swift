import Testing
@testable import TermquiltCore

func window(
    _ id: Int, _ x: Int, _ y: Int, _ width: Int = 597, _ height: Int = 385,
    columns: Int = 80, rows: Int = 24, font: Int = 11, title: String = "term"
) -> TerminalWindow {
    TerminalWindow(
        id: id, title: title,
        frame: Rect(x: x, y: y, width: width, height: height),
        grid: CharGrid(columns: columns, rows: rows), fontSize: font
    )
}

@Suite struct AssignmentTests {
    let metrics = TerminalMetrics(scale: 1)
    let cells = [
        Rect(x: 0, y: 0, width: 500, height: 500),
        Rect(x: 500, y: 0, width: 500, height: 500),
    ]

    @Test func windowsStayOnTheirSideOfTheScreen() {
        let placements = assignPlacements(
            windows: [window(1, 900, 10), window(2, 10, 10)],
            cells: cells, fontSize: 11, metrics: metrics
        )
        #expect(placements.first { $0.windowID == 1 }?.frame == cells[1])
        #expect(placements.first { $0.windowID == 2 }?.frame == cells[0])
    }

    @Test func reTilingAnAlreadyTiledLayoutKeepsEveryWindowInPlace() {
        let tiled = [
            window(1, 0, 0, 500, 500),
            window(2, 500, 0, 500, 500),
        ]
        let placements = assignPlacements(windows: tiled, cells: cells, fontSize: 11, metrics: metrics)
        #expect(placements.first { $0.windowID == 1 }?.frame == cells[0])
        #expect(placements.first { $0.windowID == 2 }?.frame == cells[1])
    }

    @Test func tiesResolveTheSameWayEveryTime() {
        let windows = [window(5, 250, 0), window(3, 250, 0)]
        let first = assignPlacements(windows: windows, cells: cells, fontSize: 11, metrics: metrics)
        let second = assignPlacements(windows: windows.reversed(), cells: cells, fontSize: 11, metrics: metrics)
        #expect(Set(first) == Set(second))
    }

    @Test func aDifferentFontIsSetDirectly() {
        let placements = assignPlacements(windows: [window(1, 0, 0, font: 11)], cells: [cells[0]], fontSize: 14, metrics: metrics)
        #expect(placements[0].fontAction == .set)
    }

    @Test func theRightFontNeedsNoAction() {
        // 597x385 at 80x24 is exactly what 11pt measures.
        let placements = assignPlacements(windows: [window(1, 0, 0, font: 11)], cells: [cells[0]], fontSize: 11, metrics: metrics)
        #expect(placements[0].fontAction == .none)
    }

    @Test func aCmdZoomedWindowThatReportsTheTargetFontIsForcedToRefresh() {
        // Real case: reports 11pt, but 820x504 at 87x24 means the cells are 9x19, about 15pt.
        let zoomed = window(1, 0, 0, 820, 504, columns: 87, rows: 24, font: 11)
        let placements = assignPlacements(windows: [zoomed], cells: [cells[0]], fontSize: 11, metrics: metrics)
        #expect(placements[0].fontAction == .refresh)
    }

    @Test func oneNotchOfZoomIsCaughtByCellHeight() {
        // Reports 11pt (cells 7x14), but rendered cells are 7x15, which is 12pt.
        let zoomed = window(1, 0, 0, 597, 408, columns: 80, rows: 24, font: 11)
        let placements = assignPlacements(windows: [zoomed], cells: [cells[0]], fontSize: 11, metrics: metrics)
        #expect(placements[0].fontAction == .refresh)
    }

    @Test func aWindowAlreadyInItsSlotIsNeverRefreshedEvenIfCellsLookOff() {
        // Zooming changes a window's frame, so one sitting exactly in its slot cannot be zoomed.
        // Prediction is up to a point off at some sizes; that must not cause a flicker on re-tile.
        let inSlot = window(1, 0, 0, 500, 500, columns: 40, rows: 15, font: 17)
        let placements = assignPlacements(windows: [inSlot], cells: [cells[0]], fontSize: 17, metrics: metrics)
        #expect(placements[0].fontAction == .none)
    }

    @Test func aWindowAlreadyInPlaceWithTheRightFontNeedsNoChange() {
        let placed = window(1, 0, 0, 597, 385, font: 11)
        let placement = WindowPlacement(windowID: 1, frame: placed.frame, fontSize: 11, fontAction: .none)
        #expect(!placement.changes(placed))
        let moved = WindowPlacement(windowID: 1, frame: cells[1], fontSize: 11, fontAction: .none)
        #expect(moved.changes(placed))
        let refont = WindowPlacement(windowID: 1, frame: placed.frame, fontSize: 12, fontAction: .set)
        #expect(refont.changes(placed))
    }
}

@Suite struct EffectiveFontTests {
    let metrics = TerminalMetrics(scale: 1)

    @Test func trustsTheReportedFontWhenCellsAgree() {
        #expect(effectiveFont(of: window(1, 0, 0, 597, 385, font: 11), metrics: metrics) == 11)
    }

    @Test func infersTheRenderedFontWhenCmdZoomHidIt() {
        let zoomed = window(1, 0, 0, 820, 504, columns: 87, rows: 24, font: 11)
        #expect(effectiveFont(of: zoomed, metrics: metrics) == 15)
    }

    @Test func anotherTypefaceIsNotMistakenForZoom() {
        // Menlo's lines are about a point shorter than SF Mono's at the same size.
        let menlo = window(1, 0, 0, 597, 361, font: 11)
        #expect(effectiveFont(of: menlo, metrics: metrics) == 11)
    }

    @Test func aTieGoesToTheSizeClosestToWhatWasReported() {
        // Cells of 9x18.5 sit exactly between 14pt and 15pt.
        let zoomed = window(1, 0, 0, 757, 492, font: 11)
        #expect(effectiveFont(of: zoomed, metrics: metrics) == 14)
    }

    @Test func aWindowWithNoReportedGridKeepsItsReportedFont() {
        let empty = window(1, 0, 0, 100, 100, columns: 0, rows: 0, font: 13)
        #expect(effectiveFont(of: empty, metrics: metrics) == 13)
    }
}

@Suite struct DisplaySelectionTests {
    func display(_ name: String, _ width: Int, _ height: Int, builtIn: Bool = false, scale: Int = 1) -> Display {
        let frame = Rect(x: 0, y: 0, width: width, height: height)
        return Display(name: name, frame: frame, visibleFrame: frame, scale: scale, isBuiltIn: builtIn)
    }

    var all: [Display] {
        [display("Color LCD", 1728, 1117, builtIn: true, scale: 2), display("DELL", 2560, 1440), display("Odyssey G91SD", 5120, 1440)]
    }

    @Test func automaticPrefersTheLargestExternalMonitor() throws {
        #expect(try selectDisplay(all, .automatic).name == "Odyssey G91SD")
    }

    @Test func automaticFallsBackToTheLaptopScreenWhenAlone() throws {
        #expect(try selectDisplay([all[0]], .automatic).name == "Color LCD")
    }

    @Test func canTargetTheBuiltInDisplay() throws {
        #expect(try selectDisplay(all, .builtIn).name == "Color LCD")
    }

    @Test func canTargetByNamePartIgnoringCase() throws {
        #expect(try selectDisplay(all, .name("dell")).name == "DELL")
    }

    @Test func canTargetByOneBasedIndex() throws {
        #expect(try selectDisplay(all, .index(2)).name == "DELL")
    }

    @Test func unknownDisplayErrorListsWhatExists() {
        #expect(throws: TermquiltError.self) { try selectDisplay(all, .name("nope")) }
        #expect(throws: TermquiltError.self) { try selectDisplay(all, .index(9)) }
        #expect(throws: TermquiltError.self) { try selectDisplay([all[1]], .builtIn) }
        #expect(throws: TermquiltError.self) { try selectDisplay([all[0]], .external) }
        #expect(throws: TermquiltError.self) { try selectDisplay([], .automatic) }
    }

    @Test func selectorParsesFriendlyWords() {
        #expect(DisplaySelector(parsing: "laptop") == .builtIn)
        #expect(DisplaySelector(parsing: "external") == .external)
        #expect(DisplaySelector(parsing: "2") == .index(2))
        #expect(DisplaySelector(parsing: "odyssey") == .name("odyssey"))
    }
}

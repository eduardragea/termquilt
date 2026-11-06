import Testing
@testable import TermquiltCore

@Suite struct GeometryTests {
    @Test func clippingKeepsOnlyTheOverlap() {
        let rect = Rect(x: 50, y: 50, width: 100, height: 100)
        let bounds = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(rect.clipped(to: bounds) == Rect(x: 50, y: 50, width: 50, height: 50))
    }

    @Test func clippingReturnsNilWhenRectsDoNotOverlap() {
        let rect = Rect(x: 200, y: 0, width: 10, height: 10)
        #expect(rect.clipped(to: Rect(x: 0, y: 0, width: 100, height: 100)) == nil)
    }

    @Test func touchingRectsDoNotIntersect() {
        let left = Rect(x: 0, y: 0, width: 100, height: 100)
        let right = Rect(x: 100, y: 0, width: 100, height: 100)
        #expect(!left.intersects(right))
    }

    @Test func convertsAppKitCoordinatesOnThePrimaryDisplay() {
        // The Odyssey's real visibleFrame: 30pt menu bar on top, 78pt Dock below.
        let rect = Rect(appKitX: 0, appKitY: 78, width: 5120, height: 1332, primaryHeight: 1440)
        #expect(rect == Rect(x: 0, y: 30, width: 5120, height: 1332))
    }

    @Test func convertsAppKitCoordinatesOnADisplayBelowThePrimary() {
        let rect = Rect(appKitX: 100, appKitY: -1117, width: 1728, height: 1117, primaryHeight: 1440)
        #expect(rect == Rect(x: 100, y: 1440, width: 1728, height: 1117))
    }

    @Test func convertsAppKitCoordinatesOnADisplayAboveThePrimary() {
        let rect = Rect(appKitX: 0, appKitY: 1440, width: 1728, height: 1117, primaryHeight: 1440)
        #expect(rect == Rect(x: 0, y: -1117, width: 1728, height: 1117))
    }

    @Test func convertsAppKitCoordinatesOnADisplayLeftOfThePrimary() {
        let rect = Rect(appKitX: -1728, appKitY: 0, width: 1728, height: 1117, primaryHeight: 1440)
        #expect(rect == Rect(x: -1728, y: 323, width: 1728, height: 1117))
    }

    @Test func fractionalAppKitFramesRoundInwardSoWindowsStayOnScreen() {
        let rect = Rect(appKitX: 0.5, appKitY: 0.5, width: 100, height: 100, primaryHeight: 200)
        #expect(rect == Rect(x: 1, y: 100, width: 99, height: 99))
    }
}

@Suite struct TerminalMetricsTests {
    /// Measured on Terminal.app, SF Mono, 1x display: (font, cell width, cell height).
    static let measured: [(Int, Int, Int)] = [
        (9, 6, 12), (10, 6, 13), (11, 7, 14), (12, 7, 15), (13, 8, 17), (14, 9, 18),
        (15, 9, 19), (16, 10, 20), (17, 11, 22), (18, 11, 23), (19, 12, 24), (20, 12, 25),
        (21, 13, 26), (22, 14, 27), (23, 14, 28), (24, 15, 29),
    ]

    @Test func cellWidthMatchesMeasurementsExactly() {
        let metrics = TerminalMetrics(scale: 1)
        for (font, width, _) in Self.measured {
            #expect(metrics.cellWidth(font: font) == Double(width), "font \(font)")
        }
    }

    @Test func cellHeightIsWithinOnePointOfMeasurements() {
        let metrics = TerminalMetrics(scale: 1)
        for (font, _, height) in Self.measured {
            #expect(abs(metrics.cellHeight(font: font) - Double(height)) <= 1, "font \(font)")
        }
    }

    @Test func gridMatchesWhatTerminalActuallyReported() {
        let metrics = TerminalMetrics(scale: 1)
        #expect(metrics.grid(for: Size(width: 800, height: 600), font: 11) == CharGrid(columns: 109, rows: 39))
        #expect(metrics.grid(for: Size(width: 811, height: 615), font: 16) == CharGrid(columns: 77, rows: 28))
    }

    @Test func gridNeverGoesNegativeForWindowsSmallerThanTheChrome() {
        let grid = TerminalMetrics(scale: 1).grid(for: Size(width: 10, height: 10), font: 11)
        #expect(grid == CharGrid(columns: 0, rows: 0))
    }

    @Test func windowSizeRoundTripsThroughGrid() {
        let metrics = TerminalMetrics(scale: 1)
        let size = metrics.windowSize(for: CharGrid(columns: 80, rows: 24), font: 14)
        #expect(metrics.grid(for: size, font: 14) == CharGrid(columns: 80, rows: 24))
    }

    @Test func retinaDisplaysAllowHalfPointCells() {
        let metrics = TerminalMetrics(scale: 2)
        #expect(metrics.cellWidth(font: 10) == 6)
        #expect(metrics.cellWidth(font: 12) == 7.5)
    }
}

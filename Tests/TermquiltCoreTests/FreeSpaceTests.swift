import Testing
@testable import TermquiltCore

@Suite struct FreeRegionTests {
    let display = Rect(x: 0, y: 30, width: 5120, height: 1332)
    let minimum = Size(width: 300, height: 200)

    @Test func noObstaclesMeansTheWholeDisplay() {
        #expect(freeRegions(in: display, avoiding: [], minimumSize: minimum) == [display])
    }

    @Test func aCentredBrowserLeavesTwoFullHeightBands() {
        // An ultrawide with a browser in the middle, ending above the Dock.
        let browser = Rect(x: 1671, y: 30, width: 1975, height: 1252)
        let regions = freeRegions(in: display, avoiding: [browser], minimumSize: minimum)
        #expect(regions == [
            Rect(x: 0, y: 30, width: 1671, height: 1332),
            Rect(x: 3646, y: 30, width: 1474, height: 1332),
        ])
    }

    @Test func sliversThatNoTerminalCouldUseAreDropped() {
        let almostFull = Rect(x: 100, y: 30, width: 5020, height: 1332)
        #expect(freeRegions(in: display, avoiding: [almostFull], minimumSize: minimum).isEmpty)
    }

    @Test func aHugeThinStripDoesNotStopTheSearchForUsableSpace() {
        // The largest empty rect by area is too short to use; the smaller one must still be found.
        let area = Rect(x: 0, y: 0, width: 4000, height: 1000)
        let obstacle = Rect(x: 0, y: 100, width: 3600, height: 900)
        let regions = freeRegions(in: area, avoiding: [obstacle], minimumSize: Size(width: 300, height: 200))
        #expect(regions == [Rect(x: 3600, y: 0, width: 400, height: 1000)])
    }

    @Test func obstaclesOutsideTheAreaAreIgnored() {
        let offscreen = Rect(x: 9000, y: 0, width: 500, height: 500)
        #expect(freeRegions(in: display, avoiding: [offscreen], minimumSize: minimum) == [display])
    }

    @Test func regionsNeverOverlapEachOtherOrAnyObstacle() {
        let obstacles = [
            Rect(x: 800, y: 200, width: 900, height: 500),
            Rect(x: 3000, y: 700, width: 1200, height: 400),
        ]
        let regions = freeRegions(in: display, avoiding: obstacles, minimumSize: minimum)
        #expect(!regions.isEmpty)
        for (index, region) in regions.enumerated() {
            #expect(!obstacles.contains { $0.intersects(region) })
            #expect(!regions[(index + 1)...].contains { $0.intersects(region) })
        }
    }

    @Test func regionsComeBackInLeftToRightOrder() {
        let browser = Rect(x: 2000, y: 30, width: 1000, height: 1332)
        let regions = freeRegions(in: display, avoiding: [browser], minimumSize: minimum)
        #expect(regions.map(\.x) == regions.map(\.x).sorted())
    }
}

@Suite struct OtherAppWindowTests {
    let display = Rect(x: 0, y: 30, width: 5120, height: 1332)

    func terminal(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> ScreenWindow {
        ScreenWindow(owner: "Terminal", frame: Rect(x: x, y: y, width: width, height: height))
    }

    func app(_ name: String, _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> ScreenWindow {
        ScreenWindow(owner: name, frame: Rect(x: x, y: y, width: width, height: height))
    }

    func others(_ windows: [ScreenWindow]) -> OtherAppWindows {
        otherAppWindows(windowsFrontToBack: windows, display: display, ignoringOwners: ["Terminal"])
    }

    @Test func terminalsThemselvesNeverCount() {
        #expect(others([terminal(0, 30, 2000, 1000)]) == OtherAppWindows())
    }

    @Test func sortsABusyWindowStackIntoGroups() {
        // Front to back: 12 terminals, then a browser, then apps behind it.
        let windows = [
            terminal(914, 544, 829, 487), terminal(3647, 30, 597, 385), terminal(4245, 30, 597, 385),
            terminal(0, 544, 913, 479), terminal(4246, 968, 597, 385), terminal(4245, 416, 873, 553),
            terminal(3648, 802, 597, 399), terminal(919, 34, 820, 504), terminal(0, 35, 917, 508),
            terminal(3647, 416, 597, 385), terminal(920, 1025, 818, 465), terminal(0, 1014, 919, 426),
            app("Browser", 1671, 30, 1975, 1252),
            app("Chat", 2128, 541, 1200, 800),
            app("Assistant", 0, 30, 1280, 820),
            app("Notes", 2110, 424, 900, 530),
            app("Community", 0, 35, 1707, 1004),
            app("Calendar", 354, 714, 935, 598),
            app("Updater", 2307, 606, 506, 224),
            app("Reader", 2048, 164, 1024, 796),
            app("Utility", 2271, 263, 577, 402),
            app("Finder", 433, 527, 920, 464),
        ]
        let result = others(windows)
        #expect(result.visible.map(\.owner) == ["Browser"])
        #expect(result.underTerminals.map(\.owner) == ["Assistant"])
        #expect(result.hidden.map(\.owner) == ["Chat", "Notes", "Community", "Calendar", "Reader", "Finder"])
    }

    @Test func aWindowUnderTheTerminalsStillCounts() {
        // Regression: terminals used to count as hiding things, so whatever they covered lost its space.
        let chat = app("Chat", 0, 30, 1280, 820)
        let result = others([terminal(0, 30, 2000, 1000), chat])
        #expect(result.underTerminals == [chat])
        #expect(result.visible.isEmpty)
        #expect(result.hidden.isEmpty)
    }

    @Test func aWindowHiddenByBothTerminalsAndAnotherAppIsHidden() {
        let chat = app("Chat", 0, 30, 1280, 820)
        let result = others([terminal(0, 30, 2000, 1000), app("Browser", 0, 30, 1300, 900), chat])
        #expect(result.hidden == [chat])
    }

    @Test func aSmallWindowInFrontStillHidesWhatIsBehindIt() {
        // The front window is too small to count, but it covers most of the one behind.
        let result = others([app("Palette", 100, 100, 580, 580), app("Editor", 100, 100, 600, 600)])
        #expect(result.visible.isEmpty)
        #expect(result.hidden.map(\.owner) == ["Editor"])
    }

    @Test func aWindowThatIsOnlyPartlyCoveredStaysInView() {
        let editor = app("Editor", 100, 100, 600, 600)
        let result = others([app("Palette", 100, 100, 300, 300), editor])
        #expect(result.visible == [editor])
    }

    @Test func tinyWindowsDoNotCarveUpTheScreen() {
        #expect(others([app("Mini player", 100, 100, 300, 200)]) == OtherAppWindows())
    }

    @Test func windowsOnAnotherDisplayAreIgnored() {
        #expect(others([app("Browser", 6000, 0, 1500, 1000)]) == OtherAppWindows())
    }

    @Test func aWindowMostlyOnAnotherDisplayStillKeepsThePartShownHere() {
        // Only 40% of this browser is on the display, but all of that part is visible.
        let result = others([app("Browser", 4520, 30, 1500, 1000)])
        #expect(result.visible.map(\.frame) == [Rect(x: 4520, y: 30, width: 600, height: 1000)])
    }

    @Test func terminalsBehindAnotherAppCountAsCovered() {
        let slot = Rect(x: 0, y: 0, width: 500, height: 500)
        let stack = [app("Browser", 100, 100, 800, 800), terminal(0, 0, 500, 500)]
        #expect(anyCovered(frames: [slot], windowsFrontToBack: stack, terminalOwners: ["Terminal"]))
    }

    @Test func terminalsInFrontOfAnotherAppAreNotCovered() {
        let slot = Rect(x: 0, y: 0, width: 500, height: 500)
        let stack = [terminal(0, 0, 500, 500), app("Browser", 100, 100, 800, 800)]
        #expect(!anyCovered(frames: [slot], windowsFrontToBack: stack, terminalOwners: ["Terminal"]))
    }

    @Test func aWindowInFrontThatDoesNotOverlapIsNotCovering() {
        let slot = Rect(x: 0, y: 0, width: 500, height: 500)
        let stack = [app("Browser", 600, 0, 800, 800), terminal(0, 0, 500, 500)]
        #expect(!anyCovered(frames: [slot], windowsFrontToBack: stack, terminalOwners: ["Terminal"]))
    }

    @Test func otherTerminalsNeverCountAsCovering() {
        let slot = Rect(x: 0, y: 0, width: 500, height: 500)
        let stack = [terminal(100, 100, 800, 800), terminal(0, 0, 500, 500)]
        #expect(!anyCovered(frames: [slot], windowsFrontToBack: stack, terminalOwners: ["Terminal"]))
    }

    @Test func terminalsOutsideTheTiledSetAreIgnored() {
        // With --match, an untouched terminal behind a browser is none of our business.
        let slot = Rect(x: 0, y: 0, width: 500, height: 500)
        let stack = [app("Browser", 2000, 0, 800, 800), terminal(2100, 100, 300, 300), terminal(0, 0, 500, 500)]
        #expect(!anyCovered(frames: [slot], windowsFrontToBack: stack, terminalOwners: ["Terminal"]))
    }

    @Test func windowsAreClippedToTheDisplay() {
        let result = others([app("Browser", 4000, 0, 2000, 1000)])
        #expect(result.visible.map(\.frame) == [Rect(x: 4000, y: 30, width: 1120, height: 970)])
    }
}

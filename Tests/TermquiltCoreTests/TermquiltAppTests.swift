import Foundation
import Testing
@testable import TermquiltCore

/// In-memory Terminal that behaves like the real one: placements land exactly, grids follow.
class FakeTerminal: TerminalBackend, @unchecked Sendable {
    var ownerNames: Set<String> { ["Terminal"] }
    var running = true
    var windows: [TerminalWindow]
    var appliedBatches: [[WindowPlacement]] = []
    var failingIDs: Set<Int> = []
    /// Windows that accept the command but end up elsewhere, as if Terminal refused the size.
    var refusingIDs: Set<Int> = []
    var applyError: TermquiltError?
    var session = "session-1"
    var broughtToFrontCount = 0
    /// Like Ghostty: a font can be set, but the app never reports one back.
    var keepsFontUnknown = false
    var sessionIdentifier: String { session }
    let metrics = TerminalMetrics(scale: 1)

    init(_ windows: [TerminalWindow]) { self.windows = windows }

    func isRunning() -> Bool { running }
    func listWindows() throws(TermquiltError) -> [TerminalWindow] { windows }
    func notes() -> [String] { [] }

    func bringToFront() throws(TermquiltError) { broughtToFrontCount += 1 }

    func apply(_ placements: [WindowPlacement]) throws(TermquiltError) -> [Int] {
        if let applyError { throw applyError }
        appliedBatches.append(placements)
        windows = windows.map { current in
            guard let placement = placements.first(where: { $0.windowID == current.id }),
                  !failingIDs.contains(current.id), !refusingIDs.contains(current.id) else { return current }
            guard current.canSetFont, !keepsFontUnknown else {
                return TerminalWindow(
                    id: current.id, title: current.title, frame: placement.frame, grid: current.grid,
                    fontSize: current.fontSize, appName: current.appName, canSetFont: current.canSetFont
                )
            }
            return TerminalWindow(
                id: current.id, title: current.title, frame: placement.frame,
                grid: metrics.grid(for: Size(width: placement.frame.width, height: placement.frame.height), font: placement.fontSize),
                fontSize: placement.fontSize, appName: current.appName, canSetFont: current.canSetFont
            )
        }
        return placements.map(\.windowID).filter(failingIDs.contains)
    }
}

struct FakeDisplays: DisplayProvider {
    let list: [Display]
    func displays() -> [Display] { list }
}

struct FakeScreen: ScreenWindowProvider {
    let list: [ScreenWindow]
    func windowsFrontToBack() -> [ScreenWindow] { list }
}

/// A window stack whose terminals move as they are tiled, with other apps above or below them.
struct StackedScreen: ScreenWindowProvider {
    let terminal: FakeTerminal
    var above: [ScreenWindow] = []
    var below: [ScreenWindow] = []

    func windowsFrontToBack() -> [ScreenWindow] {
        above + terminal.windows.map { ScreenWindow(owner: "Terminal", frame: $0.frame) } + below
    }
}

/// Retitles windows after a resize, the way Terminal's default "name — 80×24" title does.
final class TitleChangingTerminal: FakeTerminal, @unchecked Sendable {
    override func apply(_ placements: [WindowPlacement]) throws(TermquiltError) -> [Int] {
        let failed = try super.apply(placements)
        windows = windows.map { current in
            TerminalWindow(id: current.id, title: "agent resized", frame: current.frame, grid: current.grid, fontSize: current.fontSize)
        }
        return failed
    }
}

@Suite struct TermquiltAppTests {
    let odyssey = Display(
        name: "Odyssey", frame: Rect(x: 0, y: 0, width: 5120, height: 1440),
        visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1332), scale: 1, isBuiltIn: false
    )

    let laptop = Display(
        name: "Laptop", frame: Rect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: Rect(x: 0, y: 25, width: 1728, height: 1040), scale: 2, isBuiltIn: true
    )
    let maximisedBrowser = ScreenWindow(owner: "Browser", frame: Rect(x: 0, y: 25, width: 1300, height: 1040))
    let centredBrowser = ScreenWindow(owner: "Browser", frame: Rect(x: 1671, y: 30, width: 1975, height: 1252))

    func makeApp(
        _ terminal: FakeTerminal,
        screen: [ScreenWindow] = [],
        stack: StackedScreen? = nil,
        displays: [Display]? = nil
    ) -> TermquiltApp {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termquilt-\(UUID().uuidString)")
        return TermquiltApp(
            terminal: terminal,
            displays: FakeDisplays(list: displays ?? [odyssey]),
            screen: stack ?? FakeScreen(list: screen),
            store: Store(directory: directory),
            settle: {}
        )
    }

    func messy(_ count: Int) -> [TerminalWindow] {
        (1...count).map { window($0, $0 * 37, $0 * 41) }
    }

    @Test func tilesEveryWindowAndReportsTheResult() throws {
        let terminal = FakeTerminal(messy(12))
        let lines = try makeApp(terminal).tile(TileOptions())
        #expect(terminal.windows.allSatisfy { $0.fontSize == 16 })
        expectExactFill(terminal.windows.map(\.frame), of: [odyssey.visibleFrame])
        #expect(lines.joined(separator: "\n").contains("12 terminals"))
        #expect(lines.joined(separator: "\n").contains("16 pt"))
    }

    @Test func reTilingChangesNothing() throws {
        let terminal = FakeTerminal(messy(5))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions())
        let lines = try app.tile(TileOptions())
        #expect(terminal.appliedBatches.count == 1)
        #expect(lines.joined().lowercased().contains("already"))
    }

    @Test func aDryRunTouchesNothing() throws {
        let terminal = FakeTerminal(messy(3))
        let before = terminal.windows
        let app = makeApp(terminal)
        let lines = try app.tile(TileOptions(font: .fixed(20), dryRun: true))
        #expect(terminal.windows == before)
        #expect(terminal.appliedBatches.isEmpty)
        #expect(try app.store.loadSnapshot() == nil)
        #expect(try app.store.loadPreferences().font(for: "Odyssey") == nil)
        #expect(lines.joined().lowercased().contains("dry run"))
    }

    @Test func aVisibleBrowserKeepsItsSpace() throws {
        let browser = Rect(x: 1671, y: 30, width: 1975, height: 1252)
        let terminal = FakeTerminal(messy(4))
        let screen = [ScreenWindow(owner: "Browser", frame: browser)]
        _ = try makeApp(terminal, screen: screen).tile(TileOptions())
        #expect(!terminal.windows.contains { $0.frame.intersects(browser) })
    }

    @Test func anAppBehindTheTerminalsStillKeepsItsSpace() throws {
        // Regression: terminals used to count as hiding things, so whatever they covered lost its space.
        let chat = ScreenWindow(owner: "Chat", frame: Rect(x: 0, y: 30, width: 1280, height: 820))
        let terminal = FakeTerminal(messy(4))
        let stack = StackedScreen(terminal: terminal, below: [chat])
        let lines = try makeApp(terminal, stack: stack).tile(TileOptions())
        #expect(!terminal.windows.contains { $0.frame.intersects(chat.frame) })
        #expect(lines.contains("Keeping clear of: Chat"))
    }

    @Test func reTilingAroundAnAppChangesNothing() throws {
        // Moving the terminals off an app must not change whether that app counts.
        let chat = ScreenWindow(owner: "Chat", frame: Rect(x: 0, y: 30, width: 1280, height: 820))
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal, stack: StackedScreen(terminal: terminal, below: [chat]))
        _ = try app.tile(TileOptions())
        let lines = try app.tile(TileOptions())
        #expect(terminal.appliedBatches.count == 1)
        #expect(lines.contains("Already tidy."))
    }

    @Test func reTilingWithAppsAboveAndBelowChangesNothing() throws {
        let chat = ScreenWindow(owner: "Chat", frame: Rect(x: 0, y: 30, width: 1280, height: 820))
        let terminal = FakeTerminal(messy(12))
        let app = makeApp(terminal, stack: StackedScreen(terminal: terminal, above: [centredBrowser], below: [chat]))
        _ = try app.tile(TileOptions())
        let lines = try app.tile(TileOptions())
        #expect(terminal.appliedBatches.count == 1)
        #expect(lines.contains("Already tidy."))
    }

    @Test func aSecondPressMovesNothingEvenIfAnAppWasOnlyPartlyCovered() throws {
        // Regression: an app the first tile only partly covered looked visible to the second,
        // which then made room for it, so the same hotkey moved every terminal twice.
        let apps = [
            ScreenWindow(owner: "A0", frame: Rect(x: 2804, y: 572, width: 1822, height: 649)),
            ScreenWindow(owner: "A1", frame: Rect(x: 1171, y: 420, width: 2295, height: 770)),
            ScreenWindow(owner: "A2", frame: Rect(x: 29, y: 30, width: 2330, height: 1032)),
            ScreenWindow(owner: "A3", frame: Rect(x: 575, y: 104, width: 927, height: 985)),
        ]
        let terminal = FakeTerminal([
            window(1, 1315, 638, 670, 602), window(2, 4134, 326, 924, 505), window(3, 2892, 279, 1024, 472),
            window(4, 4311, 161, 620, 300), window(5, 1050, 305, 764, 592), window(6, 222, 545, 1104, 345),
            window(7, 4083, 90, 591, 562), window(8, 1153, 403, 976, 642), window(9, 3167, 420, 506, 382),
            window(10, 2618, 205, 935, 386),
        ])
        let app = makeApp(terminal, stack: StackedScreen(terminal: terminal, below: apps))
        _ = try app.tile(TileOptions())
        let lines = try app.tile(TileOptions())
        #expect(terminal.appliedBatches.count == 1)
        #expect(lines.contains("Already tidy."))
    }

    @Test(arguments: [FontOption.saved, .fixed(14)])
    func goingBackToAroundUncoversABrowserTheTerminalsBuried(font: FontOption) throws {
        // After a full-screen tile the browser sits under the terminals, and must still get its space back.
        let terminal = FakeTerminal(messy(12))
        let app = makeApp(terminal, stack: StackedScreen(terminal: terminal, below: [centredBrowser]))
        _ = try app.tile(TileOptions(layout: .full))
        expectExactFill(terminal.windows.map(\.frame), of: [odyssey.visibleFrame])

        _ = try app.tile(TileOptions(font: font, layout: .around))
        #expect(!terminal.windows.contains { $0.frame.intersects(centredBrowser.frame) })
    }

    @Test func fullIgnoresOtherWindows() throws {
        let browser = Rect(x: 1671, y: 30, width: 1975, height: 1252)
        let terminal = FakeTerminal(messy(4))
        let screen = [ScreenWindow(owner: "Browser", frame: browser)]
        _ = try makeApp(terminal, screen: screen).tile(TileOptions(layout: .full))
        expectExactFill(terminal.windows.map(\.frame), of: [odyssey.visibleFrame])
    }

    @Test func tooLittleFreeSpaceFallsBackToTheWholeDisplayAndSaysSo() throws {
        let terminal = FakeTerminal(messy(6))
        let lines = try makeApp(terminal, screen: [maximisedBrowser], displays: [laptop]).tile(TileOptions())
        expectExactFill(terminal.windows.map(\.frame), of: [laptop.visibleFrame])
        #expect(lines.contains("Not enough room to keep clear of: Browser"))
    }

    @Test func aChosenLayoutIsRememberedPerDisplay() throws {
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal, screen: [centredBrowser], displays: [odyssey, laptop])
        _ = try app.tile(TileOptions(layout: .full))
        #expect(try app.store.loadPreferences().layout(for: "Odyssey") == .full)
        #expect(try app.store.loadPreferences().layout(for: "Laptop") == .around)

        _ = try app.tile(TileOptions())
        expectExactFill(terminal.windows.map(\.frame), of: [odyssey.visibleFrame])
    }

    @Test func aroundSwitchesBackFromFull() throws {
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal, screen: [centredBrowser])
        _ = try app.tile(TileOptions(layout: .full))
        _ = try app.tile(TileOptions(layout: .around))
        #expect(!terminal.windows.contains { $0.frame.intersects(centredBrowser.frame) })
        _ = try app.tile(TileOptions())
        #expect(!terminal.windows.contains { $0.frame.intersects(centredBrowser.frame) })
    }

    @Test func biggerAndSmallerKeepTheSavedLayout() throws {
        // The hotkeys pass no flags, so they must follow the setting.
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal, screen: [centredBrowser])
        _ = try app.tile(TileOptions(layout: .full))
        _ = try app.adjustFont(by: -1, TileOptions())
        expectExactFill(terminal.windows.map(\.frame), of: [odyssey.visibleFrame])
    }

    @Test func toggleSwitchesBothWaysAndRemembers() throws {
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal, screen: [centredBrowser])
        _ = try app.tile(TileOptions())

        _ = try app.toggleLayout(TileOptions())
        #expect(try app.store.loadPreferences().layout(for: "Odyssey") == .full)
        expectExactFill(terminal.windows.map(\.frame), of: [odyssey.visibleFrame])

        _ = try app.toggleLayout(TileOptions())
        #expect(try app.store.loadPreferences().layout(for: "Odyssey") == .around)
        #expect(!terminal.windows.contains { $0.frame.intersects(centredBrowser.frame) })
    }

    @Test func undoAlsoRevertsTheChosenLayout() throws {
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal, screen: [centredBrowser])
        _ = try app.tile(TileOptions())
        _ = try app.tile(TileOptions(layout: .full))
        _ = try app.undo()
        #expect(try app.store.loadPreferences().layout(for: "Odyssey") == .around)
        #expect(!terminal.windows.contains { $0.frame.intersects(centredBrowser.frame) })
    }

    @Test func aDryRunDoesNotSaveTheLayout() throws {
        let app = makeApp(FakeTerminal(messy(4)), screen: [centredBrowser])
        let lines = try app.tile(TileOptions(layout: .full, dryRun: true))
        #expect(try app.store.loadPreferences().layout(for: "Odyssey") == .around)
        #expect(lines.joined().contains("Dry run"))
    }

    @Test func aChosenFontIsRememberedPerDisplay() throws {
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions(font: .fixed(13)))
        #expect(try app.store.loadPreferences().font(for: "Odyssey") == 13)
        _ = try app.tile(TileOptions())
        #expect(terminal.windows.allSatisfy { $0.fontSize == 13 })
    }

    @Test func autoForgetsTheRememberedFont() throws {
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions(font: .fixed(13)))
        _ = try app.tile(TileOptions(font: .automatic))
        #expect(try app.store.loadPreferences().font(for: "Odyssey") == nil)
        #expect(terminal.windows.allSatisfy { $0.fontSize == FontLimits.autoMaximum })
    }

    @Test func biggerAndSmallerMoveOnePointFromWhatIsOnScreen() throws {
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions(font: .fixed(13)))
        _ = try app.adjustFont(by: 1, TileOptions())
        #expect(terminal.windows.allSatisfy { $0.fontSize == 14 })
        _ = try app.adjustFont(by: -2, TileOptions())
        #expect(terminal.windows.allSatisfy { $0.fontSize == 12 })
        #expect(try app.store.loadPreferences().font(for: "Odyssey") == 12)
    }

    @Test func biggerWithNoSavedFontStartsFromTheMostCommonFontOnScreen() throws {
        let terminal = FakeTerminal([window(1, 0, 0, font: 13), window(2, 10, 0, font: 13), window(3, 20, 0, font: 11)])
        _ = try makeApp(terminal).adjustFont(by: 1, TileOptions())
        #expect(terminal.windows.allSatisfy { $0.fontSize == 14 })
    }

    @Test func fontAdjustmentStopsAtTheLimits() throws {
        let terminal = FakeTerminal(messy(1))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions(font: .fixed(FontLimits.maximum - 1)))
        _ = try app.adjustFont(by: 1, TileOptions())
        #expect(terminal.windows[0].fontSize == FontLimits.maximum)
        _ = try app.adjustFont(by: 1, TileOptions())
        #expect(terminal.windows[0].fontSize == FontLimits.maximum)

        _ = try app.tile(TileOptions(font: .fixed(FontLimits.minimum + 1)))
        _ = try app.adjustFont(by: -1, TileOptions())
        #expect(terminal.windows[0].fontSize == FontLimits.minimum)
        _ = try app.adjustFont(by: -1, TileOptions())
        #expect(terminal.windows[0].fontSize == FontLimits.minimum)
    }

    @Test func undoRestoresTheOriginalLayoutAndFonts() throws {
        let original = messy(4)
        let terminal = FakeTerminal(original)
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions())
        _ = try app.undo()
        #expect(terminal.windows.map(\.frame) == original.map(\.frame))
        #expect(terminal.windows.map(\.fontSize) == original.map(\.fontSize))
    }

    @Test func undoRestoresTheRealFontOfACmdZoomedWindow() throws {
        // Reports 11pt, but 820x504 at 87x24 means cells of 9x19, which is 15pt.
        let zoomed = window(1, 919, 34, 820, 504, columns: 87, rows: 24, font: 11)
        let terminal = FakeTerminal([zoomed])
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions())
        _ = try app.undo()
        #expect(terminal.windows[0].frame == zoomed.frame)
        #expect(terminal.windows[0].fontSize == 15)
    }

    @Test func undoNeverTouchesWindowsOutsideTheOriginalTile() throws {
        // Regression: undo once saved every window as its redo point, so undoing twice
        // rewrote the font of Cmd-zoomed windows that were never part of the tile.
        let bystander = window(2, 50, 50, 820, 504, columns: 87, rows: 24, font: 11, title: "plain shell")
        let terminal = FakeTerminal([window(1, 0, 0, title: "agent"), bystander])
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions(match: "agent"))
        _ = try app.undo()
        _ = try app.undo()
        #expect(terminal.windows[1] == bystander)
        #expect(!terminal.appliedBatches.joined().contains { $0.windowID == 2 })
    }

    @Test func undoWhenEverythingAlreadyMatchesAppliesNothing() throws {
        let original = messy(2)
        let terminal = FakeTerminal(original)
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions())
        _ = try app.undo()
        let states = original.map { WindowState(id: $0.id, frame: $0.frame, fontSize: $0.fontSize) }
        try app.store.save(Snapshot(windows: states, terminalSession: terminal.session, preferences: Preferences()))
        let batchesBefore = terminal.appliedBatches.count
        let lines = try app.undo()
        #expect(terminal.appliedBatches.count == batchesBefore)
        #expect(lines.joined().contains("Nothing to undo"))
    }

    @Test func undoTwiceRedoes() throws {
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions())
        let tiled = terminal.windows
        _ = try app.undo()
        #expect(terminal.windows != tiled)
        _ = try app.undo()
        #expect(terminal.windows.map(\.frame) == tiled.map(\.frame))
        #expect(terminal.windows.map(\.fontSize) == tiled.map(\.fontSize))
    }

    @Test func undoSkipsWindowsThatHaveSinceClosed() throws {
        let terminal = FakeTerminal(messy(3))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions())
        terminal.windows.removeLast()
        _ = try app.undo()
        #expect(terminal.appliedBatches.last?.count == 2)
    }

    @Test func undoWithNothingSavedSaysSo() throws {
        let lines = try makeApp(FakeTerminal(messy(1))).undo()
        #expect(lines.joined().lowercased().contains("nothing to undo"))
    }

    @Test func aReTileWithNoChangesKeepsTheOriginalUndoPoint() throws {
        let original = messy(3)
        let terminal = FakeTerminal(original)
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions())
        _ = try app.tile(TileOptions())
        _ = try app.undo()
        #expect(terminal.windows.map(\.frame) == original.map(\.frame))
    }

    @Test func matchLimitsWhichWindowsAreTouched() throws {
        let terminal = FakeTerminal([
            window(1, 0, 0, title: "claude agent"),
            window(2, 50, 50, title: "plain shell"),
        ])
        let untouched = terminal.windows[1]
        _ = try makeApp(terminal).tile(TileOptions(match: "CLAUDE"))
        #expect(terminal.windows[1] == untouched)
        #expect(terminal.windows[0].frame == odyssey.visibleFrame)
    }

    @Test func noWindowsIsAFriendlyMessage() throws {
        let lines = try makeApp(FakeTerminal([])).tile(TileOptions())
        #expect(lines.joined().contains("No terminal windows"))
    }

    @Test func terminalNotRunningIsAClearError() {
        let terminal = FakeTerminal([])
        terminal.running = false
        #expect(throws: TermquiltError.terminalNotRunning) { try makeApp(terminal).tile(TileOptions()) }
    }

    @Test func windowsThatFailToApplyAreReported() throws {
        let terminal = FakeTerminal(messy(3))
        terminal.failingIDs = [2]
        let lines = try makeApp(terminal).tile(TileOptions())
        #expect(lines.contains("1 window couldn't be changed (closed in the meantime?)."))
    }

    @Test func goingBelowTheReadableMinimumIsMentioned() throws {
        let terminal = FakeTerminal(messy(12))
        let lines = try makeApp(terminal).tile(TileOptions(font: .fixed(30)))
        #expect(lines.joined().contains("below"))
    }

    @Test func terminalsTiledBehindAnotherAppComeToTheFront() throws {
        let terminal = FakeTerminal(messy(6))
        let stack = StackedScreen(terminal: terminal, above: [maximisedBrowser])
        let lines = try makeApp(terminal, stack: stack, displays: [laptop]).tile(TileOptions())
        #expect(terminal.broughtToFrontCount == 1)
        #expect(lines.joined().contains("to the front"))
    }

    @Test func aBuriedAppThatEndsUpOverATerminalAlsoRaisesThem() throws {
        // Real stack: an app sitting between terminals, hidden until they move out of the way.
        let terminal = FakeTerminal(messy(4))
        let buried = ScreenWindow(owner: "Chat", frame: Rect(x: 100, y: 100, width: 300, height: 200))
        let stack = StackedScreen(terminal: terminal, above: [buried])
        _ = try makeApp(terminal, stack: stack).tile(TileOptions())
        #expect(terminal.broughtToFrontCount == 1)
    }

    @Test func tilingAroundAVisibleWindowDoesNotStealFocus() throws {
        let terminal = FakeTerminal(messy(4))
        let stack = StackedScreen(terminal: terminal, above: [centredBrowser])
        _ = try makeApp(terminal, stack: stack).tile(TileOptions())
        #expect(terminal.broughtToFrontCount == 0)
    }

    @Test func terminalsAlreadyOnTopAreNotRaised() throws {
        let terminal = FakeTerminal(messy(6))
        let stack = StackedScreen(terminal: terminal, below: [maximisedBrowser])
        _ = try makeApp(terminal, stack: stack, displays: [laptop]).tile(TileOptions())
        #expect(terminal.broughtToFrontCount == 0)
    }

    @Test func aTidyLayoutThatIsCoveredStillComesToTheFront() throws {
        let terminal = FakeTerminal(messy(4))
        let stack = StackedScreen(terminal: terminal, above: [maximisedBrowser])
        let app = makeApp(terminal, stack: stack, displays: [laptop])
        _ = try app.tile(TileOptions(layout: .full))
        let lines = try app.tile(TileOptions(layout: .full))
        #expect(lines.joined().contains("Already tidy"))
        #expect(terminal.broughtToFrontCount == 2)
    }

    @Test func aDryRunNeverRaisesAnything() throws {
        let terminal = FakeTerminal(messy(6))
        let stack = StackedScreen(terminal: terminal, above: [maximisedBrowser])
        _ = try makeApp(terminal, stack: stack, displays: [laptop]).tile(TileOptions(dryRun: true))
        #expect(terminal.broughtToFrontCount == 0)
    }

    @Test func undoAlsoRevertsTheRememberedFont() throws {
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions(font: .fixed(13)))
        _ = try app.adjustFont(by: 1, TileOptions())
        #expect(try app.store.loadPreferences().font(for: "Odyssey") == 14)

        _ = try app.undo()
        #expect(try app.store.loadPreferences().font(for: "Odyssey") == 13)

        _ = try app.undo()
        #expect(try app.store.loadPreferences().font(for: "Odyssey") == 14)
    }

    @Test func undoAfterTheFirstEverFontChoiceForgetsIt() throws {
        let terminal = FakeTerminal(messy(4))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions(font: .fixed(13)))
        _ = try app.undo()
        #expect(try app.store.loadPreferences().font(for: "Odyssey") == nil)
    }

    @Test func aFailedUndoKeepsTheUndoPoint() throws {
        let original = messy(3)
        let terminal = FakeTerminal(original)
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions())

        terminal.applyError = .appleScriptFailed(code: -1712, message: "timed out")
        #expect(throws: TermquiltError.self) { try app.undo() }

        terminal.applyError = nil
        _ = try app.undo()
        #expect(terminal.windows.map(\.frame) == original.map(\.frame))
    }

    @Test func undoRefusesASnapshotFromBeforeTerminalRestarted() throws {
        // Window IDs can be reused after a relaunch, so old frames could land on unrelated windows.
        let terminal = FakeTerminal(messy(3))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions())
        let batchesBefore = terminal.appliedBatches.count

        terminal.session = "session-2"
        let lines = try app.undo()
        #expect(terminal.appliedBatches.count == batchesBefore)
        #expect(lines.joined().contains("restarted"))
    }

    @Test func windowsThatRefuseTheirSizeAreReported() throws {
        let terminal = FakeTerminal(messy(3))
        terminal.refusingIDs = [1, 2]
        let lines = try makeApp(terminal).tile(TileOptions())
        #expect(lines.contains("2 windows didn't take the requested size."))
    }

    @Test func theResultIsReadBackEvenIfTheTitleStopsMatching() throws {
        // Terminal's default title includes the grid size, which changes when a window is resized.
        let terminal = TitleChangingTerminal([window(1, 0, 0, title: "agent 80×24")])
        let lines = try makeApp(terminal).tile(TileOptions(match: "80×24"))
        #expect(lines[0].contains("1 terminal"))
        #expect(!lines[0].contains("each 0×0"))
    }

    @Test func statusShowsWhichWindowsAreBeingAvoided() throws {
        let lines = try makeApp(FakeTerminal(messy(1)), screen: [centredBrowser]).status()
        #expect(lines.contains("Keeping clear of Browser: 1975×1252 at 1671,30"))
    }

    @Test func statusShowsWhichWindowsThereIsNoRoomFor() throws {
        let lines = try makeApp(FakeTerminal(messy(6)), screen: [maximisedBrowser], displays: [laptop]).status()
        #expect(lines.contains("No room to keep clear of Browser: 1300×1040 at 0,25"))
    }

    @Test func statusShowsTheSavedSettingsForEachDisplay() throws {
        let app = makeApp(FakeTerminal(messy(1)), displays: [odyssey, laptop])
        _ = try app.tile(TileOptions(font: .fixed(14), layout: .full))
        let lines = try app.status()
        #expect(lines.contains { $0.hasPrefix("Display 1: Odyssey") && $0.hasSuffix("layout: full screen, font: 14 pt") })
        #expect(lines.contains { $0.hasPrefix("Display 2: Laptop") && $0.hasSuffix("layout: around other apps, font: auto") })
    }

    @Test func statusStillShowsSavedSettingsWhenTerminalIsClosed() throws {
        let terminal = FakeTerminal([])
        terminal.running = false
        let lines = try makeApp(terminal).status()
        #expect(lines.contains { $0.hasSuffix("layout: around other apps, font: auto") })
        #expect(lines.contains("No supported terminal is running."))
    }

    @Test func statusPlansForTheWindowsAndDisplayItWasAskedAbout() throws {
        // Twelve terminals don't fit beside this window on the laptop, but one does.
        let side = ScreenWindow(owner: "Side", frame: Rect(x: 0, y: 25, width: 1000, height: 1040))
        let terminal = FakeTerminal(messy(11) + [window(99, 0, 0, title: "only me")])
        let app = makeApp(terminal, screen: [side], displays: [odyssey, laptop])

        let all = try app.status(TileOptions(display: .builtIn))
        #expect(all.contains("No room to keep clear of Side: 1000×1040 at 0,25"))
        let one = try app.status(TileOptions(display: .builtIn, match: "only me"))
        #expect(one.contains("Keeping clear of Side: 1000×1040 at 0,25"))
        #expect(one.filter { $0.hasPrefix("  ") }.count == 1)
    }

    @Test func statusListsDisplaysAndWindows() throws {
        let terminal = FakeTerminal([window(1, 0, 0, title: "project\u{1B}[31m agent")])
        let lines = try makeApp(terminal).status()
        let text = lines.joined(separator: "\n")
        #expect(text.contains("Odyssey"))
        #expect(text.contains("project"))
        #expect(!text.contains("\u{1B}"), "control characters from titles must not reach the terminal")
    }
}

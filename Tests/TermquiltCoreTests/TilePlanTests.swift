import Testing
@testable import TermquiltCore

/// Deciding which apps keep their space, on a busy ultrawide with a dozen terminals.
@Suite struct TilePlanTests {
    let odyssey = Display(
        name: "Odyssey", frame: Rect(x: 0, y: 0, width: 5120, height: 1440),
        visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1332), scale: 1, isBuiltIn: false
    )
    let metrics = TerminalMetrics(scale: 1)

    func app(_ name: String, _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> ScreenWindow {
        ScreenWindow(owner: name, frame: Rect(x: x, y: y, width: width, height: height))
    }

    func terminal(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> ScreenWindow {
        app("Terminal", x, y, width, height)
    }

    /// Front to back, the order `CGWindowListCopyWindowInfo` reports them in.
    var busyDesktop: [ScreenWindow] {
        [
            app("Player", 2070, 219, 980, 600),
            terminal(4245, 30, 597, 385), terminal(3648, 802, 597, 399), terminal(4246, 968, 597, 385),
            terminal(3647, 30, 597, 385), terminal(4245, 416, 873, 553), terminal(3647, 416, 597, 385),
            app("Browser", 1671, 30, 1975, 1252),
            terminal(0, 1014, 919, 426), terminal(0, 544, 913, 479), terminal(914, 544, 829, 487),
            terminal(919, 34, 820, 504), terminal(0, 35, 917, 508),
            app("Audio", 1880, 266, 1360, 860),
            app("Messenger", 2128, 541, 1200, 800),
            app("Assistant", 2040, 277, 1040, 760),
            terminal(920, 1025, 818, 465),
            app("Chatbot", 0, 30, 1280, 820),
            app("Notes", 2110, 424, 900, 530),
            app("Community", 0, 35, 1707, 1004),
            app("Calendar", 354, 714, 935, 598),
            app("Updater", 2307, 606, 506, 224),
            app("Reader", 2048, 164, 1024, 796),
            app("Utility", 2271, 263, 577, 402),
            app("Finder", 433, 527, 920, 464),
        ]
    }

    /// The left half of the ultrawide, covered by terminals so that what's behind isn't visible.
    var terminalsOnTheLeft: ScreenWindow { terminal(0, 30, 1671, 1332) }
    var browser: ScreenWindow { app("Browser", 1671, 30, 1975, 1252) }
    var chatbot: ScreenWindow { app("Chatbot", 0, 30, 1280, 820) }

    func plan(
        terminals: Int,
        _ windows: [ScreenWindow],
        mode: LayoutMode = .around,
        font: FontChoice = .automatic
    ) -> TilePlan {
        makeTilePlan(
            windowCount: terminals,
            display: odyssey,
            mode: mode,
            otherApps: otherAppWindows(windowsFrontToBack: windows, display: odyssey.visibleFrame, ignoringOwners: ["Terminal"]),
            font: font,
            metrics: metrics
        )
    }

    /// Compares the terminals with the apps' real frames, rather than with the plan's own `keptClear`,
    /// which is derived from those same terminals and so couldn't disagree.
    func expectNoTerminalOver(
        _ names: [String],
        in windows: [ScreenWindow],
        _ plan: TilePlan,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let frames = windows.filter { names.contains($0.owner) }.map(\.frame)
        #expect(frames.count >= names.count, sourceLocation: sourceLocation)
        #expect(!plan.layout.cells.isEmpty, sourceLocation: sourceLocation)
        for cell in plan.layout.cells {
            #expect(!frames.contains { $0.intersects(cell) }, "\(cell)", sourceLocation: sourceLocation)
        }
    }

    func grids(_ plan: TilePlan) -> [CharGrid] {
        plan.layout.cells.map { metrics.grid(for: $0.size, font: plan.layout.fontSize) }
    }

    @Test func twelveTerminalsKeepTheCentreAndNameWhatDidNotFit() {
        let result = plan(terminals: 12, busyDesktop)
        #expect(result.layout.fontSize == 13)
        #expect(result.layout.meetsMinimum)
        #expect(result.layout.cells.count == 12)
        expectNoTerminalOver(["Player", "Browser", "Audio", "Assistant", "Notes", "Reader"], in: busyDesktop, result)
        #expect(result.keptClear.map(\.owner) == ["Player", "Browser", "Audio", "Messenger", "Assistant", "Notes", "Reader"])
        #expect(result.covered.map(\.owner) == ["Chatbot", "Community", "Calendar", "Finder"])
    }

    @Test func sixTerminalsHaveRoomToAvoidEveryApp() {
        let result = plan(terminals: 6, busyDesktop)
        #expect(result.covered.isEmpty)
        #expect(result.layout.meetsMinimum)
        #expect(result.layout.cells.count == 6)
        expectNoTerminalOver(["Browser", "Chatbot", "Community", "Calendar", "Finder"], in: busyDesktop, result)
    }

    @Test func seventeenTerminalsStillGoAroundTheAppYouCanSee() {
        // Regression: this covered the browser in front of you while keeping clear of a buried app.
        let result = plan(terminals: 17, busyDesktop)
        #expect(result.layout.fontSize == FontLimits.autoMinimum)
        #expect(result.layout.cells.count == 17)
        expectNoTerminalOver(["Browser", "Player"], in: busyDesktop, result)
        #expect(result.covered.map(\.owner).contains("Chatbot"))
        #expect(grids(result).allSatisfy { $0.columns >= CharGrid.usable.columns && $0.rows >= CharGrid.usable.rows })
        #expect(result.notes.contains("Some terminals are under 80×20 so they can stay clear of other apps."))
    }

    @Test func aVisibleAppIsWorthCrampedTerminals() {
        let windows = [browser, chatbot]
        let result = plan(terminals: 12, windows)
        expectNoTerminalOver(["Browser", "Chatbot"], in: windows, result)
        #expect(result.layout.fontSize == FontLimits.autoMinimum)
        #expect(result.covered.isEmpty)
    }

    @Test func anAppUnderTheTerminalsIsNotWorthCrampingThem() {
        let windows = [browser, terminalsOnTheLeft, chatbot]
        let result = plan(terminals: 12, windows)
        expectNoTerminalOver(["Browser"], in: windows, result)
        #expect(result.layout.fontSize == 13)
        #expect(result.covered.map(\.owner) == ["Chatbot"])
        #expect(!result.notes.joined().contains("Some terminals are under"))
    }

    @Test func anAppUnderTheTerminalsIsWorthSomeTextSize() {
        let alone = plan(terminals: 6, [browser])
        let windows = [browser, terminalsOnTheLeft, chatbot]
        let withChat = plan(terminals: 6, windows)
        #expect(withChat.layout.fontSize < alone.layout.fontSize)
        #expect(withChat.layout.meetsMinimum)
        #expect(!withChat.notes.joined().contains("Some terminals are under"))
        expectNoTerminalOver(["Browser", "Chatbot"], in: windows, withChat)
    }

    @Test func aHiddenAppNeverCostsTextSize() {
        // Calendar alone would fit at 11 pt, but it sits behind other apps, so 13 pt wins.
        let windows = [browser, terminalsOnTheLeft, app("Community", 0, 35, 1707, 1004), app("Calendar", 354, 714, 935, 598)]
        let result = plan(terminals: 12, windows)
        #expect(result.layout.fontSize == 13)
        #expect(result.covered.map(\.owner).contains("Calendar"))
    }

    @Test func aHiddenAppWithRoomToSpareKeepsItsSpace() {
        let windows = [app("Browser", 0, 30, 2000, 1000), app("Chat", 0, 30, 2100, 1100)]
        let result = plan(terminals: 2, windows)
        #expect(result.covered.isEmpty)
        expectNoTerminalOver(["Browser", "Chat"], in: windows, result)
    }

    @Test func theFrontAppWinsWhenThereIsRoomForOnlyOne() {
        let windows = [app("Front", 0, 30, 2400, 1000), app("Back", 2720, 30, 2400, 1000)]
        let result = plan(terminals: 12, windows)
        expectNoTerminalOver(["Front"], in: windows, result)
        #expect(result.keptClear.map(\.owner) == ["Front"])
        #expect(result.covered.map(\.owner) == ["Back"])
    }

    @Test func anAppThatCannotFitDoesNotStopSmallerOnesBehindIt() {
        let windows = [app("Maximised", 0, 30, 5120, 1332), app("Side", 4000, 900, 800, 460)]
        let result = plan(terminals: 4, windows)
        expectNoTerminalOver(["Side"], in: windows, result)
        #expect(result.covered.map(\.owner) == ["Maximised"])
    }

    @Test(arguments: 11...18)
    func choosingATextSizeKeepsTheSameAppsClear(size: Int) {
        // Regression: pressing bigger once used to throw the terminals over the browser,
        // and pressing smaller gave the room to a buried app instead of to the terminals.
        let inView = ["Player", "Browser", "Chatbot"]
        let automatic = plan(terminals: 12, busyDesktop)
        let result = plan(terminals: 12, busyDesktop, font: .fixed(size))
        #expect(result.layout.fontSize == size)
        #expect(result.layout.cells.count == 12)
        expectNoTerminalOver(["Player", "Browser"], in: busyDesktop, result)
        #expect(result.keptClear.filter { inView.contains($0.owner) } == automatic.keptClear.filter { inView.contains($0.owner) })
    }

    @Test func aBiggerChosenFontSaysWhenTerminalsGetCramped() {
        #expect(plan(terminals: 12, busyDesktop, font: .fixed(14)).notes.contains("Some terminals are under 80×20 so they can stay clear of other apps."))
        #expect(!plan(terminals: 12, busyDesktop, font: .fixed(13)).notes.joined().contains("Some terminals are under"))
    }

    @Test func aSmallerChosenFontGivesTheRoomToTheTerminals() {
        let narrowest = { (plan: TilePlan) in plan.layout.cells.map(\.width).min() ?? 0 }
        let at13 = plan(terminals: 12, busyDesktop, font: .fixed(13))
        let at12 = plan(terminals: 12, busyDesktop, font: .fixed(12))
        #expect(narrowest(at12) >= narrowest(at13))
        #expect(at12.keptClear == at13.keptClear)
    }

    @Test func aChosenFontTooBigForTheSpaceCoversTheAppAndSaysSo() {
        let result = plan(terminals: 12, [browser], font: .fixed(24))
        #expect(result.covered.map(\.owner) == ["Browser"])
        #expect(result.notes.contains("Not enough room to keep clear of: Browser"))
        expectExactFill(result.layout.cells, of: [odyssey.visibleFrame])
    }

    @Test func aChosenFontDoesNotAddAppsTheAutomaticLayoutHadNoRoomFor() {
        let windows = [browser, terminalsOnTheLeft, chatbot]
        let result = plan(terminals: 12, windows, font: .fixed(12))
        expectNoTerminalOver(["Browser"], in: windows, result)
        #expect(result.covered.map(\.owner) == ["Chatbot"])
    }

    @Test func aHiddenAppNeverSqueezesTerminalsBelowComfortableAtAChosenFont() {
        // Mostly behind the browser, but poking out far enough to take the left-hand terminals' space.
        let result = plan(terminals: 12, [browser, app("Behind", 1000, 100, 1700, 1000)], font: .fixed(14))
        #expect(result.keptClear.map(\.owner) == ["Browser"])
        #expect(result.covered.map(\.owner) == ["Behind"])
    }

    @Test func anAppThatEndsUpClearIsReportedAsClearEvenWithoutBeingPlannedFor() {
        // Too costly to plan around at this font, but the terminals never reach it.
        let result = plan(terminals: 12, [browser, app("Behind", 2000, 100, 1000, 1000)], font: .fixed(14))
        #expect(result.keptClear.map(\.owner) == ["Browser", "Behind"])
        #expect(result.covered.isEmpty)
    }

    @Test func whenNothingFitsTheTerminalsTakeTheWholeScreenAndSaySo() {
        let result = plan(terminals: 60, busyDesktop)
        #expect(result.keptClear.isEmpty)
        expectExactFill(result.layout.cells, of: [odyssey.visibleFrame])
        #expect(result.notes.joined().contains("Not enough room to keep clear of"))
        #expect(result.notes.joined().contains("below"))
    }

    @Test func fullIgnoresEveryOtherApp() {
        let result = plan(terminals: 12, busyDesktop, mode: .full)
        expectExactFill(result.layout.cells, of: [odyssey.visibleFrame])
        #expect(result.layout.fontSize == 16)
        #expect(result.keptClear.isEmpty)
        #expect(result.covered.isEmpty)
        #expect(result.notes.joined().contains("--around"))
    }

    @Test func nothingElseOpenMeansNoNotes() {
        let result = plan(terminals: 4, [])
        #expect(result.notes.isEmpty)
        expectExactFill(result.layout.cells, of: [odyssey.visibleFrame])
    }

    @Test func notesNameEachAppOnceAndWithoutInvisibleCharacters() {
        let windows = [
            app("\u{200E}Messenger", 0, 30, 800, 800),
            app("\u{200E}Messenger", 900, 30, 800, 800),
            app("Bad\u{1B}[31mName", 2000, 30, 800, 800),
        ]
        let notes = plan(terminals: 2, windows).notes
        #expect(notes == ["Keeping clear of: Messenger, Bad[31mName"])
    }
}

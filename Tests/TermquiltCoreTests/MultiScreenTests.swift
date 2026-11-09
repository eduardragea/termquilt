import Foundation
import Testing
@testable import TermquiltCore

/// A laptop with a monitor to its right, bottom edges level, as measured on a real desk. The
/// monitor's top is 37 points below the laptop's, and it has its own menu bar.
enum Desk {
    static let laptop = Display(
        name: "Built-in Retina Display", frame: Rect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: Rect(x: 0, y: 33, width: 1728, height: 1006), scale: 2, isBuiltIn: true
    )
    static let monitor = Display(
        name: "LG FHD", frame: Rect(x: 1728, y: 37, width: 1920, height: 1080),
        visibleFrame: Rect(x: 1728, y: 67, width: 1920, height: 1050), scale: 1, isBuiltIn: false
    )
    static let otherMonitor = Display(
        name: "DELL U2723QE", frame: Rect(x: 1728, y: 0, width: 2560, height: 1440),
        visibleFrame: Rect(x: 1728, y: 30, width: 2560, height: 1410), scale: 2, isBuiltIn: false
    )
    static let both = [laptop, monitor]
    /// An app you're looking at, top left of the laptop.
    static let chat = ScreenWindow(owner: "ChatGPT", frame: Rect(x: 0, y: 33, width: 1280, height: 820))

    /// Windows scattered over the laptop, as after working there all morning.
    static func onLaptop(_ count: Int, firstID: Int = 1) -> [TerminalWindow] {
        (0..<count).map { window(firstID + $0, 40 + $0 * 90, 60 + $0 * 70, 613, 424, font: 13) }
    }

    static func onMonitor(_ count: Int, firstID: Int) -> [TerminalWindow] {
        (0..<count).map { window(firstID + $0, 1800 + $0 * 120, 120 + $0 * 60, 700, 450, font: 13) }
    }
}

@Suite struct MultiScreenTests {
    func makeApp(
        _ terminal: FakeTerminal,
        displays: [Display] = Desk.both,
        above: [ScreenWindow] = [],
        store: Store? = nil
    ) -> TermquiltApp {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termquilt-\(UUID().uuidString)")
        return TermquiltApp(
            terminal: terminal,
            displays: FakeDisplays(list: displays),
            screen: StackedScreen(terminal: terminal, above: above),
            store: store ?? Store(directory: directory),
            settle: {}
        )
    }

    func windows(_ terminal: FakeTerminal, on display: Display) -> [TerminalWindow] {
        terminal.windows.filter { display.visibleFrame.clipped(to: $0.frame) == $0.frame }
    }

    @Test func sharesTheTerminalsAcrossBothScreens() throws {
        let terminal = FakeTerminal(Desk.onLaptop(10))
        let lines = try makeApp(terminal).tile(TileOptions())

        let onLaptop = windows(terminal, on: Desk.laptop)
        let onMonitor = windows(terminal, on: Desk.monitor)
        #expect(onLaptop.count + onMonitor.count == 10)
        // Room for about the same space each: 1728×1006 against 1920×1050.
        #expect(onLaptop.count == 5)
        #expect(onMonitor.count == 5)
        expectExactFill(onLaptop.map(\.frame), of: [Desk.laptop.visibleFrame])
        expectExactFill(onMonitor.map(\.frame), of: [Desk.monitor.visibleFrame])
        #expect(lines.contains { $0.hasPrefix("5 terminals on Built-in Retina Display") })
        #expect(lines.contains { $0.hasPrefix("5 terminals on LG FHD") })
    }

    @Test func nothingGoesUnderTheSecondScreensMenuBar() throws {
        let terminal = FakeTerminal(Desk.onLaptop(10))
        _ = try makeApp(terminal).tile(TileOptions())
        #expect(windows(terminal, on: Desk.monitor).allSatisfy { $0.frame.y >= Desk.monitor.visibleFrame.y })
        #expect(windows(terminal, on: Desk.monitor).contains { $0.frame.y == Desk.monitor.visibleFrame.y })
    }

    @Test func aSecondTileChangesNothing() throws {
        let terminal = FakeTerminal(Desk.onLaptop(7) + Desk.onMonitor(4, firstID: 20))
        let app = makeApp(terminal, above: [Desk.chat])
        _ = try app.tile(TileOptions())
        let tiled = terminal.windows
        let lines = try app.tile(TileOptions())
        #expect(lines.contains("Already tidy."))
        #expect(terminal.windows == tiled)
    }

    @Test func anAppOnOneScreenDoesNotSendEverythingToTheOther() throws {
        let terminal = FakeTerminal(Desk.onLaptop(10))
        let lines = try makeApp(terminal, above: [Desk.chat]).tile(TileOptions())
        #expect(windows(terminal, on: Desk.laptop).count == 5)
        #expect(lines.contains("Not enough room to keep clear of: ChatGPT"))
    }

    @Test func onEachScreenTheyStillGoAroundAppsWhenThereIsRoom() throws {
        let terminal = FakeTerminal(Desk.onLaptop(4))
        let small = ScreenWindow(owner: "Notes", frame: Rect(x: 0, y: 33, width: 500, height: 1006))
        _ = try makeApp(terminal, above: [small]).tile(TileOptions())
        #expect(windows(terminal, on: Desk.laptop).count == 2)
        #expect(!terminal.windows.contains { $0.frame.intersects(small.frame) })
    }

    @Test func windowsStayOnTheirScreenWhenItHasRoom() throws {
        let laptopIDs = Set(1...5)
        let terminal = FakeTerminal(Desk.onLaptop(5) + Desk.onMonitor(5, firstID: 20))
        _ = try makeApp(terminal).tile(TileOptions())
        #expect(Set(windows(terminal, on: Desk.laptop).map(\.id)) == laptopIDs)
    }

    @Test func eachScreenKeepsItsOwnFontAndBiggerRaisesEach() throws {
        let terminal = FakeTerminal(Desk.onLaptop(10))
        let app = makeApp(terminal)
        try app.store.save(Preferences(fontByDisplay: [Desk.laptop.name: 12, Desk.monitor.name: 14]))

        _ = try app.tile(TileOptions())
        #expect(windows(terminal, on: Desk.laptop).allSatisfy { $0.fontSize == 12 })
        #expect(windows(terminal, on: Desk.monitor).allSatisfy { $0.fontSize == 14 })

        _ = try app.adjustFont(by: 1, TileOptions())
        #expect(windows(terminal, on: Desk.laptop).allSatisfy { $0.fontSize == 13 })
        #expect(windows(terminal, on: Desk.monitor).allSatisfy { $0.fontSize == 15 })
        let saved = try app.store.loadPreferences()
        #expect(saved.font(for: Desk.laptop.name) == 13)
        #expect(saved.font(for: Desk.monitor.name) == 15)
    }

    @Test func aChosenScreenIsRememberedForThisSetOfScreens() throws {
        let terminal = FakeTerminal(Desk.onLaptop(6))
        let app = makeApp(terminal)

        _ = try app.tile(TileOptions(display: .external))
        #expect(windows(terminal, on: Desk.monitor).count == 6)

        let again = try app.tile(TileOptions())
        #expect(windows(terminal, on: Desk.monitor).count == 6)
        #expect(again.contains { $0.contains("Only using LG FHD") })

        _ = try app.tile(TileOptions(display: .all))
        #expect(!windows(terminal, on: Desk.laptop).isEmpty)
        _ = try app.tile(TileOptions())
        #expect(!windows(terminal, on: Desk.laptop).isEmpty)
    }

    @Test func aChosenScreenDoesNotFollowYouToAnotherDesk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termquilt-\(UUID().uuidString)")
        let store = Store(directory: directory)
        _ = try makeApp(FakeTerminal(Desk.onLaptop(6)), store: store).tile(TileOptions(display: .builtIn))

        let terminal = FakeTerminal(Desk.onLaptop(6))
        _ = try makeApp(terminal, displays: [Desk.laptop, Desk.otherMonitor], store: store).tile(TileOptions())
        #expect(windows(terminal, on: Desk.laptop).count < 6)
    }

    @Test func aDryRunRemembersNoScreen() throws {
        let terminal = FakeTerminal(Desk.onLaptop(6))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions(display: .external, dryRun: true))
        #expect(try app.store.loadPreferences().displayBySetup.isEmpty)
    }

    @Test func undoBringsBackTheScreenChoice() throws {
        let terminal = FakeTerminal(Desk.onLaptop(6))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions())
        _ = try app.tile(TileOptions(display: .external))
        _ = try app.undo()
        #expect(try app.store.loadPreferences().displayBySetup.isEmpty)
    }

    @Test func statusSaysHowATileWouldShareThemOut() throws {
        let terminal = FakeTerminal(Desk.onLaptop(10))
        let lines = try makeApp(terminal).status()
        #expect(lines.contains("Terminals are shared across every screen."))
        #expect(lines.contains("A tile would put 5 on Built-in Retina Display and 5 on LG FHD."))
    }

    @Test func fullOnEveryScreenFillsBoth() throws {
        let terminal = FakeTerminal(Desk.onLaptop(10))
        let app = makeApp(terminal, above: [Desk.chat])
        _ = try app.tile(TileOptions(layout: .full))
        expectExactFill(windows(terminal, on: Desk.laptop).map(\.frame), of: [Desk.laptop.visibleFrame])
        expectExactFill(windows(terminal, on: Desk.monitor).map(\.frame), of: [Desk.monitor.visibleFrame])
        let saved = try app.store.loadPreferences()
        #expect(saved.layout(for: Desk.laptop.name) == .full)
        #expect(saved.layout(for: Desk.monitor.name) == .full)
    }

    @Test func aTabAtAnotherSizeIsWorthATidyEvenWhenTheWindowIsInPlace() throws {
        let terminal = FakeTerminal(Desk.onLaptop(4))
        let app = makeApp(terminal)
        _ = try app.tile(TileOptions())
        terminal.windows[0] = terminal.windows[0].withTabsAtOtherSizes(true)
        let lines = try app.tile(TileOptions())
        #expect(!lines.contains("Already tidy."))
        #expect(terminal.appliedBatches.last?.map(\.windowID) == [terminal.windows[0].id])
        #expect(try app.tile(TileOptions()).contains("Already tidy."))
    }

    @Test func toggleFlipsEveryScreenTogether() throws {
        let terminal = FakeTerminal(Desk.onLaptop(4))
        let app = makeApp(terminal)
        _ = try app.toggleLayout(TileOptions())
        #expect(try app.store.loadPreferences().layout(for: Desk.laptop.name) == .full)
        #expect(try app.store.loadPreferences().layout(for: Desk.monitor.name) == .full)
        _ = try app.toggleLayout(TileOptions())
        #expect(try app.store.loadPreferences().layout(for: Desk.monitor.name) == .around)
    }
}

@Suite struct ScreenShareTests {
    @Test func oneScreenTakesEverything() {
        let windows = Desk.onLaptop(3)
        #expect(shareWindows(windows, among: [Desk.laptop]) == [windows])
    }

    @Test func sharesInProportionToSize() {
        #expect(shareWindows(Desk.onLaptop(10), among: Desk.both).map(\.count) == [5, 5])
        #expect(shareWindows(Desk.onLaptop(3), among: Desk.both).map(\.count) == [1, 2])
        #expect(shareWindows(Desk.onLaptop(1), among: Desk.both).map(\.count) == [0, 1])
    }

    @Test func theWindowsNearestTheOtherScreenAreTheOnesThatMove() {
        let windows = [100, 500, 900, 1300].enumerated().map { index, x in window(index + 1, x, 300, 200, 200) }
        let groups = shareWindows(windows, among: Desk.both)
        #expect(groups[0].map(\.id) == [1, 2])
        #expect(groups[1].map(\.id) == [3, 4])
    }

    @Test func anOddWindowBetweenTwoEqualScreensStaysPut() {
        let right = Display(
            name: "Right", frame: Rect(x: 1728, y: 0, width: 1728, height: 1117),
            visibleFrame: Rect(x: 1728, y: 33, width: 1728, height: 1006), scale: 2, isBuiltIn: false
        )
        let windows = [window(1, 100, 100, 400, 300), window(2, 1900, 100, 400, 300), window(3, 2400, 500, 400, 300)]
        let groups = shareWindows(windows, among: [Desk.laptop, right])
        #expect(groups.map { $0.map(\.id) } == [[1], [2, 3]])
    }

    @Test func aWindowOffEveryScreenGoesToTheNearest() {
        let lost = window(1, 5000, 300, 200, 200)
        #expect(shareWindows([lost], among: Desk.both).map(\.count) == [0, 1])
    }
}

@Suite struct ScreenChoiceTests {
    @Test func parsesEveryScreen() {
        #expect(DisplaySelector(parsing: "all") == .all)
        #expect(DisplaySelector(parsing: "Both") == .all)
        #expect(DisplaySelector(parsing: "auto") == .automatic)
    }

    @Test func automaticMeansEveryScreenUntilOneIsChosen() throws {
        #expect(try targetDisplays(Desk.both, .automatic, preferences: Preferences()) == Desk.both)
        let chosen = Preferences().settingDisplay(Desk.monitor.name, forSetup: setupKey(Desk.both))
        #expect(try targetDisplays(Desk.both, .automatic, preferences: chosen) == [Desk.monitor])
        #expect(try targetDisplays(Desk.both, .all, preferences: chosen) == Desk.both)
        #expect(try targetDisplays(Desk.both, .builtIn, preferences: chosen) == [Desk.laptop])
    }

    @Test func noScreensIsAnError() {
        #expect(throws: TermquiltError.self) { try targetDisplays([], .automatic, preferences: Preferences()) }
    }

    @Test func theSetupKeyIgnoresOrder() {
        #expect(setupKey(Desk.both) == setupKey(Desk.both.reversed()))
        #expect(setupKey(Desk.both) != setupKey([Desk.laptop, Desk.otherMonitor]))
    }

    @Test func olderSettingsFilesStillLoad() throws {
        let json = #"{"fontByDisplay":{"LG FHD":12},"layoutByDisplay":{}}"#
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(preferences.font(for: "LG FHD") == 12)
        #expect(preferences.displayBySetup.isEmpty)
    }
}

@Suite struct TerminalTabTests {
    /// Two tabs share the window at the top left. Only the selected one, 1, is on screen.
    let windows = [
        window(1, 0, 33, 600, 400, font: 13),
        window(2, 0, 33, 600, 400, font: 13),
        window(3, 600, 33, 600, 400, font: 13),
    ]

    @Test func backgroundTabsDontGetTheirOwnSlot() {
        #expect(windowsOnScreen(windows, onScreen: [1, 3]).map(\.id) == [1, 3])
    }

    @Test func withNoOnScreenListNothingIsLeftOut() {
        #expect(windowsOnScreen(windows, onScreen: nil).count == 3)
    }

    @Test func withNothingOnScreenNothingIsArranged() {
        #expect(windowsOnScreen(windows, onScreen: []).isEmpty)
    }

    @Test func aWindowSaysWhenATabBehindItHasAnotherSize() {
        let mixed = [window(1, 0, 33, 600, 400, font: 11), window(2, 0, 33, 600, 400, font: 13)]
        #expect(windowsOnScreen(mixed, onScreen: [1]).map(\.hasTabsAtOtherSizes) == [true])
        #expect(windowsOnScreen(windows, onScreen: [1, 3]).map(\.hasTabsAtOtherSizes) == [false, false])
    }

    @Test func backgroundTabsGetTheNewFontBeforeTheirWindowMoves() {
        let move = WindowPlacement(windowID: 1, frame: Rect(x: 0, y: 500, width: 500, height: 300), fontSize: 11, fontAction: .set)
        let placements = includingBackgroundTabs([move], windows: windows, onScreen: [1, 3])
        #expect(placements.map(\.windowID) == [2, 1])
        #expect(placements[0].frame == move.frame)
        #expect(placements[0].fontSize == 11)
        #expect(placements[0].fontAction == .set)
    }

    @Test func aTabAlreadyAtTheRightSizeIsLeftAlone() {
        let move = WindowPlacement(windowID: 1, frame: Rect(x: 0, y: 500, width: 500, height: 300), fontSize: 13, fontAction: .none)
        #expect(includingBackgroundTabs([move], windows: windows, onScreen: [1, 3]) == [move])
    }
}

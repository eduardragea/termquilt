import Foundation
import Testing
@testable import TermquiltCore

/// One terminal app for these tests, with a name and an on/off switch.
final class FakeApp: FakeTerminal, @unchecked Sendable {
    let name: String
    var listError: TermquiltError?
    var raiseError: TermquiltError?
    var pendingNotes: [String] = []
    var raisedCount: Int { broughtToFrontCount }

    init(_ name: String, _ windows: [TerminalWindow]) {
        self.name = name
        super.init(windows)
    }

    override var ownerNames: Set<String> { [name] }

    override func listWindows() throws(TermquiltError) -> [TerminalWindow] {
        if let listError { throw listError }
        return try super.listWindows()
    }

    override func bringToFront() throws(TermquiltError) {
        if let raiseError { throw raiseError }
        try super.bringToFront()
    }

    override func notes() -> [String] {
        let notes = pendingNotes
        pendingNotes = []
        return notes
    }
}

/// A window from an app that won't let other programs change its text size.
func fixedFontWindow(_ id: Int, _ x: Int, _ y: Int, title: String = "shell") -> TerminalWindow {
    TerminalWindow(
        id: id, title: title, frame: Rect(x: x, y: y, width: 700, height: 500),
        grid: CharGrid(columns: 96, rows: 30), fontSize: TerminalWindow.unknownFont,
        appName: "iTerm2", canSetFont: false
    )
}

@Suite struct CompositeTerminalTests {
    func window(_ id: Int, title: String = "a") -> TerminalWindow {
        TerminalWindow(id: id, title: title, frame: Rect(x: id * 10, y: 30, width: 600, height: 400), grid: CharGrid(columns: 80, rows: 24), fontSize: 13)
    }

    @Test func listsWindowsFromEveryRunningAppWithoutClashingIDs() throws {
        // Two apps can both have a window 7, because each numbers its own.
        let first = FakeApp("Terminal", [window(7)])
        let second = FakeApp("iTerm2", [window(7)])
        let composite = CompositeTerminal(backends: [first, second])
        let windows = try composite.listWindows()
        #expect(windows.count == 2)
        #expect(Set(windows.map(\.id)).count == 2)
    }

    @Test func aWindowKeepsItsIDAcrossRunsEvenAsOtherAppsComeAndGo() throws {
        let first = FakeApp("Terminal", [window(7)])
        let second = FakeApp("iTerm2", [window(9)])
        let bothRunning = try CompositeTerminal(backends: [first, second]).listWindows()
        first.running = false
        let oneRunning = try CompositeTerminal(backends: [first, second]).listWindows()
        #expect(bothRunning.map(\.id).last == oneRunning.map(\.id).first)
    }

    @Test func sendsEachPlacementToTheAppThatOwnsTheWindow() throws {
        let first = FakeApp("Terminal", [window(7)])
        let second = FakeApp("iTerm2", [window(7)])
        let composite = CompositeTerminal(backends: [first, second])
        let windows = try composite.listWindows()
        let target = Rect(x: 0, y: 30, width: 500, height: 300)
        let placements = windows.map { WindowPlacement(windowID: $0.id, frame: target, fontSize: 13, fontAction: .none) }
        #expect(try composite.apply(placements) == [])
        #expect(first.windows[0].frame == target)
        #expect(second.windows[0].frame == target)
        #expect(first.appliedBatches[0][0].windowID == 7)
        #expect(second.appliedBatches[0][0].windowID == 7)
    }

    @Test func reportsFailedWindowsWithTheIDsItHandedOut() throws {
        let first = FakeApp("Terminal", [window(7)])
        let second = FakeApp("iTerm2", [window(7)])
        second.failingIDs = [7]
        let composite = CompositeTerminal(backends: [first, second])
        let windows = try composite.listWindows()
        let placements = windows.map { WindowPlacement(windowID: $0.id, frame: Rect(x: 0, y: 30, width: 500, height: 300), fontSize: 13, fontAction: .none) }
        #expect(try composite.apply(placements) == [windows[1].id])
    }

    @Test func skipsAppsThatAreNotRunning() throws {
        let first = FakeApp("Terminal", [window(1)])
        first.running = false
        let second = FakeApp("iTerm2", [window(2)])
        let composite = CompositeTerminal(backends: [first, second])
        #expect(composite.isRunning())
        #expect(try composite.listWindows().count == 1)
        #expect(composite.ownerNames == ["iTerm2"])
    }

    @Test func isNotRunningWhenNoAppIs() {
        let only = FakeApp("Terminal", [])
        only.running = false
        #expect(!CompositeTerminal(backends: [only]).isRunning())
    }

    @Test func oneAppThatWontCooperateDoesNotStopTheOthers() throws {
        let first = FakeApp("Terminal", [window(1)])
        let second = FakeApp("Ghostty", [window(2)])
        second.listError = .accessibilityDenied(app: "Ghostty")
        let composite = CompositeTerminal(backends: [first, second])
        #expect(try composite.listWindows().count == 1)
        let notes = composite.notes().joined()
        #expect(notes.contains("Ghostty"))
        #expect(notes.contains("Accessibility"))
    }

    @Test func ifEveryAppFailsTheRealErrorComesThrough() {
        let only = FakeApp("Terminal", [window(1)])
        only.listError = .automationDenied(app: "Terminal")
        let composite = CompositeTerminal(backends: [only])
        #expect(throws: TermquiltError.automationDenied(app: "Terminal")) { try composite.listWindows() }
    }

    @Test func raisesEveryRunningApp() throws {
        let first = FakeApp("Terminal", [window(1)])
        let second = FakeApp("iTerm2", [window(2)])
        let stopped = FakeApp("Warp", [])
        stopped.running = false
        try CompositeTerminal(backends: [first, second, stopped]).bringToFront()
        #expect(first.raisedCount == 1)
        #expect(second.raisedCount == 1)
        #expect(stopped.raisedCount == 0)
    }

    @Test func anAppThatWontRaiseDoesNotStopTheOthers() throws {
        let first = FakeApp("Terminal", [window(1)])
        first.raiseError = .automationDenied(app: "Terminal")
        let second = FakeApp("iTerm2", [window(2)])
        let composite = CompositeTerminal(backends: [first, second])
        try composite.bringToFront()
        #expect(second.raisedCount == 1)
        #expect(composite.notes().joined().contains("Terminal"))
    }

    @Test func ifNoAppWillRaiseTheErrorComesThrough() {
        let only = FakeApp("Terminal", [window(1)])
        only.raiseError = .automationDenied(app: "Terminal")
        #expect(throws: TermquiltError.automationDenied(app: "Terminal")) { try CompositeTerminal(backends: [only]).bringToFront() }
    }

    @Test func aProblemIsReportedOnceAndNotAgainAfterItsFixed() throws {
        // Hotkeys keep one of these alive for days, so an old problem mustn't come back.
        let first = FakeApp("Terminal", [window(1)])
        let second = FakeApp("Ghostty", [window(2)])
        second.applyError = .automationDenied(app: "Ghostty")
        let composite = CompositeTerminal(backends: [first, second])
        let placements = try composite.listWindows().map { WindowPlacement(windowID: $0.id, frame: Rect(x: 0, y: 30, width: 500, height: 300), fontSize: 13, fontAction: .none) }
        _ = try composite.apply(placements)
        #expect(composite.notes().joined().contains("Ghostty"))
        #expect(composite.notes().isEmpty)
    }

    @Test func passesOnNotesFromTheAppsThemselves() {
        let only = FakeApp("Ghostty", [])
        only.pendingNotes = ["a note"]
        #expect(CompositeTerminal(backends: [only]).notes() == ["a note"])
    }

    @Test func anIDOutsideEveryAppsRangeIsIgnoredRatherThanCrashing() throws {
        let only = FakeApp("Terminal", [window(1)])
        let placement = WindowPlacement(windowID: 99 << 40, frame: Rect(x: 0, y: 30, width: 500, height: 300), fontSize: 13, fontAction: .none)
        #expect(try CompositeTerminal(backends: [only]).apply([placement]) == [])
        #expect(only.appliedBatches.isEmpty)
    }

    @Test func aSavedSessionSurvivesAnotherTerminalOpening() {
        let first = FakeApp("Terminal", [])
        let second = FakeApp("iTerm2", [])
        second.running = false
        let composite = CompositeTerminal(backends: [first, second])
        let saved = composite.sessionIdentifier
        second.running = true
        #expect(composite.matchesSession(saved))
    }

    @Test func aSavedSessionDoesNotSurviveItsAppRestarting() {
        let first = FakeApp("Terminal", [])
        let composite = CompositeTerminal(backends: [first])
        let saved = composite.sessionIdentifier
        first.session = "session-2"
        #expect(!composite.matchesSession(saved))
    }

    @Test func aSavedSessionDoesNotSurviveItsAppQuitting() {
        let first = FakeApp("Terminal", [])
        let composite = CompositeTerminal(backends: [first])
        let saved = composite.sessionIdentifier
        first.running = false
        #expect(!composite.matchesSession(saved))
    }

    @Test func aSessionSavedBeforeThereWereSeveralAppsIsNotTrusted() {
        // The old format had no app number, so its windows can't be matched to an app any more.
        let composite = CompositeTerminal(backends: [FakeApp("Terminal", [])])
        #expect(!composite.matchesSession("123-456.7"))
    }

    @Test func theSessionChangesWhenAnAppRestarts() {
        let first = FakeApp("Terminal", [])
        let second = FakeApp("iTerm2", [])
        let composite = CompositeTerminal(backends: [first, second])
        let before = composite.sessionIdentifier
        second.session = "session-2"
        #expect(composite.sessionIdentifier != before)
    }
}

/// The whole app, driving a mix of terminals through the composite.
@Suite struct MixedTerminalTests {
    let odyssey = Display(
        name: "Odyssey", frame: Rect(x: 0, y: 0, width: 5120, height: 1440),
        visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1332), scale: 1, isBuiltIn: false
    )
    let browser = ScreenWindow(owner: "Browser", frame: Rect(x: 1671, y: 30, width: 1975, height: 1252))

    func makeApp(_ backends: [any TerminalBackend], screen: [ScreenWindow] = []) -> TermquiltApp {
        TermquiltApp(
            terminal: CompositeTerminal(backends: backends),
            displays: FakeDisplays(list: [odyssey]),
            screen: FakeScreen(list: screen),
            store: Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("termquilt-\(UUID().uuidString)")),
            settle: {}
        )
    }

    @Test func arrangesWindowsFromDifferentAppsIntoOneGrid() throws {
        let terminal = FakeApp("Terminal", [window(1, 0, 0), window(2, 40, 40)])
        let iterm = FakeApp("iTerm2", [fixedFontWindow(1, 80, 80), fixedFontWindow(2, 120, 120)])
        let lines = try makeApp([terminal, iterm]).tile(TileOptions())
        expectExactFill((terminal.windows + iterm.windows).map(\.frame), of: [odyssey.visibleFrame])
        #expect(lines[0].contains("4 terminals"))
    }

    @Test func treatsOtherTerminalAppsAsTerminalsNotAsAppsToAvoid() throws {
        let terminal = FakeApp("Terminal", [window(1, 0, 0)])
        let iterm = FakeApp("iTerm2", [fixedFontWindow(1, 80, 80)])
        let screen = (terminal.windows + iterm.windows).enumerated().map { index, window in
            ScreenWindow(owner: index == 0 ? "Terminal" : "iTerm2", frame: window.frame)
        }
        let lines = try makeApp([terminal, iterm], screen: screen).tile(TileOptions())
        #expect(!lines.contains { $0.contains("Keeping clear") || $0.contains("Not enough room") })
        expectExactFill((terminal.windows + iterm.windows).map(\.frame), of: [odyssey.visibleFrame])
    }

    @Test func stillGoesAroundOtherApps() throws {
        let iterm = FakeApp("iTerm2", [fixedFontWindow(1, 0, 0), fixedFontWindow(2, 40, 40)])
        _ = try makeApp([iterm], screen: [browser]).tile(TileOptions())
        #expect(!iterm.windows.contains { $0.frame.intersects(browser.frame) })
    }

    @Test func neverAsksAnAppThatCantChangeItsFontToDoSo() throws {
        let iterm = FakeApp("iTerm2", [fixedFontWindow(1, 0, 0)])
        _ = try makeApp([iterm]).tile(TileOptions(font: .fixed(20)))
        #expect(!iterm.appliedBatches.isEmpty)
        #expect(iterm.appliedBatches.joined().allSatisfy { $0.fontAction == .none })
    }

    @Test func doesNotClaimATextSizeWhenNoWindowHasOneItControls() throws {
        let iterm = FakeApp("iTerm2", [fixedFontWindow(1, 0, 0)])
        let lines = try makeApp([iterm]).tile(TileOptions())
        #expect(!lines[0].contains(" pt"))
    }

    @Test func explainsWhenOnlySomeWindowsTookTheFont() throws {
        let terminal = FakeApp("Terminal", [window(1, 0, 0)])
        let iterm = FakeApp("iTerm2", [fixedFontWindow(1, 80, 80)])
        let lines = try makeApp([terminal, iterm]).tile(TileOptions(font: .fixed(14)))
        #expect(terminal.windows[0].fontSize == 14)
        #expect(lines.contains { $0.contains("iTerm2") && $0.contains("text size") })
    }

    @Test func biggerExplainsWhenNothingCanChangeAndMovesNothing() throws {
        let iterm = FakeApp("iTerm2", [fixedFontWindow(1, 0, 0)])
        let app = makeApp([iterm])
        let lines = try app.adjustFont(by: 1, TileOptions())
        #expect(iterm.appliedBatches.isEmpty)
        #expect(lines.joined().contains("iTerm2"))
        #expect(lines.joined().contains("⌘+"))
        #expect(try app.store.loadPreferences().font(for: "Odyssey") == nil)
    }

    @Test func aChosenFontIsNotRememberedIfNothingCouldUseIt() throws {
        let iterm = FakeApp("iTerm2", [fixedFontWindow(1, 0, 0)])
        let app = makeApp([iterm])
        _ = try app.tile(TileOptions(font: .fixed(20)))
        #expect(try app.store.loadPreferences().font(for: "Odyssey") == nil)
    }

    @Test func reTilingAWindowWhoseFontCantBeReadChangesNothing() throws {
        // Ghostty can set a font but not report one, so its windows always look unknown.
        let ghostty = FakeApp("Ghostty", [unreadableFontWindow(1, 0, 0)])
        ghostty.keepsFontUnknown = true
        let app = makeApp([ghostty])
        _ = try app.tile(TileOptions())
        #expect(ghostty.appliedBatches.joined().allSatisfy { $0.fontAction == .set })
        let lines = try app.tile(TileOptions())
        #expect(ghostty.appliedBatches.count == 1)
        #expect(lines.contains("Already tidy."))
    }

    @Test func aChosenFontStillReachesAWindowWhoseFontCantBeRead() throws {
        let ghostty = FakeApp("Ghostty", [unreadableFontWindow(1, 0, 0)])
        ghostty.keepsFontUnknown = true
        let app = makeApp([ghostty])
        _ = try app.tile(TileOptions())
        _ = try app.tile(TileOptions(font: .fixed(15)))
        #expect(ghostty.appliedBatches.count == 2)
        #expect(ghostty.appliedBatches[1].allSatisfy { $0.fontAction == .set && $0.fontSize == 15 })
    }

    @Test func biggerWorksOnAWindowWhoseFontCantBeRead() throws {
        let ghostty = FakeApp("Ghostty", [unreadableFontWindow(1, 0, 0)])
        ghostty.keepsFontUnknown = true
        let app = makeApp([ghostty])
        _ = try app.tile(TileOptions())
        let automatic = try #require(ghostty.appliedBatches[0].first?.fontSize)
        _ = try app.adjustFont(by: -1, TileOptions())
        #expect(ghostty.appliedBatches.last?.first?.fontSize == automatic - 1)
    }

    @Test func undoRestoresPositionsWithoutTouchingFontsItCantSet() throws {
        let original = fixedFontWindow(1, 100, 100)
        let iterm = FakeApp("iTerm2", [original])
        let app = makeApp([iterm])
        _ = try app.tile(TileOptions())
        _ = try app.undo()
        #expect(iterm.windows[0].frame == original.frame)
        #expect(iterm.appliedBatches.count == 2)
        #expect(iterm.appliedBatches.joined().allSatisfy { $0.fontAction == .none })
    }

    @Test func statusNamesTheAppWhenItCantReportATextSize() throws {
        let iterm = FakeApp("iTerm2", [fixedFontWindow(1, 0, 0, title: "my session")])
        let lines = try makeApp([iterm]).status()
        #expect(lines.contains { $0.contains("iTerm2") && $0.contains("my session") && !$0.contains("0 pt") })
    }

    @Test func statusLeavesOutAGridItCantKnow() throws {
        let ghostty = FakeApp("Ghostty", [unreadableFontWindow(1, 0, 0, title: "my session")])
        let lines = try makeApp([ghostty]).status()
        #expect(lines.contains { $0.contains("my session") && !$0.contains("0×0") })
    }

    @Test func aTileNeverReportsAnEmptyGrid() throws {
        let ghostty = FakeApp("Ghostty", [unreadableFontWindow(1, 0, 0)])
        ghostty.keepsFontUnknown = true
        let lines = try makeApp([ghostty]).tile(TileOptions())
        #expect(!lines[0].contains("0×0"))
    }

    @Test func doesNotInventAGridForAWindowItKnowsNothingAbout() throws {
        // Like kitty: it reports no grid and no font, and this can't set one.
        let kitty = FakeApp("kitty", [
            TerminalWindow(
                id: 1, title: "shell", frame: Rect(x: 0, y: 30, width: 700, height: 500),
                grid: CharGrid(columns: 0, rows: 0), fontSize: TerminalWindow.unknownFont,
                appName: "kitty", canSetFont: false
            ),
        ])
        let lines = try makeApp([kitty]).tile(TileOptions())
        #expect(lines[0] == "1 terminal on Odyssey")
        let preview = try makeApp([kitty]).tile(TileOptions(dryRun: true))
        #expect(preview[0] == "1 terminal on Odyssey")
    }

    @Test func noWindowsButAFailedAppStillExplainsTheFailure() throws {
        // Nothing to arrange in Terminal, and Ghostty has windows it isn't allowed to see.
        let terminal = FakeApp("Terminal", [])
        let ghostty = FakeApp("Ghostty", [])
        ghostty.listError = .accessibilityDenied(app: "Ghostty")
        let lines = try makeApp([terminal, ghostty]).tile(TileOptions())
        #expect(lines.contains { $0.contains("No terminal windows") })
        #expect(lines.contains { $0.contains("Ghostty") && $0.contains("Accessibility") })
    }

    @Test func undoReportsProblemsToo() throws {
        let terminal = FakeApp("Terminal", [window(1, 0, 0)])
        let ghostty = FakeApp("Ghostty", [])
        let app = makeApp([terminal, ghostty])
        _ = try app.tile(TileOptions())
        ghostty.pendingNotes = ["a problem"]
        let lines = try app.undo()
        #expect(lines.contains("a problem"))
    }

    @Test func aFailedRunDoesNotRememberTheFontItAskedFor() throws {
        let terminal = FakeApp("Terminal", [window(1, 0, 0)])
        terminal.applyError = .automationDenied(app: "Terminal")
        let app = makeApp([terminal])
        #expect(throws: TermquiltError.self) { try app.tile(TileOptions(font: .fixed(14))) }
        #expect(try app.store.loadPreferences().font(for: "Odyssey") == nil)
    }

    @Test func passesOnNotesAboutAppsThatCouldNotBeIncluded() throws {
        let terminal = FakeApp("Terminal", [window(1, 0, 0)])
        let ghostty = FakeApp("Ghostty", [])
        ghostty.listError = .accessibilityDenied(app: "Ghostty")
        let lines = try makeApp([terminal, ghostty]).tile(TileOptions())
        #expect(lines.contains { $0.contains("Ghostty") && $0.contains("Accessibility") })
    }

    func unreadableFontWindow(_ id: Int, _ x: Int, _ y: Int, title: String = "shell") -> TerminalWindow {
        TerminalWindow(
            id: id, title: title, frame: Rect(x: x, y: y, width: 700, height: 500),
            grid: CharGrid(columns: 0, rows: 0), fontSize: TerminalWindow.unknownFont,
            appName: "Ghostty", canSetFont: true
        )
    }
}

@Suite struct ITermScriptTests {
    @Test func listsOnlyOrdinaryVisibleWindows() {
        #expect(ITermScript.list.contains("visible of w"))
        #expect(ITermScript.list.contains("miniaturized of w"))
        #expect(ITermScript.list.contains("is hotkey window of w"))
        #expect(ITermScript.list.contains(ITermScript.bundleIdentifier))
    }

    @Test func parsesIntoWindowsThatCannotSetAFont() throws {
        let raw = "80549\u{1F}0\u{1F}30\u{1F}835\u{1F}474\u{1F}115\u{1F}23\u{1F}0\u{1F}my session"
        let windows = try parseITermWindowList(raw, appName: "iTerm2")
        #expect(windows == [
            TerminalWindow(
                id: 80549, title: "my session", frame: Rect(x: 0, y: 30, width: 835, height: 444),
                grid: CharGrid(columns: 115, rows: 23), fontSize: TerminalWindow.unknownFont,
                appName: "iTerm2", canSetFont: false
            ),
        ])
    }

    @Test func placingWindowsSetsBoundsAndNothingElse() {
        let script = ITermScript.apply([
            WindowPlacement(windowID: 80549, frame: Rect(x: 0, y: 30, width: 835, height: 444), fontSize: 20, fontAction: .set),
        ])
        #expect(script.contains("window id 80549"))
        #expect(script.contains("{0, 30, 835, 474}"))
        #expect(!script.contains("font"))
        #expect(!script.contains("write"))
    }
}

@Suite struct SandboxTests {
    @Test func spotsCodexsSandbox() {
        #expect(sandboxProblem(environment: ["CODEX_SANDBOX": "seatbelt"]) == .insideCodexSandbox)
    }

    @Test func staysOutOfTheWayEverywhereElse() {
        #expect(sandboxProblem(environment: [:]) == nil)
        #expect(sandboxProblem(environment: ["CODEX_MANAGED_BY_NPM": "1", "TERM": "xterm"]) == nil)
    }

    @Test func anEmptyValueIsNotASandbox() {
        #expect(sandboxProblem(environment: ["CODEX_SANDBOX": ""]) == nil)
    }

    @Test func canBeOverriddenWhenTheVariableIsJustLeftOver() {
        // A tmux server started from the sandbox passes the variable on to ordinary shells.
        let environment = ["CODEX_SANDBOX": "seatbelt", "TERMQUILT_IGNORE_SANDBOX": "1"]
        #expect(sandboxProblem(environment: environment) == nil)
    }

    @Test func explainsTheFix() {
        let message = TermquiltError.insideCodexSandbox.description
        #expect(message.contains("sandbox"))
        #expect(message.contains(#"prefix_rule(pattern=["termquilt"], decision="allow")"#))
        #expect(message.contains("~/.codex/rules/default.rules"))
        #expect(message.contains("TERMQUILT_IGNORE_SANDBOX=1"))
    }
}

@Suite struct GhosttyScriptTests {
    @Test func setsTheFontOnEveryTerminal() {
        let script = GhosttyScript.setFont(14)
        #expect(script.contains(GhosttyScript.bundleIdentifier))
        #expect(script.contains("repeat with t in terminals"))
        #expect(script.contains(#"perform action "set_font_size:14" on t"#))
    }
}

import Foundation
import Testing
@testable import TermquiltCore

@Suite struct WindowListParsingTests {
    let unit = "\u{1F}"
    let record = "\u{1E}"

    func line(_ fields: String...) -> String { fields.joined(separator: unit) }

    @Test func parsesWhatTheScriptReturns() throws {
        let raw = [
            line("52", "0", "35", "917", "543", "88", "23", "11", "project — claude — 88×23"),
            line("54", "-100", "30", "400", "500", "80", "24", "13", "other"),
        ].joined(separator: record)
        let windows = try parseWindowList(raw)
        #expect(windows.count == 2)
        #expect(windows[0] == TerminalWindow(
            id: 52, title: "project — claude — 88×23",
            frame: Rect(x: 0, y: 35, width: 917, height: 508),
            grid: CharGrid(columns: 88, rows: 23), fontSize: 11
        ))
        #expect(windows[1].frame == Rect(x: -100, y: 30, width: 500, height: 470))
    }

    @Test func emptyOutputMeansNoWindows() throws {
        #expect(try parseWindowList("").isEmpty)
    }

    @Test func titlesMayContainAnything() throws {
        let raw = line("1", "0", "0", "10", "10", "1", "1", "11", "a,b;c \"quoted\" 🧵")
        #expect(try parseWindowList(raw)[0].title == "a,b;c \"quoted\" 🧵")
    }

    @Test func malformedOutputIsAnErrorRatherThanAGuess() {
        #expect(throws: TermquiltError.self) { try parseWindowList("garbage") }
        #expect(throws: TermquiltError.self) { try parseWindowList(line("x", "0", "0", "10", "10", "1", "1", "11", "t")) }
        // right edge before left edge
        #expect(throws: TermquiltError.self) { try parseWindowList(line("1", "50", "0", "10", "10", "1", "1", "11", "t")) }
    }
}

@Suite struct ApplyScriptTests {
    @Test func setsFontBeforeBoundsBecauseFontChangesResizeTheWindow() throws {
        let script = TerminalScript.apply([
            WindowPlacement(windowID: 7, frame: Rect(x: 10, y: 20, width: 100, height: 200), fontSize: 14, fontAction: .set),
        ])
        let font = try #require(script.range(of: "set font size of t to 14"))
        let bounds = try #require(script.range(of: "set bounds of w to {10, 20, 110, 220}"))
        #expect(font.lowerBound < bounds.lowerBound)
        #expect(script.contains("window id 7"))
    }

    @Test func refreshNudgesTheFontOffAndBackOn() throws {
        let script = TerminalScript.apply([
            WindowPlacement(windowID: 7, frame: Rect(x: 0, y: 0, width: 100, height: 100), fontSize: 14, fontAction: .refresh),
        ])
        let nudge = try #require(script.range(of: "set font size of t to 15"))
        let target = try #require(script.range(of: "set font size of t to 14"))
        #expect(nudge.lowerBound < target.lowerBound)
    }

    @Test func refreshAtTheLargestFontNudgesDownward() throws {
        let script = TerminalScript.apply([
            WindowPlacement(
                windowID: 7, frame: Rect(x: 0, y: 0, width: 100, height: 100),
                fontSize: FontLimits.maximum, fontAction: .refresh
            ),
        ])
        #expect(script.contains("set font size of t to \(FontLimits.maximum - 1)"))
        #expect(!script.contains("set font size of t to \(FontLimits.maximum + 1)"))
    }

    @Test func noFontLinesWhenTheFontIsAlreadyRight() {
        let script = TerminalScript.apply([
            WindowPlacement(windowID: 7, frame: Rect(x: 0, y: 0, width: 100, height: 100), fontSize: 14, fontAction: .none),
        ])
        #expect(!script.contains("font size"))
    }

    @Test func aWindowThatDisappearedIsReportedNotFatal() {
        let script = TerminalScript.apply([
            WindowPlacement(windowID: 7, frame: Rect(x: 0, y: 0, width: 100, height: 100), fontSize: 14, fontAction: .none),
        ])
        #expect(script.contains("on error"))
        #expect(script.contains("set end of failed to 7"))
    }

    @Test func failedIDsParse() {
        #expect(parseFailedIDs("") == [])
        #expect(parseFailedIDs("7,12") == [7, 12])
    }
}

@Suite struct StoreTests {
    func temporaryStore() -> Store {
        Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("termquilt-\(UUID().uuidString)"))
    }

    @Test func missingFilesMeanDefaults() throws {
        let store = temporaryStore()
        #expect(try store.loadPreferences() == Preferences())
        #expect(try store.loadSnapshot() == nil)
    }

    @Test func preferencesRoundTripPerDisplay() throws {
        let store = temporaryStore()
        let preferences = Preferences().settingFont(14, for: "Odyssey").settingFont(11, for: "Color LCD")
        try store.save(preferences)
        let loaded = try store.loadPreferences()
        #expect(loaded.font(for: "Odyssey") == 14)
        #expect(loaded.font(for: "Color LCD") == 11)
        #expect(loaded.font(for: "Unknown") == nil)
    }

    @Test func settingAFontLeavesTheOriginalUntouched() {
        let original = Preferences().settingFont(14, for: "Odyssey")
        let changed = original.settingFont(nil, for: "Odyssey")
        #expect(original.font(for: "Odyssey") == 14)
        #expect(changed.font(for: "Odyssey") == nil)
    }

    @Test func snapshotsRoundTrip() throws {
        let store = temporaryStore()
        let snapshot = Snapshot(
            windows: [WindowState(id: 1, frame: Rect(x: 1, y: 2, width: 3, height: 4), fontSize: 11)],
            terminalSession: "123-456",
            preferences: Preferences().settingFont(14, for: "Odyssey")
        )
        try store.save(snapshot)
        #expect(try store.loadSnapshot() == snapshot)
    }

    @Test func corruptFilesAreReportedNotIgnored() throws {
        let store = temporaryStore()
        try store.save(Preferences())
        try Data("{not json".utf8).write(to: store.preferencesURL)
        #expect(throws: TermquiltError.self) { try store.loadPreferences() }
    }

    @Test func nonsenseFontSizesInConfigAreRejected() throws {
        let store = temporaryStore()
        try store.save(Preferences())
        try Data(#"{"fontByDisplay":{"Odyssey":9000}}"#.utf8).write(to: store.preferencesURL)
        #expect(throws: TermquiltError.self) { try store.loadPreferences() }
    }

    @Test func layoutsDefaultToAroundAndRoundTripPerDisplay() throws {
        let store = temporaryStore()
        try store.save(Preferences().settingLayout(.full, for: "Odyssey"))
        let loaded = try store.loadPreferences()
        #expect(loaded.layout(for: "Odyssey") == .full)
        #expect(loaded.layout(for: "Color LCD") == .around)
    }

    @Test func settingALayoutKeepsFontsAndLeavesTheOriginalUntouched() {
        let original = Preferences().settingFont(14, for: "Odyssey")
        let changed = original.settingLayout(.full, for: "Odyssey")
        #expect(original.layout(for: "Odyssey") == .around)
        #expect(changed.layout(for: "Odyssey") == .full)
        #expect(changed.font(for: "Odyssey") == 14)
        #expect(changed.settingFont(15, for: "Odyssey").layout(for: "Odyssey") == .full)
    }

    @Test func settingsSavedBeforeLayoutsExistedStillLoad() throws {
        let store = temporaryStore()
        try store.save(Preferences())
        try Data(#"{"fontByDisplay":{"Odyssey":14}}"#.utf8).write(to: store.preferencesURL)
        let loaded = try store.loadPreferences()
        #expect(loaded.font(for: "Odyssey") == 14)
        #expect(loaded.layout(for: "Odyssey") == .around)
    }

    @Test func undoPointsSavedBeforeLayoutsExistedStillLoad() throws {
        let store = temporaryStore()
        try store.save(Preferences())
        let old = #"{"windows":[],"terminalSession":"s","preferences":{"fontByDisplay":{"Odyssey":14}}}"#
        try Data(old.utf8).write(to: store.snapshotURL)
        #expect(try store.loadSnapshot()?.preferences.font(for: "Odyssey") == 14)
    }

    @Test func anUnknownLayoutInConfigIsRejected() throws {
        let store = temporaryStore()
        try store.save(Preferences())
        try Data(#"{"fontByDisplay":{},"layoutByDisplay":{"Odyssey":"sideways"}}"#.utf8).write(to: store.preferencesURL)
        #expect(throws: TermquiltError.self) { try store.loadPreferences() }
    }
}

@Suite struct FontOptionTests {
    @Test func parsesAutoAndNumbers() throws {
        #expect(try FontOption(parsing: "auto") == .automatic)
        #expect(try FontOption(parsing: "14") == .fixed(14))
    }

    @Test func rejectsWhatTerminalCouldNotRender() {
        #expect(throws: TermquiltError.self) { try FontOption(parsing: "3") }
        #expect(throws: TermquiltError.self) { try FontOption(parsing: "500") }
        #expect(throws: TermquiltError.self) { try FontOption(parsing: "big") }
    }
}

@Suite struct LaunchAgentPlistTests {
    @Test func runsTheHotkeyAgentAndKeepsItAliveOnlyAfterCrashes() throws {
        let plist = LaunchAgentPlist.contents(
            executablePath: "/Users/me/.local/bin/termquilt",
            logPath: "/Users/me/Library/Logs/termquilt.log"
        )
        #expect(plist["Label"] as? String == LaunchAgentPlist.label)
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/me/.local/bin/termquilt", "hotkeys", "run"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
        #expect(plist["StandardErrorPath"] as? String == "/Users/me/Library/Logs/termquilt.log")
    }
}

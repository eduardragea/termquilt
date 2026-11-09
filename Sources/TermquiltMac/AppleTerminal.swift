import AppKit
import TermquiltCore

/// Terminal.app, driven through its AppleScript dictionary. It can do everything.
public struct AppleTerminal: TerminalBackend {
    private let app = RunningApp(bundleIdentifiers: ["com.apple.Terminal"], fallbackName: "Terminal")
    private let script = AppleScriptRunner(appName: "Terminal")

    public init() {}

    public var ownerNames: Set<String> { app.ownerNames }
    public var sessionIdentifier: String { app.session }
    public func isRunning() -> Bool { !app.instances.isEmpty }

    public func bringToFront() throws(TermquiltError) {
        _ = try script.run(TerminalScript.activate)
    }

    /// Terminal lists each tab as a window, so only those on screen count.
    public func listWindows() throws(TermquiltError) -> [TerminalWindow] {
        windowsOnScreen(try everyWindow(), onScreen: onScreenWindowNumbers(of: app))
    }

    public func apply(_ placements: [WindowPlacement]) throws(TermquiltError) -> [Int] {
        let withTabs = includingBackgroundTabs(placements, windows: try everyWindow(), onScreen: onScreenWindowNumbers(of: app))
        let failed = parseFailedIDs(try script.run(TerminalScript.apply(withTabs, primaryHeight: primaryScreenHeight())))
        let asked = Set(placements.map(\.windowID))
        return failed.filter(asked.contains)
    }

    /// Includes background tabs and windows in other Spaces. Terminal's window IDs are the same
    /// numbers the system window list uses.
    private func everyWindow() throws(TermquiltError) -> [TerminalWindow] {
        try parseWindowList(script.run(TerminalScript.list))
    }
}

/// iTerm2, driven through its AppleScript dictionary. It moves windows exactly and reports its
/// character grid, but only its optional Python API can change text size.
public struct ITerm2Terminal: TerminalBackend {
    private static let name = "iTerm2"
    private let app = RunningApp(bundleIdentifiers: [ITermScript.bundleIdentifier], fallbackName: name)
    private let script = AppleScriptRunner(appName: name)

    public init() {}

    public var ownerNames: Set<String> { app.ownerNames }
    public var sessionIdentifier: String { app.session }
    public func isRunning() -> Bool { !app.instances.isEmpty }

    public func bringToFront() throws(TermquiltError) {
        _ = try script.run(ITermScript.activate)
    }

    public func listWindows() throws(TermquiltError) -> [TerminalWindow] {
        try parseITermWindowList(script.run(ITermScript.list), appName: Self.name)
    }

    public func apply(_ placements: [WindowPlacement]) throws(TermquiltError) -> [Int] {
        parseFailedIDs(try script.run(ITermScript.apply(placements)))
    }
}

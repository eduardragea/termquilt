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

    public func listWindows() throws(TermquiltError) -> [TerminalWindow] {
        try parseWindowList(script.run(TerminalScript.list))
    }

    public func apply(_ placements: [WindowPlacement]) throws(TermquiltError) -> [Int] {
        parseFailedIDs(try script.run(TerminalScript.apply(placements)))
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

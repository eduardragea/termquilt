import Foundation

/// Where the terminals are allowed to go.
public enum LayoutMode: String, Codable, Sendable {
    /// Keep clear of other apps as far as there's room.
    case around
    /// Use the whole screen, covering whatever is there.
    case full
}

/// What the user chose, remembered per display: the same terminals usually
/// want a different font on a laptop than on a 49-inch ultrawide.
public struct Preferences: Equatable, Codable, Sendable {
    public let fontByDisplay: [String: Int]
    public let layoutByDisplay: [String: LayoutMode]
    /// The one screen chosen for a set of screens, keyed by `setupKey`. Absent means all of them.
    public let displayBySetup: [String: String]

    public init(
        fontByDisplay: [String: Int] = [:],
        layoutByDisplay: [String: LayoutMode] = [:],
        displayBySetup: [String: String] = [:]
    ) {
        self.fontByDisplay = fontByDisplay
        self.layoutByDisplay = layoutByDisplay
        self.displayBySetup = displayBySetup
    }

    /// Files saved by older versions lack the newer keys.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontByDisplay = try container.decode([String: Int].self, forKey: .fontByDisplay)
        layoutByDisplay = try container.decodeIfPresent([String: LayoutMode].self, forKey: .layoutByDisplay) ?? [:]
        displayBySetup = try container.decodeIfPresent([String: String].self, forKey: .displayBySetup) ?? [:]
    }

    public func font(for display: String) -> Int? {
        fontByDisplay[display]
    }

    public func layout(for display: String) -> LayoutMode {
        layoutByDisplay[display] ?? .around
    }

    public func display(forSetup setup: String) -> String? {
        displayBySetup[setup]
    }

    /// Returns a copy with the display's font set, or removed when `font` is nil.
    public func settingFont(_ font: Int?, for display: String) -> Preferences {
        var updated = fontByDisplay
        updated[display] = font
        return Preferences(fontByDisplay: updated, layoutByDisplay: layoutByDisplay, displayBySetup: displayBySetup)
    }

    public func settingLayout(_ layout: LayoutMode, for display: String) -> Preferences {
        var updated = layoutByDisplay
        updated[display] = layout
        return Preferences(fontByDisplay: fontByDisplay, layoutByDisplay: updated, displayBySetup: displayBySetup)
    }

    /// Returns a copy with the screen chosen for this set of screens, or every screen when `display` is nil.
    public func settingDisplay(_ display: String?, forSetup setup: String) -> Preferences {
        var updated = displayBySetup
        updated[setup] = display
        return Preferences(fontByDisplay: fontByDisplay, layoutByDisplay: layoutByDisplay, displayBySetup: updated)
    }
}

public struct WindowState: Equatable, Codable, Sendable {
    public let id: Int
    public let frame: Rect
    public let fontSize: Int

    public init(id: Int, frame: Rect, fontSize: Int) {
        self.id = id
        self.frame = frame
        self.fontSize = fontSize
    }
}

/// Everything as it was before the last change, for `undo`.
public struct Snapshot: Equatable, Codable, Sendable {
    public let windows: [WindowState]
    /// Which run of Terminal these window IDs belong to. IDs can be reused after a relaunch.
    public let terminalSession: String
    public let preferences: Preferences

    public init(windows: [WindowState], terminalSession: String, preferences: Preferences) {
        self.windows = windows
        self.terminalSession = terminalSession
        self.preferences = preferences
    }
}

public struct Store: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/.config/termquilt`, or `TERMQUILT_CONFIG_DIR` when set.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["TERMQUILT_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/termquilt", isDirectory: true)
    }

    var preferencesURL: URL { directory.appendingPathComponent("preferences.json") }
    var snapshotURL: URL { directory.appendingPathComponent("undo.json") }

    public func loadPreferences() throws(TermquiltError) -> Preferences {
        guard let preferences: Preferences = try load(from: preferencesURL) else { return Preferences() }
        let invalid = preferences.fontByDisplay.values.first { !(FontLimits.minimum...FontLimits.maximum).contains($0) }
        if let invalid {
            throw .corruptFile(path: preferencesURL.path, reason: "\(invalid) isn't a usable font size")
        }
        return preferences
    }

    public func loadSnapshot() throws(TermquiltError) -> Snapshot? {
        try load(from: snapshotURL)
    }

    public func save(_ preferences: Preferences) throws(TermquiltError) {
        try write(preferences, to: preferencesURL)
    }

    public func save(_ snapshot: Snapshot) throws(TermquiltError) {
        try write(snapshot, to: snapshotURL)
    }

    private func load<Value: Decodable>(from url: URL) throws(TermquiltError) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch {
            throw .corruptFile(path: url.path, reason: error.localizedDescription)
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws(TermquiltError) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            throw .fileWriteFailed(path: url.path, reason: error.localizedDescription)
        }
    }
}

/// The launchd job that keeps the hotkeys available.
public enum LaunchAgentPlist {
    public static let label = "io.github.eduardragea.termquilt"

    public static func contents(executablePath: String, logPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executablePath, "hotkeys", "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }
}

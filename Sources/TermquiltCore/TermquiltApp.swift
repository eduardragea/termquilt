import Foundation

public protocol TerminalBackend {
    /// The owner names this terminal's windows have in the system window list.
    var ownerNames: Set<String> { get }
    /// Identifies this run of the terminal app. Changes when it relaunches.
    var sessionIdentifier: String { get }
    func isRunning() -> Bool
    /// Raises all of the terminal's windows above other apps.
    func bringToFront() throws(TermquiltError)
    func listWindows() throws(TermquiltError) -> [TerminalWindow]
    /// Returns the IDs of windows that could not be changed.
    func apply(_ placements: [WindowPlacement]) throws(TermquiltError) -> [Int]
    /// Anything the user should hear about, such as a terminal that had to be left out.
    func notes() -> [String]
    /// Whether a saved session identifier still describes the windows open now.
    func matchesSession(_ saved: String) -> Bool
}

public extension TerminalBackend {
    func notes() -> [String] { [] }
    func matchesSession(_ saved: String) -> Bool { saved == sessionIdentifier }
}

public protocol DisplayProvider {
    func displays() -> [Display]
}

public protocol ScreenWindowProvider {
    func windowsFrontToBack() -> [ScreenWindow]
}

public enum FontOption: Equatable, Sendable {
    /// Whatever was last chosen for this display, otherwise automatic.
    case saved
    /// Fit automatically and forget any saved choice.
    case automatic
    /// Use this size and remember it for this display.
    case fixed(Int)

    public init(parsing text: String) throws(TermquiltError) {
        if text.lowercased() == "auto" {
            self = .automatic
            return
        }
        guard let size = Int(text), (FontLimits.minimum...FontLimits.maximum).contains(size) else {
            throw .invalidFont(text)
        }
        self = .fixed(size)
    }
}

public struct TileOptions: Equatable, Sendable {
    public let font: FontOption
    /// Use this layout and remember it for the display. Nil means whatever was last chosen there.
    public let layout: LayoutMode?
    public let display: DisplaySelector
    public let match: String?
    public let dryRun: Bool

    public init(
        font: FontOption = .saved,
        layout: LayoutMode? = nil,
        display: DisplaySelector = .automatic,
        match: String? = nil,
        dryRun: Bool = false
    ) {
        self.font = font
        self.layout = layout
        self.display = display
        self.match = match
        self.dryRun = dryRun
    }

    func withFont(_ font: FontOption) -> TileOptions {
        TileOptions(font: font, layout: layout, display: display, match: match, dryRun: dryRun)
    }

    func withLayout(_ layout: LayoutMode) -> TileOptions {
        TileOptions(font: font, layout: layout, display: display, match: match, dryRun: dryRun)
    }
}

private enum FontRules {
    /// What to plan around when an app gives no way to tell what size its text is.
    static let assumedFont = 13
}

/// The commands, independent of how they were triggered. Each returns lines for the user to read.
public struct TermquiltApp {
    public let terminal: any TerminalBackend
    public let displays: any DisplayProvider
    public let screen: any ScreenWindowProvider
    public let store: Store
    /// Gives Terminal a moment to finish resizing before the result is read back.
    public let settle: () -> Void

    public init(
        terminal: any TerminalBackend,
        displays: any DisplayProvider,
        screen: any ScreenWindowProvider,
        store: Store,
        settle: @escaping () -> Void
    ) {
        self.terminal = terminal
        self.displays = displays
        self.screen = screen
        self.store = store
        self.settle = settle
    }

    public func tile(_ options: TileOptions) throws(TermquiltError) -> [String] {
        guard terminal.isRunning() else { throw .terminalNotRunning }
        let windows = try matchingWindows(options.match)
        guard !windows.isEmpty else { return ["No terminal windows to arrange."] + terminal.notes() }

        let display = try selectDisplay(displays.displays(), options.display)
        let preferences = try store.loadPreferences()
        let metrics = TerminalMetrics(scale: display.scale)
        let plan = tilePlan(for: windows, display: display, preferences: preferences, options: options)
        let placements = assignPlacements(
            windows: windows, cells: plan.layout.cells, fontSize: plan.layout.fontSize, metrics: metrics,
            applyingUnknownFonts: options.font != .saved
        )

        if options.dryRun {
            let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let predicted = placements
                .filter { byID[$0.windowID].map(hasKnowableGrid) ?? false }
                .map { metrics.grid(for: $0.frame.size, font: plan.layout.fontSize) }
            return describe(plan, display: display, grids: predicted, windows: windows, options: options)
                + ["Dry run: nothing was changed."]
        }

        let lines = try apply(placements, to: windows, plan: plan, display: display, metrics: metrics, previous: preferences, options: options)
        // Only after the change went through, so a failed run doesn't leave a size nothing is using.
        try remember(options, preferences: preferences, display: display, windows: windows)
        return lines
    }

    /// Flips between keeping clear of other apps and using the whole screen, then tiles.
    public func toggleLayout(_ options: TileOptions) throws(TermquiltError) -> [String] {
        let display = try selectDisplay(displays.displays(), options.display)
        let current = try store.loadPreferences().layout(for: display.name)
        return try tile(options.withLayout(current == .full ? .around : .full))
    }

    public func adjustFont(by delta: Int, _ options: TileOptions) throws(TermquiltError) -> [String] {
        guard terminal.isRunning() else { throw .terminalNotRunning }
        let windows = try matchingWindows(options.match)
        guard !windows.isEmpty else { return ["No terminal windows to arrange."] + terminal.notes() }

        // Moving windows wouldn't answer a request for bigger text, so say why nothing happened.
        guard windows.contains(where: \.canSetFont) else { return fixedFontNotes(for: windows) + terminal.notes() }

        let display = try selectDisplay(displays.displays(), options.display)
        let preferences = try store.loadPreferences()
        let readable = windows.filter { $0.canSetFont && $0.fontSize != TerminalWindow.unknownFont }
        let current = preferences.font(for: display.name)
            ?? (readable.isEmpty
                ? tilePlan(for: windows, display: display, preferences: preferences, options: options.withFont(.automatic)).layout.fontSize
                : mostCommonFont(in: readable))
        let next = min(FontLimits.maximum, max(FontLimits.minimum, current + delta))
        return try tile(options.withFont(.fixed(next)))
    }

    /// Restores the previous layout. Undoing twice redoes, because the state being
    /// replaced becomes the new undo point.
    public func undo() throws(TermquiltError) -> [String] {
        guard terminal.isRunning() else { throw .terminalNotRunning }
        guard let snapshot = try store.loadSnapshot() else { return ["Nothing to undo."] }
        guard terminal.matchesSession(snapshot.terminalSession) else {
            return ["Nothing to undo: a terminal app has restarted or quit since then, so those windows may be gone."]
        }

        // Only windows from the snapshot are in scope. Saving anything wider as the redo point
        // would let a second undo rewrite windows the original tile never touched.
        let savedIDs = Set(snapshot.windows.map(\.id))
        let windows = try terminal.listWindows().filter { savedIDs.contains($0.id) }
        let current = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placements = snapshot.windows.compactMap { saved -> WindowPlacement? in
            guard let window = current[saved.id] else { return nil }
            let placement = WindowPlacement(
                windowID: saved.id,
                frame: saved.frame,
                fontSize: saved.fontSize,
                fontAction: window.canSetFont && window.fontSize != saved.fontSize ? .set : .none
            )
            return placement.changes(window) ? placement : nil
        }
        guard !placements.isEmpty else { return ["Nothing to undo: those windows are already as they were, or have closed."] }

        let scale = try selectDisplay(displays.displays(), .automatic).scale
        let currentPreferences = try store.loadPreferences()
        // The undo point is replaced only once the restore has worked, so a failure can be retried.
        let failed = try terminal.apply(placements)
        try store.save(snapshotOf(windows, metrics: TerminalMetrics(scale: scale), preferences: currentPreferences))
        try store.save(snapshot.preferences)
        return ["Restored \(placements.count - failed.count) windows."] + failureNote(failed.count) + terminal.notes()
    }

    /// `display` and `match` work as they do for `tile`, so this reports what that tile would do.
    public func status(_ options: TileOptions = TileOptions()) throws(TermquiltError) -> [String] {
        let preferences = try store.loadPreferences()
        let displayLines = displays.displays().enumerated().map { index, display in
            let usable = display.visibleFrame
            let kind = display.isBuiltIn ? "laptop" : "external"
            return "Display \(index + 1): \(display.name) (\(kind)), usable area \(usable.width)×\(usable.height), "
                + settingsSummary(preferences, display: display)
        }
        guard terminal.isRunning() else { return displayLines + ["No supported terminal is running."] }

        let windows = try matchingWindows(options.match)
        let windowLines = windows.map(statusLine)
        let otherApps = try otherAppLines(for: windows, preferences: preferences, options: options)
        return displayLines + otherApps + terminal.notes() + ["\(windowLines.count) terminal windows:"] + windowLines
    }

    private func statusLine(for window: TerminalWindow) -> String {
        let frame = window.frame
        let grid = window.grid.columns > 0 ? "\(window.grid.columns)×\(window.grid.rows) at " : ""
        let font = window.fontSize == TerminalWindow.unknownFont ? window.appName : "\(window.fontSize) pt"
        return "  \(grid)\(frame.width)×\(frame.height), \(font): \(printable(window.title))"
    }

    private func settingsSummary(_ preferences: Preferences, display: Display) -> String {
        let layout = preferences.layout(for: display.name) == .full ? "full screen" : "around other apps"
        let font = preferences.font(for: display.name).map { "\($0) pt" } ?? "auto"
        return "layout: \(layout), font: \(font)"
    }

    /// Explains why a tile might not use the whole screen.
    private func otherAppLines(
        for windows: [TerminalWindow],
        preferences: Preferences,
        options: TileOptions
    ) throws(TermquiltError) -> [String] {
        let target = try selectDisplay(displays.displays(), options.display)
        let plan = tilePlan(for: windows, display: target, preferences: preferences, options: options)
        return plan.keptClear.map { "Keeping clear of \(placeText($0))" }
            + plan.covered.map { "No room to keep clear of \(placeText($0))" }
    }

    private func placeText(_ window: ScreenWindow) -> String {
        let frame = window.frame
        return "\(printable(window.owner)): \(frame.width)×\(frame.height) at \(frame.x),\(frame.y)"
    }

    private func matchingWindows(_ match: String?) throws(TermquiltError) -> [TerminalWindow] {
        let windows = try terminal.listWindows()
        guard let match else { return windows }
        return windows.filter { $0.title.localizedCaseInsensitiveContains(match) }
    }

    private func tilePlan(
        for windows: [TerminalWindow],
        display: Display,
        preferences: Preferences,
        options: TileOptions
    ) -> TilePlan {
        makeSettledTilePlan(
            tiledFrames: windows.map(\.frame),
            windowsFrontToBack: screen.windowsFrontToBack(),
            terminalOwners: terminal.ownerNames,
            display: display,
            mode: options.layout ?? preferences.layout(for: display.name),
            font: planningFont(for: windows, options: options, preferences: preferences, display: display),
            metrics: TerminalMetrics(scale: display.scale)
        )
    }

    /// When no window's text size can change, plan for the size they already have.
    private func planningFont(
        for windows: [TerminalWindow],
        options: TileOptions,
        preferences: Preferences,
        display: Display
    ) -> FontChoice {
        guard windows.isEmpty || windows.contains(where: \.canSetFont) else {
            return .fixed(estimatedFont(of: windows, metrics: TerminalMetrics(scale: display.scale)))
        }
        return fontChoice(options.font, preferences: preferences, display: display)
    }

    private func estimatedFont(of windows: [TerminalWindow], metrics: TerminalMetrics) -> Int {
        let fonts = windows.map { effectiveFont(of: $0, metrics: metrics) }.filter { $0 != TerminalWindow.unknownFont }
        let counts = Dictionary(grouping: fonts) { $0 }.mapValues(\.count)
        return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? FontRules.assumedFont
    }

    private func fontChoice(_ option: FontOption, preferences: Preferences, display: Display) -> FontChoice {
        switch option {
        case .automatic:
            return .automatic
        case .fixed(let size):
            return .fixed(size)
        case .saved:
            return preferences.font(for: display.name).map(FontChoice.fixed) ?? .automatic
        }
    }

    private func remember(
        _ options: TileOptions,
        preferences: Preferences,
        display: Display,
        windows: [TerminalWindow]
    ) throws(TermquiltError) {
        // A size nothing could use shouldn't be applied later to a window that can.
        let font = windows.contains(where: \.canSetFont) ? options.font : .saved
        let withFont: Preferences
        switch font {
        case .saved: withFont = preferences
        case .automatic: withFont = preferences.settingFont(nil, for: display.name)
        case .fixed(let size): withFont = preferences.settingFont(size, for: display.name)
        }
        let updated = options.layout.map { withFont.settingLayout($0, for: display.name) } ?? withFont
        guard updated != preferences else { return }
        try store.save(updated)
    }

    private func apply(
        _ placements: [WindowPlacement],
        to windows: [TerminalWindow],
        plan: TilePlan,
        display: Display,
        metrics: TerminalMetrics,
        previous: Preferences,
        options: TileOptions
    ) throws(TermquiltError) -> [String] {
        let frames = Set(placements.map(\.frame))
        let currentByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changes = placements.filter { placement in
            currentByID[placement.windowID].map(placement.changes) ?? false
        }
        guard !changes.isEmpty else {
            return describe(plan, display: display, grids: knownGrids(windows, plan: plan, metrics: metrics), windows: windows, options: options)
                + ["Already tidy."]
                + (try raiseIfCovered(frames))
        }

        // Saved before applying, so a failure partway through can still be undone.
        try store.save(snapshotOf(windows, metrics: metrics, preferences: previous))
        let failed = try terminal.apply(changes)
        settle()

        // Read back what Terminal actually did instead of reporting what was asked for. Goes by ID,
        // because a window's default title includes its size and so changes when it is resized.
        let tiledIDs = Set(windows.map(\.id))
        let after = try terminal.listWindows().filter { tiledIDs.contains($0.id) }
        let afterByID = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let refused = placements.filter { placement in
            !failed.contains(placement.windowID)
                && afterByID[placement.windowID].map { $0.frame != placement.frame } ?? false
        }
        let refusedNote = refused.isEmpty
            ? []
            : ["\(refused.count) window\(refused.count == 1 ? "" : "s") didn't take the requested size."]
        return describe(plan, display: display, grids: knownGrids(after, plan: plan, metrics: metrics), windows: after, options: options)
            + failureNote(failed.count)
            + refusedNote
            + (try raiseIfCovered(frames))
    }

    /// Moving a window doesn't raise it, so a terminal can land in its slot behind another app.
    /// Only raises when that really happened, because raising takes focus from whatever you're in.
    private func raiseIfCovered(_ frames: Set<Rect>) throws(TermquiltError) -> [String] {
        let isCovered = anyCovered(
            frames: frames,
            windowsFrontToBack: screen.windowsFrontToBack(),
            terminalOwners: terminal.ownerNames
        )
        guard isCovered else { return [] }
        try terminal.bringToFront()
        return ["Other windows were covering them, so your terminals came to the front."] + terminal.notes()
    }

    /// Stores the font each window really renders with, so undo can bring back a Cmd-zoomed window.
    private func snapshotOf(_ windows: [TerminalWindow], metrics: TerminalMetrics, preferences: Preferences) -> Snapshot {
        Snapshot(
            windows: windows.map { window in
                WindowState(
                    id: window.id,
                    frame: window.frame,
                    fontSize: window.canSetFont ? effectiveFont(of: window, metrics: metrics) : TerminalWindow.unknownFont
                )
            },
            terminalSession: terminal.sessionIdentifier,
            preferences: preferences
        )
    }

    private func failureNote(_ count: Int) -> [String] {
        guard count > 0 else { return [] }
        return ["\(count) window\(count == 1 ? "" : "s") couldn't be changed (closed in the meantime?)."]
    }

    private func mostCommonFont(in windows: [TerminalWindow]) -> Int {
        let counts = Dictionary(grouping: windows, by: \.fontSize).mapValues(\.count)
        let best = counts.max { ($0.value, $0.key) < ($1.value, $1.key) }
        return best?.key ?? FontLimits.autoMinimum
    }

    /// A grid can be worked out if the app reports it, or if termquilt set the font itself. Otherwise
    /// it would only be a guess about a font nothing here knows.
    private func hasKnowableGrid(_ window: TerminalWindow) -> Bool {
        window.grid.columns > 0 || window.canSetFont
    }

    private func knownGrids(_ windows: [TerminalWindow], plan: TilePlan, metrics: TerminalMetrics) -> [CharGrid] {
        windows.filter(hasKnowableGrid).map { window in
            window.grid.columns > 0 ? window.grid : metrics.grid(for: window.frame.size, font: plan.layout.fontSize)
        }
    }

    private func describe(
        _ plan: TilePlan,
        display: Display,
        grids: [CharGrid],
        windows: [TerminalWindow],
        options: TileOptions
    ) -> [String] {
        let count = plan.layout.cells.count
        let controlsFont = windows.contains(where: \.canSetFont)
        let font = controlsFont ? ", \(plan.layout.fontSize) pt" : ""
        let each = grids.isEmpty ? "" : ", each \(gridSummary(grids))"
        let summary = "\(count) terminal\(count == 1 ? "" : "s") on \(display.name)\(font)\(each)"
        // On its own, an app that can't change its text size needs no explaining unless asked for.
        let fontNotes = controlsFont || options.font != .saved ? fixedFontNotes(for: windows) : []
        return [summary] + plan.notes + fontNotes + terminal.notes()
    }

    private func fixedFontNotes(for windows: [TerminalWindow]) -> [String] {
        let apps = windows.filter { !$0.canSetFont }.map(\.appName)
        return apps.reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }.map { "\($0) doesn't let other programs set its text size, so those windows kept theirs. Use ⌘+ and ⌘- there." }
    }

    private func gridSummary(_ grids: [CharGrid]) -> String {
        let columns = grids.map(\.columns)
        let rows = grids.map(\.rows)
        return "\(rangeText(columns))×\(rangeText(rows))"
    }

    private func rangeText(_ values: [Int]) -> String {
        guard let low = values.min(), let high = values.max() else { return "0" }
        return low == high ? "\(low)" : "\(low)-\(high)"
    }
}

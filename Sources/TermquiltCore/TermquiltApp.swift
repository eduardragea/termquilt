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
        try tile(options, font: .option(options.font))
    }

    /// Flips between keeping clear of other apps and using the whole screen, then tiles.
    public func toggleLayout(_ options: TileOptions) throws(TermquiltError) -> [String] {
        let preferences = try store.loadPreferences()
        let targets = try targetDisplays(displays.displays(), options.display, preferences: preferences)
        let isFull = targets.allSatisfy { preferences.layout(for: $0.name) == .full }
        return try tile(options.withLayout(isFull ? .around : .full))
    }

    /// Each screen keeps its own size, so each goes one point up or down from where it is.
    public func adjustFont(by delta: Int, _ options: TileOptions) throws(TermquiltError) -> [String] {
        guard terminal.isRunning() else { throw .terminalNotRunning }
        let windows = try matchingWindows(options.match)
        guard !windows.isEmpty else { return ["No terminal windows to arrange."] + terminal.notes() }

        // Moving windows wouldn't answer a request for bigger text, so say why nothing happened.
        guard windows.contains(where: \.canSetFont) else { return fixedFontNotes(for: windows) + terminal.notes() }
        return try tile(options, font: .step(delta))
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
        let current = byID(windows)
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

        let all = displays.displays()
        guard !all.isEmpty else { throw .noDisplays }
        let currentPreferences = try store.loadPreferences()
        // The undo point is replaced only once the restore has worked, so a failure can be retried.
        let failed = try terminal.apply(placements)
        try store.save(snapshotOf(windows, displays: all, preferences: currentPreferences))
        try store.save(snapshot.preferences)
        return ["Restored \(placements.count - failed.count) windows."] + failureNote(failed.count) + terminal.notes()
    }

    /// `display` and `match` work as they do for `tile`, so this reports what that tile would do.
    public func status(_ options: TileOptions = TileOptions()) throws(TermquiltError) -> [String] {
        let preferences = try store.loadPreferences()
        let all = displays.displays()
        let displayLines = all.enumerated().map { index, display in
            let usable = display.visibleFrame
            let kind = display.isBuiltIn ? "laptop" : "external"
            return "Display \(index + 1): \(display.name) (\(kind)), usable area \(usable.width)×\(usable.height) at \(usable.x),\(usable.y), "
                + settingsSummary(preferences, display: display)
        }
        let screenLines = all.count > 1 ? [screenChoiceSummary(all, preferences: preferences)] : []
        guard terminal.isRunning() else { return displayLines + screenLines + ["No supported terminal is running."] }

        let windows = try matchingWindows(options.match)
        let targets = try targetDisplays(all, options.display, preferences: preferences)
        let screens = plan(windows, on: targets, preferences: preferences, options: options, font: .option(.saved))
        let shareLines = screens.count > 1
            ? ["A tile would put " + listText(screens.map { "\($0.windows.count) on \($0.display.name)" }) + "."]
            : []
        let otherApps = screens.flatMap { screen in
            screen.plan.keptClear.map { "Keeping clear of \(placeText($0))" }
                + screen.plan.covered.map { "No room to keep clear of \(placeText($0))" }
        }
        return displayLines + screenLines + shareLines + otherApps + terminal.notes()
            + ["\(windows.count) terminal windows:"] + windows.map(statusLine)
    }

    // MARK: - Planning

    private func tile(_ options: TileOptions, font request: FontRequest) throws(TermquiltError) -> [String] {
        guard terminal.isRunning() else { throw .terminalNotRunning }
        let windows = try matchingWindows(options.match)
        guard !windows.isEmpty else { return ["No terminal windows to arrange."] + terminal.notes() }

        let all = displays.displays()
        let preferences = try store.loadPreferences()
        let targets = try targetDisplays(all, options.display, preferences: preferences)
        let screens = plan(windows, on: targets, preferences: preferences, options: options, font: request)
        let choice = options.display == .automatic && targets.count < all.count
            ? ["Only using \(targets.map(\.name).joined()), as chosen for these screens. `termquilt --display all` uses every screen."]
            : []

        if options.dryRun {
            let byID = byID(windows)
            let predicted = screens.map { screen in
                screen.placements
                    .filter { byID[$0.windowID].map(hasKnowableGrid) ?? false }
                    .map { screen.metrics.grid(for: $0.frame.size, font: screen.plan.layout.fontSize) }
            }
            return describe(screens, grids: predicted, windows: windows, options: options, extra: choice)
                + ["Dry run: nothing was changed."]
        }

        let lines = try apply(screens, to: windows, displays: all, previous: preferences, options: options, extra: choice)
        // Only after the change went through, so a failed run doesn't leave a size nothing is using.
        try remember(screens, targets: targets, displays: all, preferences: preferences, options: options)
        return lines
    }

    /// Shares the windows out between the screens, then lays out each screen with its own settings.
    func plan(
        _ windows: [TerminalWindow],
        on targets: [Display],
        preferences: Preferences,
        options: TileOptions,
        font request: FontRequest
    ) -> [ScreenPlan] {
        let stack = screen.windowsFrontToBack()
        let owners = terminal.ownerNames
        let layoutMode = { (display: Display) in options.layout ?? preferences.layout(for: display.name) }
        let groups = shareWindows(windows, among: targets)
        // Every terminal is about to move, wherever it ends up, so none of them hides another app.
        let tiledFrames = windows.map(\.frame)

        return zip(targets, groups).filter { !$0.1.isEmpty }.map { display, group in
            let metrics = TerminalMetrics(scale: display.scale)
            let tilePlan = { (font: FontOption) in
                makeSettledTilePlan(
                    windowCount: group.count,
                    tiledFrames: tiledFrames,
                    windowsFrontToBack: stack,
                    terminalOwners: owners,
                    display: display,
                    mode: layoutMode(display),
                    font: planningFont(for: group, option: font, preferences: preferences, display: display),
                    metrics: metrics
                )
            }
            let font = fontOption(request, display: display, windows: group, preferences: preferences) {
                tilePlan(.automatic).layout.fontSize
            }
            let plan = tilePlan(font)
            let placements = assignPlacements(
                windows: group, cells: plan.layout.cells, fontSize: plan.layout.fontSize, metrics: metrics,
                applyingUnknownFonts: font != .saved
            )
            return ScreenPlan(display: display, windows: group, plan: plan, metrics: metrics, font: font, placements: placements)
        }
    }

    private func fontOption(
        _ request: FontRequest,
        display: Display,
        windows: [TerminalWindow],
        preferences: Preferences,
        automaticSize: () -> Int
    ) -> FontOption {
        switch request {
        case .option(let option):
            return option
        case .step(let delta):
            let readable = windows.filter { $0.canSetFont && $0.fontSize != TerminalWindow.unknownFont }
            let current = preferences.font(for: display.name)
                ?? (readable.isEmpty ? automaticSize() : mostCommonFont(in: readable))
            return .fixed(min(FontLimits.maximum, max(FontLimits.minimum, current + delta)))
        }
    }

    private func matchingWindows(_ match: String?) throws(TermquiltError) -> [TerminalWindow] {
        let windows = try terminal.listWindows()
        guard let match else { return windows }
        return windows.filter { $0.title.localizedCaseInsensitiveContains(match) }
    }

    /// When no window's text size can change, plan for the size they already have.
    private func planningFont(
        for windows: [TerminalWindow],
        option: FontOption,
        preferences: Preferences,
        display: Display
    ) -> FontChoice {
        guard windows.isEmpty || windows.contains(where: \.canSetFont) else {
            return .fixed(estimatedFont(of: windows, metrics: TerminalMetrics(scale: display.scale)))
        }
        return fontChoice(option, preferences: preferences, display: display)
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

    private func mostCommonFont(in windows: [TerminalWindow]) -> Int {
        let counts = Dictionary(grouping: windows, by: \.fontSize).mapValues(\.count)
        let best = counts.max { ($0.value, $0.key) < ($1.value, $1.key) }
        return best?.key ?? FontLimits.autoMinimum
    }

    // MARK: - Applying

    private func remember(
        _ screens: [ScreenPlan],
        targets: [Display],
        displays all: [Display],
        preferences: Preferences,
        options: TileOptions
    ) throws(TermquiltError) {
        let perScreen = screens.reduce(preferences) { current, screen in
            let name = screen.display.name
            // A size nothing could use shouldn't be applied later to a window that can.
            let font = screen.windows.contains(where: \.canSetFont) ? screen.font : .saved
            let withFont: Preferences
            switch font {
            case .saved: withFont = current
            case .automatic: withFont = current.settingFont(nil, for: name)
            case .fixed(let size): withFont = current.settingFont(size, for: name)
            }
            return options.layout.map { withFont.settingLayout($0, for: name) } ?? withFont
        }
        let updated: Preferences
        switch options.display {
        case .automatic:
            updated = perScreen
        case .all:
            updated = perScreen.settingDisplay(nil, forSetup: setupKey(all))
        case .builtIn, .external, .index, .name:
            updated = all.count > 1 ? perScreen.settingDisplay(targets.first?.name, forSetup: setupKey(all)) : perScreen
        }
        guard updated != preferences else { return }
        try store.save(updated)
    }

    private func apply(
        _ screens: [ScreenPlan],
        to windows: [TerminalWindow],
        displays all: [Display],
        previous: Preferences,
        options: TileOptions,
        extra: [String]
    ) throws(TermquiltError) -> [String] {
        let placements = screens.flatMap(\.placements)
        let frames = Set(placements.map(\.frame))
        let currentByID = byID(windows)
        let changes = placements.filter { placement in
            currentByID[placement.windowID].map(placement.changes) ?? false
        }
        guard !changes.isEmpty else {
            let grids = screens.map { knownGrids($0.windows, on: $0) }
            return describe(screens, grids: grids, windows: windows, options: options, extra: extra)
                + ["Already tidy."]
                + (try raiseIfCovered(frames))
        }

        // Saved before applying, so a failure partway through can still be undone.
        try store.save(snapshotOf(windows, displays: all, preferences: previous))
        let failed = try terminal.apply(changes)
        settle()

        // Read back what Terminal actually did instead of reporting what was asked for. Goes by ID,
        // because a window's default title includes its size and so changes when it is resized.
        let tiledIDs = Set(windows.map(\.id))
        let after = try terminal.listWindows().filter { tiledIDs.contains($0.id) }
        let afterByID = byID(after)
        let refused = placements.filter { placement in
            !failed.contains(placement.windowID)
                && afterByID[placement.windowID].map { $0.frame != placement.frame } ?? false
        }
        let refusedNote = refused.isEmpty
            ? []
            : ["\(refused.count) window\(refused.count == 1 ? "" : "s") didn't take the requested size."]
        let grids = screens.map { screen in knownGrids(screen.windows.compactMap { afterByID[$0.id] }, on: screen) }
        return describe(screens, grids: grids, windows: after, options: options, extra: extra)
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
    private func snapshotOf(_ windows: [TerminalWindow], displays all: [Display], preferences: Preferences) -> Snapshot {
        Snapshot(
            windows: windows.map { window in
                let metrics = TerminalMetrics(scale: display(showing: window.frame, among: all)?.scale ?? 1)
                return WindowState(
                    id: window.id,
                    frame: window.frame,
                    fontSize: window.canSetFont ? effectiveFont(of: window, metrics: metrics) : TerminalWindow.unknownFont
                )
            },
            terminalSession: terminal.sessionIdentifier,
            preferences: preferences
        )
    }

    /// A grid can be worked out if the app reports it, or if termquilt set the font itself. Otherwise
    /// it would only be a guess about a font nothing here knows.
    func hasKnowableGrid(_ window: TerminalWindow) -> Bool {
        window.grid.columns > 0 || window.canSetFont
    }

    private func knownGrids(_ windows: [TerminalWindow], on screen: ScreenPlan) -> [CharGrid] {
        windows.filter(hasKnowableGrid).map { window in
            window.grid.columns > 0 ? window.grid : screen.metrics.grid(for: window.frame.size, font: screen.plan.layout.fontSize)
        }
    }
}

/// How the text size was asked for.
enum FontRequest {
    case option(FontOption)
    /// One step up or down from each screen's current size.
    case step(Int)
}

/// One screen's share of the terminals, and where they go on it.
struct ScreenPlan {
    let display: Display
    let windows: [TerminalWindow]
    let plan: TilePlan
    let metrics: TerminalMetrics
    /// What to remember for this screen once the tile has gone through.
    let font: FontOption
    let placements: [WindowPlacement]
}

func byID(_ windows: [TerminalWindow]) -> [Int: TerminalWindow] {
    Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
}

/// The display showing most of a window, if any.
func display(showing frame: Rect, among displays: [Display]) -> Display? {
    displays
        .compactMap { display in frame.clipped(to: display.frame).map { (display, $0.area) } }
        .max { $0.1 < $1.1 }?.0
}

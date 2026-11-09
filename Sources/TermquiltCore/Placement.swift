/// A terminal window as its app reports it.
public struct TerminalWindow: Equatable, Sendable {
    /// The `fontSize` of a window whose app can't report one.
    public static let unknownFont = 0

    public let id: Int
    public let title: String
    public let frame: Rect
    /// Zero by zero when the app can't report it.
    public let grid: CharGrid
    public let fontSize: Int
    public let appName: String
    /// Whether another program can change this window's text size.
    public let canSetFont: Bool
    /// Whether a tab behind this one has a different text size, so a tidy has work to do even when
    /// the window is already in its slot.
    public let hasTabsAtOtherSizes: Bool

    public init(
        id: Int,
        title: String,
        frame: Rect,
        grid: CharGrid,
        fontSize: Int,
        appName: String = "Terminal",
        canSetFont: Bool = true,
        hasTabsAtOtherSizes: Bool = false
    ) {
        self.id = id
        self.title = title
        self.frame = frame
        self.grid = grid
        self.fontSize = fontSize
        self.appName = appName
        self.canSetFont = canSetFont
        self.hasTabsAtOtherSizes = hasTabsAtOtherSizes
    }

    public func withID(_ id: Int) -> TerminalWindow {
        TerminalWindow(
            id: id, title: title, frame: frame, grid: grid, fontSize: fontSize, appName: appName,
            canSetFont: canSetFont, hasTabsAtOtherSizes: hasTabsAtOtherSizes
        )
    }

    func withTabsAtOtherSizes(_ value: Bool) -> TerminalWindow {
        TerminalWindow(
            id: id, title: title, frame: frame, grid: grid, fontSize: fontSize, appName: appName,
            canSetFont: canSetFont, hasTabsAtOtherSizes: value
        )
    }
}

public enum FontAction: Equatable, Hashable, Sendable {
    /// The font is already right.
    case none
    /// The reported font differs, so set it.
    case set
    /// The window reports the target font but renders another one, because Cmd-plus zoom does not
    /// update what Terminal reports. Move the font off the target and back so the change applies.
    case refresh
}

/// Where one window should go.
public struct WindowPlacement: Equatable, Hashable, Sendable {
    public let windowID: Int
    public let frame: Rect
    public let fontSize: Int
    public let fontAction: FontAction

    public init(windowID: Int, frame: Rect, fontSize: Int, fontAction: FontAction) {
        self.windowID = windowID
        self.frame = frame
        self.fontSize = fontSize
        self.fontAction = fontAction
    }

    public func changes(_ window: TerminalWindow) -> Bool {
        fontAction != .none || frame != window.frame || window.hasTabsAtOtherSizes
    }

    public func withID(_ id: Int) -> WindowPlacement {
        WindowPlacement(windowID: id, frame: frame, fontSize: fontSize, fontAction: fontAction)
    }
}

/// Assigns each window to a cell, closest pairs first, so windows stay roughly where you left
/// them and re-tiling a tiled layout moves nothing. Expects one cell per window.
///
/// A window whose app can set a font but not report one gets it when it moves. `applyingUnknownFonts`
/// sends it anyway, for when the user has just asked for a different size.
public func assignPlacements(
    windows: [TerminalWindow],
    cells: [Rect],
    fontSize: Int,
    metrics: TerminalMetrics,
    applyingUnknownFonts: Bool = false
) -> [WindowPlacement] {
    let pairs = windows.flatMap { window in
        cells.enumerated().map { cellIndex, cell in
            (window: window, cellIndex: cellIndex, cell: cell, distance: distance(window.frame, cell))
        }
    }.sorted { left, right in
        (left.distance, left.window.id, left.cellIndex) < (right.distance, right.window.id, right.cellIndex)
    }

    var takenWindows = Set<Int>()
    var takenCells = Set<Int>()
    var placements: [WindowPlacement] = []
    for pair in pairs where !takenWindows.contains(pair.window.id) && !takenCells.contains(pair.cellIndex) {
        takenWindows.insert(pair.window.id)
        takenCells.insert(pair.cellIndex)
        placements.append(WindowPlacement(
            windowID: pair.window.id,
            frame: pair.cell,
            fontSize: fontSize,
            fontAction: fontAction(
                for: pair.window, target: pair.cell, fontSize: fontSize, metrics: metrics,
                applyingUnknownFonts: applyingUnknownFonts
            )
        ))
    }
    return placements
}

private func distance(_ first: Rect, _ second: Rect) -> Double {
    let deltaX = first.centerX - second.centerX
    let deltaY = first.centerY - second.centerY
    return deltaX * deltaX + deltaY * deltaY
}

private enum ZoomDetection {
    /// How far measured cells may stray from prediction, in points, before a window that is moving
    /// anyway gets its font refreshed. Tight, because a false alarm costs nothing visible.
    static let refreshTolerance = 0.75
    /// How far they must stray before undo trusts the cells over the reported font. Loose, because
    /// prediction is built on SF Mono and other typefaces differ by about a point.
    static let inferenceTolerance = 2.0
}

private func fontAction(
    for window: TerminalWindow,
    target: Rect,
    fontSize: Int,
    metrics: TerminalMetrics,
    applyingUnknownFonts: Bool
) -> FontAction {
    guard window.canSetFont else { return .none }
    if window.fontSize == TerminalWindow.unknownFont {
        return applyingUnknownFonts || window.frame != target ? .set : .none
    }
    guard window.fontSize == fontSize else { return .set }
    // Zooming changes a window's frame, so one already in its slot is known good. Checking only
    // windows that are moving anyway means a wrong guess can never cause a visible flicker.
    guard window.frame != target, let error = cellError(of: window, font: fontSize, metrics: metrics) else { return .none }
    return max(error.width, error.height) > ZoomDetection.refreshTolerance ? .refresh : .none
}

/// The font a window actually renders with. Cmd-plus zoom doesn't change what Terminal reports,
/// so when the window's cell size is far from its reported font, infer the font from the cells.
public func effectiveFont(of window: TerminalWindow, metrics: TerminalMetrics) -> Int {
    guard let reported = cellError(of: window, font: window.fontSize, metrics: metrics),
          max(reported.width, reported.height) >= ZoomDetection.inferenceTolerance else {
        return window.fontSize
    }
    let closest = (FontLimits.minimum...FontLimits.maximum).min { left, right in
        fontRank(left, window: window, metrics: metrics) < fontRank(right, window: window, metrics: metrics)
    }
    return closest ?? window.fontSize
}

private func fontRank(_ font: Int, window: TerminalWindow, metrics: TerminalMetrics) -> (Double, Int) {
    let error = cellError(of: window, font: font, metrics: metrics)
    return ((error?.width ?? 0) + (error?.height ?? 0), abs(font - window.fontSize))
}

/// How far a window's measured cell size is from what `font` predicts, or nil with no grid to measure.
private func cellError(of window: TerminalWindow, font: Int, metrics: TerminalMetrics) -> (width: Double, height: Double)? {
    guard window.grid.columns > 0, window.grid.rows > 0 else { return nil }
    let cellWidth = Double(window.frame.width - TerminalMetrics.chromeWidth) / Double(window.grid.columns)
    let cellHeight = Double(window.frame.height - TerminalMetrics.chromeHeight) / Double(window.grid.rows)
    return (abs(cellWidth - metrics.cellWidth(font: font)), abs(cellHeight - metrics.cellHeight(font: font)))
}

import Foundation

/// Titles and app names come from other programs, so strip control characters before printing.
func printable(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
}

/// The layout decision, plus anything the user should know about it.
struct TilePlan: Equatable {
    let layout: LayoutPlan
    /// Other apps' windows the terminals stay out of.
    let keptClear: [ScreenWindow]
    /// Other apps' windows there was no room to avoid.
    let covered: [ScreenWindow]
    let notes: [String]
}

enum RegionRules {
    /// A free region smaller than this terminal at the smallest comfortable font isn't worth using.
    static let smallestUsefulTerminal = CharGrid(columns: 40, rows: 12)

    static func smallestUsefulRegion(_ metrics: TerminalMetrics) -> Size {
        metrics.windowSize(for: smallestUsefulTerminal, font: FontLimits.autoMinimum)
    }
}

/// Some windows being kept clear of, and the layout that leaves.
private struct Attempt {
    let kept: [ScreenWindow]
    let layout: LayoutPlan
}

private enum SettlingRules {
    /// Plans settle in a pass or two. The limit only guards against an endless back and forth.
    static let maximumPasses = 5
}

/// Plans as if the terminals had already moved, because which apps count as visible depends on
/// where the terminals are. Otherwise an app the first tile only partly covers would look visible
/// to the next one and win more room, and the same hotkey would move everything twice.
///
/// After a tile the terminals are in front of whatever they overlap, since any left behind an app
/// get raised, so that's where they go in the simulated stack.
///
/// `tiledFrames` holds every terminal being arranged, on any screen, because all of them are about
/// to move. `windowCount` is how many of them this display gets.
func makeSettledTilePlan(
    windowCount: Int? = nil,
    tiledFrames: [Rect],
    windowsFrontToBack windows: [ScreenWindow],
    terminalOwners: Set<String>,
    display: Display,
    mode: LayoutMode,
    font: FontChoice,
    metrics: TerminalMetrics
) -> TilePlan {
    func plan(_ stack: [ScreenWindow]) -> TilePlan {
        makeTilePlan(
            windowCount: windowCount ?? tiledFrames.count,
            display: display,
            mode: mode,
            otherApps: otherAppWindows(windowsFrontToBack: stack, display: display.visibleFrame, ignoringOwners: terminalOwners),
            font: font,
            metrics: metrics
        )
    }
    let tiled = Set(tiledFrames)
    let bystanders = windows.filter { !terminalOwners.contains($0.owner) || !tiled.contains($0.frame) }
    // Any terminal's name will do: from here on, only the fact that it's a terminal matters.
    let simulatedOwner = terminalOwners.sorted().first ?? ""

    func settled(_ current: TilePlan, passesLeft: Int) -> TilePlan {
        guard passesLeft > 0 else { return current }
        let next = plan(current.layout.cells.map { ScreenWindow(owner: simulatedOwner, frame: $0) } + bystanders)
        return next.layout == current.layout ? next : settled(next, passesLeft: passesLeft - 1)
    }
    return settled(plan(windows), passesLeft: SettlingRules.maximumPasses)
}

/// Decides which apps keep their space, frontmost first within each group:
///
/// - An app you can see right now is worth cramped terminals: covering it is what you asked not to happen.
/// - One the terminals are covering is worth smaller text, but only down to a comfortable terminal.
/// - One hidden behind other apps must cost no text size: nobody wants twelve terminals shrunk for
///   a calendar they can't see.
///
/// The first two groups are settled at the automatic font even when a size was chosen, so pressing
/// bigger or smaller changes the text and not which apps the terminals go around.
func makeTilePlan(
    windowCount: Int,
    display: Display,
    mode: LayoutMode,
    otherApps: OtherAppWindows,
    font: FontChoice,
    metrics: TerminalMetrics
) -> TilePlan {
    let area = display.visibleFrame
    let whole = planLayout(windowCount: windowCount, regions: [area], font: font, metrics: metrics)
    guard mode == .around else {
        let note = "Using the whole screen. `termquilt --around` keeps clear of other apps instead."
        return TilePlan(layout: whole, keptClear: [], covered: [], notes: [note] + sizeNotes(for: whole, metrics: metrics))
    }

    let smallest = RegionRules.smallestUsefulRegion(metrics)
    func fit(_ regions: [Rect], _ font: FontChoice, _ minimum: CharGrid) -> LayoutPlan? {
        let layout = planLayout(windowCount: windowCount, regions: regions, font: font, metrics: metrics, minimum: minimum)
        return layout.meetsMinimum ? layout : nil
    }
    func keepingClear(_ windows: [ScreenWindow], from start: Attempt, using layout: ([Rect]) -> LayoutPlan?) -> Attempt {
        windows.reduce(start) { best, window in
            let kept = best.kept + [window]
            let regions = freeRegions(in: area, avoiding: kept.map(\.frame), minimumSize: smallest)
            guard !regions.isEmpty, let plan = layout(regions) else { return best }
            return Attempt(kept: kept, layout: plan)
        }
    }

    let nothingKept = Attempt(kept: [], layout: whole)
    let seen = keepingClear(otherApps.visible, from: nothingKept) {
        fit($0, .automatic, .readable) ?? fit($0, .fixed(FontLimits.autoMinimum), .usable)
    }
    let settled = keepingClear(otherApps.underTerminals, from: seen) { fit($0, .automatic, .readable) }
    let inView = font == .automatic
        ? settled
        : keepingClear(settled.kept, from: nothingKept) { fit($0, font, .usable) }
    let result = keepingClear(otherApps.hidden, from: inView) { regions in
        fit(regions, font, .readable).flatMap { $0.fontSize >= inView.layout.fontSize ? $0 : nil }
    }

    return describedPlan(result.layout, otherApps: otherApps, metrics: metrics)
}

/// Judges each app by where the terminals landed, because a window can end up clear without being planned for.
private func describedPlan(_ layout: LayoutPlan, otherApps: OtherAppWindows, metrics: TerminalMetrics) -> TilePlan {
    let all = otherApps.visible + otherApps.underTerminals + otherApps.hidden
    let isCovered = { (window: ScreenWindow) in layout.cells.contains { $0.intersects(window.frame) } }
    let keptClear = all.filter { !isCovered($0) }
    let covered = all.filter(isCovered)
    return TilePlan(
        layout: layout,
        keptClear: keptClear,
        covered: covered,
        notes: otherAppNotes(kept: keptClear, covered: covered) + sizeNotes(for: layout, metrics: metrics)
    )
}

private func otherAppNotes(kept: [ScreenWindow], covered: [ScreenWindow]) -> [String] {
    (kept.isEmpty ? [] : ["Keeping clear of: \(appNames(kept))"])
        + (covered.isEmpty ? [] : ["Not enough room to keep clear of: \(appNames(covered))"])
}

/// Each app once, in the order given.
private func appNames(_ windows: [ScreenWindow]) -> String {
    windows.map { printable($0.owner) }
        .reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }
        .joined(separator: ", ")
}

private func sizeNotes(for layout: LayoutPlan, metrics: TerminalMetrics) -> [String] {
    let minimum = CharGrid.readable
    guard layout.meetsMinimum else {
        return [
            "That is below the comfortable \(minimum.columns)×\(minimum.rows). "
                + "Close some windows, use a larger screen, or try a smaller font.",
        ]
    }
    let isCramped = layout.cells.contains { cell in
        let grid = metrics.grid(for: cell.size, font: layout.fontSize)
        return grid.columns < minimum.columns || grid.rows < minimum.rows
    }
    return isCramped ? ["Some terminals are under \(minimum.columns)×\(minimum.rows) so they can stay clear of other apps."] : []
}

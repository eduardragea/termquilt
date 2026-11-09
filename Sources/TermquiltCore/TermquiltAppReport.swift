/// Turning plans and results into lines for the user to read.
extension TermquiltApp {
    func describe(
        _ screens: [ScreenPlan],
        grids: [[CharGrid]],
        windows: [TerminalWindow],
        options: TileOptions,
        extra: [String]
    ) -> [String] {
        let perScreen = zip(screens, grids).flatMap { screen, grids in
            [summary(of: screen, grids: grids)] + screen.plan.notes
        }
        // On its own, an app that can't change its text size needs no explaining unless asked for.
        let controlsFont = windows.contains(where: \.canSetFont)
        let fontNotes = controlsFont || options.font != .saved ? fixedFontNotes(for: windows) : []
        return unique(perScreen + extra + fontNotes) + terminal.notes()
    }

    private func summary(of screen: ScreenPlan, grids: [CharGrid]) -> String {
        let count = screen.plan.layout.cells.count
        let font = screen.windows.contains(where: \.canSetFont) ? ", \(screen.plan.layout.fontSize) pt" : ""
        let each = grids.isEmpty ? "" : ", each \(gridSummary(grids))"
        return "\(count) terminal\(count == 1 ? "" : "s") on \(screen.display.name)\(font)\(each)"
    }

    func fixedFontNotes(for windows: [TerminalWindow]) -> [String] {
        unique(windows.filter { !$0.canSetFont }.map(\.appName))
            .map { "\($0) doesn't let other programs set its text size, so those windows kept theirs. Use ⌘+ and ⌘- there." }
    }

    func statusLine(for window: TerminalWindow) -> String {
        let frame = window.frame
        let grid = window.grid.columns > 0 ? "\(window.grid.columns)×\(window.grid.rows) at " : ""
        let font = window.fontSize == TerminalWindow.unknownFont ? window.appName : "\(window.fontSize) pt"
        return "  \(grid)\(frame.width)×\(frame.height), \(font): \(printable(window.title))"
    }

    func settingsSummary(_ preferences: Preferences, display: Display) -> String {
        let layout = preferences.layout(for: display.name) == .full ? "full screen" : "around other apps"
        let font = preferences.font(for: display.name).map { "\($0) pt" } ?? "auto"
        return "layout: \(layout), font: \(font)"
    }

    func screenChoiceSummary(_ displays: [Display], preferences: Preferences) -> String {
        guard let chosen = preferences.display(forSetup: setupKey(displays)),
              displays.contains(where: { $0.name == chosen }) else {
            return "Terminals are shared across every screen."
        }
        return "Terminals all go on \(chosen), as chosen for these screens."
    }

    func placeText(_ window: ScreenWindow) -> String {
        let frame = window.frame
        return "\(printable(window.owner)): \(frame.width)×\(frame.height) at \(frame.x),\(frame.y)"
    }

    func failureNote(_ count: Int) -> [String] {
        guard count > 0 else { return [] }
        return ["\(count) window\(count == 1 ? "" : "s") couldn't be changed (closed in the meantime?)."]
    }

    private func gridSummary(_ grids: [CharGrid]) -> String {
        "\(rangeText(grids.map(\.columns)))×\(rangeText(grids.map(\.rows)))"
    }

    private func rangeText(_ values: [Int]) -> String {
        guard let low = values.min(), let high = values.max() else { return "0" }
        return low == high ? "\(low)" : "\(low)-\(high)"
    }
}

/// "a", "a and b", "a, b and c".
func listText(_ items: [String]) -> String {
    guard let last = items.last else { return "" }
    return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
}

/// Each line once, in the order given.
func unique(_ lines: [String]) -> [String] {
    lines.reduce(into: [String]()) { kept, line in
        if !kept.contains(line) { kept.append(line) }
    }
}

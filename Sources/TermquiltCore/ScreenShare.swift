/// Shares windows out between displays in proportion to their size, so every terminal gets about
/// the same space. Windows stay on the display they're on while it has room for them. When some
/// have to move, the ones nearest the other display go.
///
/// Other apps don't change the shares. Going by the room they leave sounds kinder, but an app you
/// glance at on the laptop would then send every terminal to the monitor, which is the one-screen
/// pile this is meant to avoid. On each screen the terminals still go around apps where they can.
/// Whoever wants one screen can choose it, and that's remembered for that set of screens.
///
/// Returns one group per display, in the order given, keeping the windows' order within each.
func shareWindows(_ windows: [TerminalWindow], among displays: [Display]) -> [[TerminalWindow]] {
    guard displays.count > 1 else { return displays.map { _ in windows } }
    let distances = windows.map { window in displays.map { distanceSquared(from: window.frame, to: $0.frame) } }
    var placed = distances.map { row in row.indices.min { row[$0] < row[$1] } ?? 0 }
    // Two same-sized screens split an odd count, so the extra one goes where it already is.
    let shares = apportion(
        windows.count,
        weights: displays.map { Double($0.visibleFrame.area) },
        capacities: displays.map { _ in windows.count },
        incumbents: displays.indices.map { display in placed.filter { $0 == display }.count }
    )
    while let full = displays.indices.first(where: { display in placed.filter { $0 == display }.count > shares[display] }) {
        let open = displays.indices.filter { display in placed.filter { $0 == display }.count < shares[display] }
        let moves = placed.indices.filter { placed[$0] == full }.flatMap { window in
            open.map { target in (window: window, target: target, cost: distances[window][target] - distances[window][full]) }
        }
        guard let best = moves.min(by: { ($0.cost, windows[$0.window].id, $0.target) < ($1.cost, windows[$1.window].id, $1.target) })
        else { break }
        placed[best.window] = best.target
    }
    return displays.indices.map { display in windows.indices.filter { placed[$0] == display }.map { windows[$0] } }
}

/// Zero when the window's centre is on the display.
private func distanceSquared(from window: Rect, to display: Rect) -> Double {
    let deltaX = max(Double(display.x) - window.centerX, 0, window.centerX - Double(display.maxX))
    let deltaY = max(Double(display.y) - window.centerY, 0, window.centerY - Double(display.maxY))
    return deltaX * deltaX + deltaY * deltaY
}

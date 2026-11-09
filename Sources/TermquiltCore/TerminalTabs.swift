/// Terminal.app reports every tab as a window of its own. A window's tabs share its frame, but only
/// the selected one is on screen. Tiling each tab separately would give one window several slots,
/// and every move but the last would leave a hole.

/// The windows that are on screen now. Background tabs and windows in other Spaces are left alone,
/// but a window says when a tab behind it needs a different text size. `onScreen` is nil when the
/// system wouldn't say what's on screen, and then nothing is left out.
public func windowsOnScreen(_ windows: [TerminalWindow], onScreen: Set<Int>?) -> [TerminalWindow] {
    guard let onScreen else { return windows }
    let background = windows.filter { !onScreen.contains($0.id) }
    return windows.filter { onScreen.contains($0.id) }.map { window in
        window.withTabsAtOtherSizes(background.contains { tab in
            tab.frame == window.frame && tab.canSetFont && tab.fontSize != window.fontSize
        })
    }
}

/// Adds the background tabs behind each placed window whose text size differs, so the whole window
/// ends up at one size. They go first, so the window's own move lands last.
public func includingBackgroundTabs(
    _ placements: [WindowPlacement],
    windows: [TerminalWindow],
    onScreen: Set<Int>?
) -> [WindowPlacement] {
    guard let onScreen else { return placements }
    let current = byID(windows)
    let background = windows.filter { !onScreen.contains($0.id) }
    let start: (claimed: Set<Int>, result: [WindowPlacement]) = ([], [])
    return placements.reduce(into: start) { state, placement in
        guard let window = current[placement.windowID] else {
            state.result.append(placement)
            return
        }
        // A tab belongs to one window only, even if two windows happen to share a frame.
        let tabs = background.filter { $0.frame == window.frame && !state.claimed.contains($0.id) }
        state.claimed.formUnion(tabs.map(\.id))
        state.result += tabs
            .filter { $0.canSetFont && $0.fontSize != placement.fontSize }
            .map { WindowPlacement(windowID: $0.id, frame: placement.frame, fontSize: placement.fontSize, fontAction: .set) }
        state.result.append(placement)
    }.result
}

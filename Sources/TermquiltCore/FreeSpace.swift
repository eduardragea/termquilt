/// A window on screen, as seen from outside its app.
public struct ScreenWindow: Equatable, Sendable {
    public let owner: String
    public let frame: Rect

    public init(owner: String, frame: Rect) {
        self.owner = owner
        self.frame = frame
    }
}

/// Other apps' windows on one display, frontmost first and trimmed to that display.
public struct OtherAppWindows: Equatable, Sendable {
    /// Windows you can mostly see right now.
    public let visible: [ScreenWindow]
    /// Windows you could mostly see if the terminals weren't in the way.
    public let underTerminals: [ScreenWindow]
    /// Windows mostly hidden behind other apps.
    public let hidden: [ScreenWindow]

    public init(visible: [ScreenWindow] = [], underTerminals: [ScreenWindow] = [], hidden: [ScreenWindow] = []) {
        self.visible = visible
        self.underTerminals = underTerminals
        self.hidden = hidden
    }
}

private enum OtherAppRules {
    /// Smaller windows float over the terminals instead of carving up the screen.
    static let minimumDisplayShare = 0.05
    /// A window you can mostly see is one you are using.
    static let minimumVisibleShare = 0.5
    /// Sample points per axis when estimating how much of a window is visible.
    static let samplesPerAxis = 24
}

/// Finds the other apps termquilt should try to keep clear of. A window the terminals are covering
/// still counts, or anything they covered would lose its claim to the space for good.
public func otherAppWindows(
    windowsFrontToBack windows: [ScreenWindow],
    display: Rect,
    ignoringOwners terminalOwners: Set<String>
) -> OtherAppWindows {
    let minimumArea = Double(display.area) * OtherAppRules.minimumDisplayShare

    let found = windows.enumerated().compactMap { index, window -> (window: ScreenWindow, place: WindowPlace)? in
        guard !terminalOwners.contains(window.owner),
              let clipped = window.frame.clipped(to: display),
              Double(clipped.area) >= minimumArea else { return nil }
        // Measured on the part shown here, so a window straddling two displays keeps its visible part.
        let place = place(of: clipped, behind: windows[..<index], terminalOwners: terminalOwners)
        return (ScreenWindow(owner: window.owner, frame: clipped), place)
    }
    let windowsIn = { (place: WindowPlace) in found.filter { $0.place == place }.map(\.window) }
    return OtherAppWindows(
        visible: windowsIn(.visible),
        underTerminals: windowsIn(.underTerminals),
        hidden: windowsIn(.hidden)
    )
}

private enum WindowPlace {
    case visible, underTerminals, hidden
}

private func place(of frame: Rect, behind inFront: ArraySlice<ScreenWindow>, terminalOwners: Set<String>) -> WindowPlace {
    let isMostlyVisible = { (blockers: [ScreenWindow]) in
        visibleShare(of: frame, behind: blockers.map(\.frame)) >= OtherAppRules.minimumVisibleShare
    }
    if isMostlyVisible(Array(inFront)) { return .visible }
    return isMostlyVisible(inFront.filter { !terminalOwners.contains($0.owner) }) ? .underTerminals : .hidden
}

private func visibleShare(of frame: Rect, behind inFront: [Rect]) -> Double {
    let samples = OtherAppRules.samplesPerAxis
    let positions = (0..<samples).map { (Double($0) + 0.5) / Double(samples) }
    let visibleCount = positions.reduce(0) { total, fractionY in
        let pointY = Double(frame.y) + fractionY * Double(frame.height)
        return total + positions.filter { fractionX in
            let pointX = Double(frame.x) + fractionX * Double(frame.width)
            return !inFront.contains { $0.contains(pointX: pointX, pointY: pointY) }
        }.count
    }
    return Double(visibleCount) / Double(samples * samples)
}

/// Whether another app's window sits in front of any of these terminal frames. Moving a window
/// doesn't raise it, so a terminal can land in its slot and still be hidden.
func anyCovered(frames: Set<Rect>, windowsFrontToBack windows: [ScreenWindow], terminalOwners: Set<String>) -> Bool {
    windows.enumerated().contains { index, window in
        guard terminalOwners.contains(window.owner), frames.contains(window.frame) else { return false }
        return windows[..<index].contains { !terminalOwners.contains($0.owner) && $0.frame.intersects(window.frame) }
    }
}

/// Finds the empty rectangles on a display, largest first, then returns them left to right.
/// Each region is big enough to be useful, and regions never overlap.
public func freeRegions(in area: Rect, avoiding obstacles: [Rect], minimumSize: Size) -> [Rect] {
    let clippedObstacles = obstacles.compactMap { $0.clipped(to: area) }
    return collectRegions(in: area, blocked: clippedObstacles, minimumSize: minimumSize, found: [])
        .sorted { ($0.x, $0.y) < ($1.x, $1.y) }
}

private func collectRegions(in area: Rect, blocked: [Rect], minimumSize: Size, found: [Rect]) -> [Rect] {
    guard let next = largestEmptyRect(in: area, blocked: blocked, minimumSize: minimumSize) else {
        return found
    }
    return collectRegions(in: area, blocked: blocked + [next], minimumSize: minimumSize, found: found + [next])
}

/// Every maximal empty rectangle has its edges on an obstacle or on the area's border,
/// so trying each pair of edge coordinates is exhaustive. A screen has few enough
/// obstacles that the brute force is instant.
private func largestEmptyRect(in area: Rect, blocked: [Rect], minimumSize: Size) -> Rect? {
    let xs = Set([area.x, area.maxX] + blocked.flatMap { [$0.x, $0.maxX] }).sorted()
    let ys = Set([area.y, area.maxY] + blocked.flatMap { [$0.y, $0.maxY] }).sorted()

    var best: Rect?
    for (leftIndex, left) in xs.enumerated() {
        for right in xs[(leftIndex + 1)...] where right - left >= minimumSize.width {
            for (topIndex, top) in ys.enumerated() {
                for bottom in ys[(topIndex + 1)...] where bottom - top >= minimumSize.height {
                    let candidate = Rect(x: left, y: top, width: right - left, height: bottom - top)
                    if candidate.area > (best?.area ?? 0), !blocked.contains(where: candidate.intersects) {
                        best = candidate
                    }
                }
            }
        }
    }
    return best
}

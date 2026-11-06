/// How many window slots run across and down one region.
public struct TileGrid: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public enum FontChoice: Equatable, Sendable {
    case automatic
    case fixed(Int)
}

public struct LayoutPlan: Equatable, Sendable {
    public let fontSize: Int
    public let cells: [Rect]
    /// One entry per region that received windows.
    public let grids: [TileGrid]
    /// Whether every terminal reaches the readable minimum.
    public let meetsMinimum: Bool
}

/// Chooses the font and the window slots. All windows share one font.
///
/// Automatic sizing takes the largest font at which every terminal stays readable. When nothing
/// fits, it keeps the smallest comfortable font and lets the terminals be smaller than the
/// minimum, because tiny text is worse than a narrow terminal. A fixed font is always honoured.
public func planLayout(
    windowCount: Int,
    regions: [Rect],
    font: FontChoice,
    metrics: TerminalMetrics,
    minimum: CharGrid = .readable
) -> LayoutPlan {
    guard windowCount > 0, !regions.isEmpty else {
        return LayoutPlan(fontSize: fallbackFont(font), cells: [], grids: [], meetsMinimum: true)
    }

    let candidates: [Int]
    switch font {
    case .fixed(let size):
        candidates = [size]
    case .automatic:
        candidates = Array((FontLimits.autoMinimum...FontLimits.autoMaximum).reversed())
    }

    for size in candidates {
        let capacities = regions.map { capacity(of: $0, font: size, metrics: metrics, minimum: minimum) }
        guard capacities.reduce(0, +) >= windowCount else { continue }
        let shares = apportion(windowCount, weights: capacities.map(Double.init), capacities: capacities)
        return layout(shares: shares, regions: regions, font: size, metrics: metrics, minimum: minimum, meetsMinimum: true)
    }

    let size = fallbackFont(font)
    let shares = apportion(
        windowCount,
        weights: regions.map { Double($0.area) },
        capacities: regions.map { _ in windowCount }
    )
    return layout(shares: shares, regions: regions, font: size, metrics: metrics, minimum: minimum, meetsMinimum: false)
}

private func fallbackFont(_ font: FontChoice) -> Int {
    switch font {
    case .fixed(let size): return size
    case .automatic: return FontLimits.autoMinimum
    }
}

private func capacity(of region: Rect, font: Int, metrics: TerminalMetrics, minimum: CharGrid) -> Int {
    let smallest = metrics.windowSize(for: minimum, font: font)
    return (region.width / smallest.width) * (region.height / smallest.height)
}

private func layout(
    shares: [Int],
    regions: [Rect],
    font: Int,
    metrics: TerminalMetrics,
    minimum: CharGrid,
    meetsMinimum: Bool
) -> LayoutPlan {
    let placed = zip(shares, regions).filter { $0.0 > 0 }.map { share, region -> (TileGrid, [Rect]) in
        let grid = chooseTileGrid(count: share, in: region, font: font, metrics: metrics, minimum: minimum)
        return (grid, cells(count: share, grid: grid, in: region))
    }
    return LayoutPlan(
        fontSize: font,
        cells: placed.flatMap(\.1),
        grids: placed.map(\.0),
        meetsMinimum: meetsMinimum
    )
}

/// Splits `count` windows in proportion to `weights` without exceeding any capacity,
/// using the largest-remainder method so the shares always add up to `count`.
func apportion(_ count: Int, weights: [Double], capacities: [Int]) -> [Int] {
    let totalWeight = weights.reduce(0, +)
    guard totalWeight > 0 else { return weights.map { _ in 0 } }

    let quotas = weights.map { Double(count) * $0 / totalWeight }
    let byRemainder = quotas.indices.sorted { left, right in
        let leftRemainder = quotas[left] - quotas[left].rounded(.down)
        let rightRemainder = quotas[right] - quotas[right].rounded(.down)
        return leftRemainder == rightRemainder ? left < right : leftRemainder > rightRemainder
    }

    var shares = zip(quotas, capacities).map { min(Int($0), $1) }
    while shares.reduce(0, +) < count {
        let open = byRemainder.filter { shares[$0] < capacities[$0] }
        guard !open.isEmpty else { break }
        let missing = count - shares.reduce(0, +)
        for index in open.prefix(missing) {
            shares[index] += 1
        }
    }
    return shares
}

/// Picks the arrangement whose tightest terminal has the most headroom over the minimum.
func chooseTileGrid(count: Int, in region: Rect, font: Int, metrics: TerminalMetrics, minimum: CharGrid) -> TileGrid {
    let candidates = (1...count).map { columns in
        TileGrid(columns: columns, rows: (count + columns - 1) / columns)
    }
    let scored = candidates.map { grid -> (grid: TileGrid, headroom: Double, emptySlots: Int) in
        let slot = Size(width: region.width / grid.columns, height: region.height / grid.rows)
        let chars = metrics.grid(for: slot, font: font)
        let headroom = min(
            Double(chars.columns) / Double(minimum.columns),
            Double(chars.rows) / Double(minimum.rows)
        )
        return (grid, headroom, grid.columns * grid.rows - count)
    }
    let best = scored.min { left, right in
        left.headroom == right.headroom ? left.emptySlots < right.emptySlots : left.headroom > right.headroom
    }
    return best?.grid ?? TileGrid(columns: 1, rows: count)
}

/// Lays out `count` slots row by row with no gaps. Rows differ by at most one window,
/// and shorter rows stretch so the whole region is used.
func cells(count: Int, grid: TileGrid, in region: Rect) -> [Rect] {
    let perRow = count / grid.rows
    let rowsWithExtra = count % grid.rows
    let rows = partition(start: region.y, length: region.height, parts: grid.rows)

    return rows.enumerated().flatMap { rowIndex, row -> [Rect] in
        let windowsInRow = perRow + (rowIndex < rowsWithExtra ? 1 : 0)
        return partition(start: region.x, length: region.width, parts: windowsInRow).map { column in
            Rect(x: column.start, y: row.start, width: column.length, height: row.length)
        }
    }
}

/// Cuts a span into equal parts. Leftover pixels spread out, so the parts always sum to `length`.
private func partition(start: Int, length: Int, parts: Int) -> [(start: Int, length: Int)] {
    (0..<parts).map { index in
        let from = length * index / parts
        let to = length * (index + 1) / parts
        return (start + from, to - from)
    }
}

/// A terminal's size in characters.
public struct CharGrid: Equatable, Hashable, Codable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    /// The smallest terminal we call comfortable for an agent session.
    public static let readable = CharGrid(columns: 80, rows: 20)
    /// Cramped but workable. Having chosen a big font, you accept this before an app you can see
    /// loses its space to the terminals.
    public static let usable = CharGrid(columns: 60, rows: 15)
}

/// Font sizes in points.
public enum FontLimits {
    /// What `--font` accepts.
    public static let minimum = 6
    public static let maximum = 72
    /// The range automatic sizing picks from. Below 11 stops being comfortable to read,
    /// and above 18 a window is just wasting space that could show more text.
    public static let autoMinimum = 11
    public static let autoMaximum = 18
}

/// Predicts how many characters fit in a Terminal.app window.
///
/// Predictions only steer the layout choice; termquilt reads the real grid back after applying,
/// so being a character off on an unusual font costs nothing. The constants were measured on
/// Terminal.app with SF Mono at font sizes 9 to 24. See `TerminalMetricsTests` for the table.
public struct TerminalMetrics: Equatable, Sendable {
    /// Title bar, padding and scroller, in points.
    public static let chromeWidth = 37
    public static let chromeHeight = 48

    private static let advancePerPoint = 0.618
    private static let lineHeightPerPoint = 1.2
    private static let lineHeightPadding = 1.0

    public let scale: Int

    public init(scale: Int) {
        self.scale = max(1, scale)
    }

    public func cellWidth(font: Int) -> Double {
        snappedToPixels(Double(font) * Self.advancePerPoint)
    }

    public func cellHeight(font: Int) -> Double {
        snappedToPixels(Double(font) * Self.lineHeightPerPoint + Self.lineHeightPadding)
    }

    public func grid(for size: Size, font: Int) -> CharGrid {
        let usableWidth = Double(max(0, size.width - Self.chromeWidth))
        let usableHeight = Double(max(0, size.height - Self.chromeHeight))
        return CharGrid(
            columns: Int(usableWidth / cellWidth(font: font)),
            rows: Int(usableHeight / cellHeight(font: font))
        )
    }

    public func windowSize(for grid: CharGrid, font: Int) -> Size {
        let width = Double(grid.columns) * cellWidth(font: font)
        let height = Double(grid.rows) * cellHeight(font: font)
        return Size(
            width: Int(width.rounded(.up)) + Self.chromeWidth,
            height: Int(height.rounded(.up)) + Self.chromeHeight
        )
    }

    private func snappedToPixels(_ points: Double) -> Double {
        (points * Double(scale)).rounded() / Double(scale)
    }
}

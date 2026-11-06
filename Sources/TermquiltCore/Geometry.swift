/// A size in screen points.
public struct Size: Equatable, Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A rectangle in global screen points, origin at the top-left of the primary display.
/// This is the coordinate space Terminal's `bounds` and CGWindowList both use.
public struct Rect: Equatable, Hashable, Codable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var area: Int { width * height }
    public var size: Size { Size(width: width, height: height) }
    public var centerX: Double { Double(x) + Double(width) / 2 }
    public var centerY: Double { Double(y) + Double(height) / 2 }

    public func intersects(_ other: Rect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    public func clipped(to bounds: Rect) -> Rect? {
        let left = max(x, bounds.x)
        let top = max(y, bounds.y)
        let right = min(maxX, bounds.maxX)
        let bottom = min(maxY, bounds.maxY)
        guard right > left, bottom > top else { return nil }
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public func contains(pointX: Double, pointY: Double) -> Bool {
        pointX >= Double(x) && pointX < Double(maxX) && pointY >= Double(y) && pointY < Double(maxY)
    }
}

public extension Rect {
    /// Converts an AppKit frame (origin bottom-left of the primary display) to global top-left
    /// coordinates. Fractions round inward so a window never pokes past the usable area.
    init(appKitX: Double, appKitY: Double, width: Double, height: Double, primaryHeight: Double) {
        let left = appKitX.rounded(.up)
        let right = (appKitX + width).rounded(.down)
        let top = (primaryHeight - appKitY - height).rounded(.up)
        let bottom = (primaryHeight - appKitY).rounded(.down)
        self.init(x: Int(left), y: Int(top), width: Int(right - left), height: Int(bottom - top))
    }
}

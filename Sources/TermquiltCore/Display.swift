public struct Display: Equatable, Sendable {
    public let name: String
    public let frame: Rect
    /// The frame minus the menu bar and Dock.
    public let visibleFrame: Rect
    public let scale: Int
    public let isBuiltIn: Bool

    public init(name: String, frame: Rect, visibleFrame: Rect, scale: Int, isBuiltIn: Bool) {
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.isBuiltIn = isBuiltIn
    }
}

public enum DisplaySelector: Equatable, Sendable {
    /// The largest external monitor, or the laptop screen when there is none.
    case automatic
    case builtIn
    case external
    /// One-based, as `termquilt status` numbers them.
    case index(Int)
    /// Any part of the display's name, ignoring case.
    case name(String)

    public init(parsing text: String) {
        switch text.lowercased() {
        case "auto", "automatic":
            self = .automatic
        case "laptop", "internal", "builtin", "built-in":
            self = .builtIn
        case "external":
            self = .external
        default:
            if let index = Int(text) {
                self = .index(index)
            } else {
                self = .name(text)
            }
        }
    }
}

public func selectDisplay(_ displays: [Display], _ selector: DisplaySelector) throws(TermquiltError) -> Display {
    guard !displays.isEmpty else { throw .noDisplays }
    let names = displays.map(\.name)
    let largestExternal = displays
        .filter { !$0.isBuiltIn }
        .max { $0.frame.area < $1.frame.area }

    let selected: Display?
    let requested: String
    switch selector {
    case .automatic:
        selected = largestExternal ?? displays.first { $0.isBuiltIn } ?? displays.first
        requested = "automatic"
    case .builtIn:
        selected = displays.first { $0.isBuiltIn }
        requested = "laptop"
    case .external:
        selected = largestExternal
        requested = "external"
    case .index(let index):
        selected = displays.indices.contains(index - 1) ? displays[index - 1] : nil
        requested = String(index)
    case .name(let name):
        selected = displays.first { $0.name.localizedCaseInsensitiveContains(name) }
        requested = name
    }

    guard let selected else { throw .displayNotFound(requested: requested, available: names) }
    return selected
}

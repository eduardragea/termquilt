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
    /// The screen last chosen for this set of screens, otherwise all of them.
    case automatic
    /// Every screen, with the terminals shared out between them.
    case all
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
        case "all", "both", "every", "everywhere":
            self = .all
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

/// Names a set of connected screens, so a choice made at one desk doesn't follow you to another.
public func setupKey(_ displays: [Display]) -> String {
    displays.map(\.name).sorted().joined(separator: " + ")
}

/// The screens a tile uses. Without a choice it's every screen, unless one was chosen for this
/// set of screens before.
public func targetDisplays(
    _ displays: [Display],
    _ selector: DisplaySelector,
    preferences: Preferences
) throws(TermquiltError) -> [Display] {
    guard !displays.isEmpty else { throw .noDisplays }
    switch selector {
    case .all:
        return displays
    case .automatic:
        let chosen = preferences.display(forSetup: setupKey(displays))
        return displays.first { $0.name == chosen }.map { [$0] } ?? displays
    case .builtIn, .external, .index, .name:
        return [try selectDisplay(displays, selector)]
    }
}

/// One screen. `.automatic` and `.all` pick the largest external monitor, or the laptop screen.
public func selectDisplay(_ displays: [Display], _ selector: DisplaySelector) throws(TermquiltError) -> Display {
    guard !displays.isEmpty else { throw .noDisplays }
    let names = displays.map(\.name)
    let largestExternal = displays
        .filter { !$0.isBuiltIn }
        .max { $0.frame.area < $1.frame.area }

    let selected: Display?
    let requested: String
    switch selector {
    case .automatic, .all:
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

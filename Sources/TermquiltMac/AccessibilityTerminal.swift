import AppKit
import ApplicationServices
import TermquiltCore

/// Reads the window number macOS uses for an accessibility element. It's private API, but there's
/// no public way to get a stable ID, and window managers such as Rectangle rely on the same call.
@_silgen_name("_AXUIElementGetWindow")
private func axWindowNumber(_ element: AXUIElement, _ number: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A terminal with no window scripting, moved through the macOS Accessibility API. This needs a
/// permission the user has to turn on, for whichever app runs termquilt.
///
/// Not yet tested against the real apps. The README says so.
///
/// It never brings up the system permission prompt by itself. Someone who has kitty idling and only
/// uses Terminal shouldn't get asked on every run, so it explains what to turn on instead.
public struct AccessibilityTerminal: TerminalBackend {
    /// How an app lets another program change its text size, if it does at all.
    public enum FontControl: Sendable {
        case none
        case ghosttyScript
        case alacrittyCommand
    }

    private let name: String
    private let app: RunningApp
    private let fontControl: FontControl
    private let log = NoteLog()

    public init(name: String, bundleIdentifiers: [String], fontControl: FontControl) {
        self.name = name
        self.app = RunningApp(bundleIdentifiers: bundleIdentifiers, fallbackName: name)
        self.fontControl = fontControl
    }

    public var ownerNames: Set<String> { app.ownerNames }
    public var sessionIdentifier: String { app.session }
    public func isRunning() -> Bool { !app.instances.isEmpty }

    public func notes() -> [String] {
        let notes = log.notes
        log.notes = []
        return notes
    }

    /// Activating an app raises only some of its windows, so each one is raised as well.
    public func bringToFront() throws(TermquiltError) {
        let windows = try accessibleWindows()
        app.instances.forEach { $0.activate(options: [.activateAllWindows]) }
        windows.forEach { _ = AXUIElementPerformAction($0.element, kAXRaiseAction as CFString) }
    }

    public func listWindows() throws(TermquiltError) -> [TerminalWindow] {
        try accessibleWindows().map { window in
            // These apps don't report a character grid, so a zero grid means "unknown".
            TerminalWindow(
                id: window.id, title: window.title, frame: window.frame, grid: CharGrid(columns: 0, rows: 0),
                fontSize: TerminalWindow.unknownFont, appName: name, canSetFont: fontControl != .none
            )
        }
    }

    /// Sets the size twice because a window can't grow past the screen edge from where it is now,
    /// so the first attempt may be cut short until the move has happened.
    public func apply(_ placements: [WindowPlacement]) throws(TermquiltError) -> [Int] {
        let windows = Dictionary(try accessibleWindows().map { ($0.id, $0.element) }, uniquingKeysWith: { first, _ in first })
        let failed = placements.filter { placement in
            guard let element = windows[placement.windowID] else { return true }
            let frame = placement.frame
            let size = CGSize(width: frame.width, height: frame.height)
            _ = setSize(size, of: element)
            let moved = setPosition(CGPoint(x: frame.x, y: frame.y), of: element)
            return !(moved && setSize(size, of: element))
        }.map(\.windowID)

        if let size = placements.first(where: { $0.fontAction != .none })?.fontSize {
            changeFont(to: size, arranging: placements.count, of: windows.count)
        }
        return failed
    }

    /// These apps only offer a size for all their windows at once. So it's skipped when only some
    /// are being arranged, and a failure is only a note, because the windows have moved fine.
    private func changeFont(to size: Int, arranging: Int, of total: Int) {
        guard arranging >= total else {
            log.notes.append("\(name) can only change text size in all its windows at once, so it was left alone, because only some were being arranged.")
            return
        }
        do {
            try setFont(size)
        } catch {
            log.notes.append(TermquiltError.fontChangeFailed(app: name, detail: error.description).description)
        }
    }

    private func setFont(_ size: Int) throws(TermquiltError) {
        switch fontControl {
        case .none:
            return
        case .ghosttyScript:
            _ = try AppleScriptRunner(appName: name).run(GhosttyScript.setFont(size))
        case .alacrittyCommand:
            try runAlacritty(["msg", "config", "font.size=\(size)", "--window-id", "-1"])
        }
    }

    private func runAlacritty(_ arguments: [String]) throws(TermquiltError) {
        guard let executable = app.instances.first?.executableURL else {
            throw .fontChangeFailed(app: name, detail: "couldn't find the program")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw .fontChangeFailed(app: name, detail: error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw .fontChangeFailed(app: name, detail: "alacritty msg exited with \(process.terminationStatus)")
        }
    }

    private func accessibleWindows() throws(TermquiltError) -> [AccessibleWindow] {
        guard AXIsProcessTrusted() else { throw .accessibilityDenied(app: name) }
        return app.instances.flatMap { instance -> [AccessibleWindow] in
            let root = AXUIElementCreateApplication(instance.processIdentifier)
            // A hung terminal shouldn't freeze the hotkeys.
            AXUIElementSetMessagingTimeout(root, AccessibilityRules.messagingTimeout)
            let elements = value(of: root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            return elements.compactMap(accessibleWindow)
        }
    }

    private func accessibleWindow(from element: AXUIElement) -> AccessibleWindow? {
        guard value(of: element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              value(of: element, kAXMinimizedAttribute) as? Bool != true,
              let position = point(of: element),
              let size = size(of: element) else { return nil }
        var number: CGWindowID = 0
        guard axWindowNumber(element, &number) == .success, number != 0 else { return nil }
        return AccessibleWindow(
            id: Int(number),
            title: value(of: element, kAXTitleAttribute) as? String ?? name,
            frame: Rect(
                x: Int(position.x.rounded()),
                y: Int(position.y.rounded()),
                width: Int(size.width.rounded()),
                height: Int(size.height.rounded())
            ),
            element: element
        )
    }

    private func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func point(of element: AXUIElement) -> CGPoint? {
        guard let raw = value(of: element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        // Core Foundation types only cast this way. The check above makes it safe.
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    private func size(of element: AXUIElement) -> CGSize? {
        guard let raw = value(of: element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        // Core Foundation types only cast this way. The check above makes it safe.
        return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
    }

    private func setPosition(_ position: CGPoint, of element: AXUIElement) -> Bool {
        var copy = position
        guard let wrapped = AXValueCreate(.cgPoint, &copy) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, wrapped) == .success
    }

    private func setSize(_ size: CGSize, of element: AXUIElement) -> Bool {
        var copy = size
        guard let wrapped = AXValueCreate(.cgSize, &copy) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, wrapped) == .success
    }
}

private enum AccessibilityRules {
    static let messagingTimeout: Float = 1
}

/// Holds notes between applying a change and reporting on it.
private final class NoteLog {
    var notes: [String] = []
}

private struct AccessibleWindow {
    let id: Int
    let title: String
    let frame: Rect
    let element: AXUIElement
}

public enum TerminalApps {
    /// Every terminal termquilt knows. Add new ones at the end: an app's position is part of the
    /// window IDs saved for undo.
    public static var all: [any TerminalBackend] {
        [
            AppleTerminal(),
            ITerm2Terminal(),
            AccessibilityTerminal(name: "Ghostty", bundleIdentifiers: [GhosttyScript.bundleIdentifier], fontControl: .ghosttyScript),
            AccessibilityTerminal(name: "kitty", bundleIdentifiers: ["net.kovidgoyal.kitty"], fontControl: .none),
            AccessibilityTerminal(name: "WezTerm", bundleIdentifiers: ["com.github.wez.wezterm"], fontControl: .none),
            AccessibilityTerminal(name: "Alacritty", bundleIdentifiers: ["org.alacritty", "io.alacritty"], fontControl: .alacrittyCommand),
            AccessibilityTerminal(name: "Warp", bundleIdentifiers: ["dev.warp.Warp-Stable"], fontControl: .none),
        ]
    }
}

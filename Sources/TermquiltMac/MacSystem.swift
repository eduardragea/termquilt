import AppKit
import TermquiltCore

public struct MacDisplays: DisplayProvider {
    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    public init() {}

    public func displays() -> [Display] {
        connectToWindowServer()
        let screens = NSScreen.screens
        // The first screen is always the primary one, whose top-left is the global origin.
        guard let primary = screens.first else { return [] }
        let primaryHeight = Double(primary.frame.height)

        return screens.map { screen in
            Display(
                name: screen.localizedName,
                frame: topLeftRect(screen.frame, primaryHeight: primaryHeight),
                visibleFrame: topLeftRect(screen.visibleFrame, primaryHeight: primaryHeight),
                scale: Int(screen.backingScaleFactor.rounded()),
                isBuiltIn: isBuiltIn(screen)
            )
        }
    }

    /// Until a process has an application object, macOS reports a second screen's usable area as if
    /// it had no menu bar, and windows planned for its top edge get pushed down over the next row.
    /// Creating one adds no Dock icon to a command-line tool.
    private func connectToWindowServer() {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { _ = NSApplication.shared }
    }

    private func topLeftRect(_ frame: NSRect, primaryHeight: Double) -> Rect {
        Rect(
            appKitX: Double(frame.origin.x),
            appKitY: Double(frame.origin.y),
            width: Double(frame.width),
            height: Double(frame.height),
            primaryHeight: primaryHeight
        )
    }

    private func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[Self.screenNumberKey] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }
}

/// The height of the screen with the menu bar in Displays settings, whose corners anchor both
/// of macOS's coordinate systems.
func primaryScreenHeight() -> Int {
    Int((NSScreen.screens.first?.frame.height ?? 0).rounded())
}

/// The system's numbers for an app's windows that are on screen now. Background tabs, minimized
/// windows and windows in other Spaces aren't. Nil when the system won't say.
func onScreenWindowNumbers(of app: RunningApp) -> Set<Int>? {
    let processes = Set(app.instances.map { Int($0.processIdentifier) })
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]], !list.isEmpty else { return nil }
    return Set(list.compactMap { info -> Int? in
        guard let process = info[kCGWindowOwnerPID as String] as? Int, processes.contains(process) else { return nil }
        return info[kCGWindowNumber as String] as? Int
    })
}

public struct MacScreenWindows: ScreenWindowProvider {
    /// Normal app windows live on layer 0. Menu bar, Dock and overlays sit on other layers.
    private static let normalWindowLayer = 0

    public init() {}

    /// Reading bounds and owners needs no permission. If macOS ever returns nothing,
    /// the result is simply a tile over the whole display.
    public func windowsFrontToBack() -> [ScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap(screenWindow)
    }

    private func screenWindow(from info: [String: Any]) -> ScreenWindow? {
        guard info[kCGWindowLayer as String] as? Int == Self.normalWindowLayer,
              (info[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              let owner = info[kCGWindowOwnerName as String] as? String,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
            return nil
        }
        return ScreenWindow(
            owner: owner,
            frame: Rect(x: Int(frame.origin.x), y: Int(frame.origin.y), width: Int(frame.width), height: Int(frame.height))
        )
    }
}

public extension TermquiltApp {
    /// How long Terminal gets to finish resizing before the result is read back.
    private static var settleTime: TimeInterval { 0.1 }

    /// The app wired to the real system.
    static func live() -> TermquiltApp {
        TermquiltApp(
            terminal: CompositeTerminal(backends: TerminalApps.all),
            displays: MacDisplays(),
            screen: MacScreenWindows(),
            store: Store(directory: Store.defaultDirectory()),
            settle: { Thread.sleep(forTimeInterval: settleTime) }
        )
    }
}

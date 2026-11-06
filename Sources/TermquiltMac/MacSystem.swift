import AppKit
import TermquiltCore

public struct MacDisplays: DisplayProvider {
    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    public init() {}

    public func displays() -> [Display] {
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

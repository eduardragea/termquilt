import AppKit
import Carbon.HIToolbox
import TermquiltCore

public enum HotkeyAction: UInt32, CaseIterable, Sendable {
    case tile = 1
    case bigger
    case smaller
    case undo
    case toggleLayout

    var keyCode: Int {
        switch self {
        case .tile: return kVK_ANSI_T
        case .bigger: return kVK_ANSI_Equal
        case .smaller: return kVK_ANSI_Minus
        case .undo: return kVK_ANSI_Z
        case .toggleLayout: return kVK_ANSI_F
        }
    }

    public var label: String {
        switch self {
        case .tile: return "⌃⌥⌘T  tile all terminals"
        case .bigger: return "⌃⌥⌘=  bigger text"
        case .smaller: return "⌃⌥⌘-  smaller text"
        case .undo: return "⌃⌥⌘Z  undo"
        case .toggleLayout: return "⌃⌥⌘F  switch between around other apps and full screen"
        }
    }
}

/// Holds the global hotkeys for as long as the process runs.
///
/// You usually have no free prompt to type a command into when every terminal is busy with an
/// agent, so this is the main way to trigger a tile. Carbon hotkeys need no Accessibility permission.
@MainActor
public enum HotkeyAgent {
    /// Identifies our hotkeys to Carbon: the four-character code "TQLT".
    private static let signature: OSType = 0x5451_4C54
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    private static var app: TermquiltApp?
    private static var registered: [EventHotKeyRef] = []

    /// Registers the hotkeys and runs until the process is terminated.
    public static func run(app: TermquiltApp) throws(TermquiltError) {
        self.app = app
        NSApplication.shared.setActivationPolicy(.accessory)
        // Without a handler, registered hotkeys would swallow the keys and do nothing.
        try installHandler()
        registerHotkeys()
        guard !registered.isEmpty else { throw .noHotkeysRegistered }

        checkTerminalAccess(app)
        log("Ready. \(registered.count) hotkeys registered.")
        NSApplication.shared.run()
    }

    private static func installHandler() throws(TermquiltError) {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
            )
            guard status == noErr, let action = HotkeyAction(rawValue: identifier.id) else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { HotkeyAgent.perform(action) }
            return noErr
        }, 1, &pressed, nil, nil)
        guard status == noErr else { throw .hotkeyHandlerFailed(status: status) }
    }

    private static func registerHotkeys() {
        registered = HotkeyAction.allCases.compactMap { action in
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: signature, id: action.rawValue)
            let status = RegisterEventHotKey(
                UInt32(action.keyCode), modifiers, identifier, GetApplicationEventTarget(), 0, &reference
            )
            guard status == noErr, let reference else {
                log("Couldn't register \(action.label) (OSStatus \(status)). Another app may own it.")
                return nil
            }
            return reference
        }
    }

    /// Touching Terminal once at startup makes macOS ask for permission now,
    /// rather than the first time a hotkey is pressed.
    private static func checkTerminalAccess(_ app: TermquiltApp) {
        guard app.terminal.isRunning() else { return }
        do {
            _ = try app.terminal.listWindows()
        } catch {
            log(error.description)
        }
    }

    private static func perform(_ action: HotkeyAction) {
        guard let app else { return }
        do {
            let lines: [String]
            switch action {
            case .tile: lines = try app.tile(TileOptions())
            case .bigger: lines = try app.adjustFont(by: 1, TileOptions())
            case .smaller: lines = try app.adjustFont(by: -1, TileOptions())
            case .undo: lines = try app.undo()
            case .toggleLayout: lines = try app.toggleLayout(TileOptions())
            }
            lines.forEach(log)
        } catch {
            log(error.description)
            NSSound.beep()
        }
    }

    /// launchd sends stderr to ~/Library/Logs/termquilt.log.
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(Date().ISO8601Format()) \(message)\n".utf8))
    }
}

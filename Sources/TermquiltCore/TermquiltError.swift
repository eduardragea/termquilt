import Foundation

/// Inside Codex's sandbox macOS hides other apps, so termquilt would wrongly report that no terminal
/// is running. Codex sets this variable there, which allows saying what's really wrong.
///
/// Programs inherit the variable, so a long-lived one started from the sandbox, like a tmux server,
/// can pass it on to shells that aren't sandboxed at all. Hence the override.
public func sandboxProblem(environment: [String: String]) -> TermquiltError? {
    guard environment["TERMQUILT_IGNORE_SANDBOX"] == nil,
          let sandbox = environment["CODEX_SANDBOX"], !sandbox.isEmpty else { return nil }
    return .insideCodexSandbox
}

public enum TermquiltError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case terminalNotRunning
    case insideCodexSandbox
    case automationDenied(app: String)
    case accessibilityDenied(app: String)
    case fontChangeFailed(app: String, detail: String)
    case noDisplays
    case displayNotFound(requested: String, available: [String])
    case invalidFont(String)
    case malformedWindowList(String)
    case appleScriptFailed(code: Int, message: String)
    case corruptFile(path: String, reason: String)
    case fileWriteFailed(path: String, reason: String)
    case launchAgentFailed(String)
    case noHotkeysRegistered
    case hotkeyHandlerFailed(status: Int32)

    public var description: String {
        switch self {
        case .terminalNotRunning:
            return "No supported terminal is running, so there is nothing to arrange. "
                + "termquilt works with Terminal, iTerm2, Ghostty, kitty, WezTerm, Alacritty and Warp."
        case .insideCodexSandbox:
            return """
            termquilt can't work inside Codex's sandbox, because the sandbox blocks controlling other apps.
            Run it outside the sandbox by approving it when Codex asks. To stop being asked, add this line to ~/.codex/rules/default.rules:
              prefix_rule(pattern=["termquilt"], decision="allow")
            If you aren't in Codex's sandbox and still see this, set TERMQUILT_IGNORE_SANDBOX=1.
            """
        case .automationDenied(let app):
            return """
            macOS blocked termquilt from controlling \(app).
            Allow it in System Settings > Privacy & Security > Automation, then try again.
            """
        case .accessibilityDenied(let app):
            return """
            To move \(app) windows, macOS needs you to give Accessibility permission to the app running termquilt.
            Turn it on in System Settings > Privacy & Security > Accessibility (add it with + if it isn't listed), then try again.
            """
        case .fontChangeFailed(let app, let detail):
            return "Couldn't change the text size in \(app): \(detail)"
        case .noDisplays:
            return "macOS reported no displays."
        case .displayNotFound(let requested, let available):
            return "No display matches \"\(requested)\". Available: \(available.joined(separator: ", "))."
        case .invalidFont(let text):
            return "\"\(text)\" isn't a font size. Use \"auto\" or a number from \(FontLimits.minimum) to \(FontLimits.maximum)."
        case .malformedWindowList(let detail):
            return "Terminal returned a window list termquilt can't read: \(detail)"
        case .appleScriptFailed(let code, let message):
            return "Talking to Terminal failed (\(code)): \(message)"
        case .corruptFile(let path, let reason):
            return "Can't read \(path): \(reason). Fix or delete the file and try again."
        case .fileWriteFailed(let path, let reason):
            return "Can't write \(path): \(reason)"
        case .launchAgentFailed(let detail):
            return "Couldn't set up the hotkey agent: \(detail)"
        case .noHotkeysRegistered:
            return "None of the hotkeys could be registered."
        case .hotkeyHandlerFailed(let status):
            return "Couldn't listen for hotkeys (OSStatus \(status))."
        }
    }

    public var errorDescription: String? { description }
}

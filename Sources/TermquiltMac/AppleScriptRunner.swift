import AppKit
import TermquiltCore

/// Runs AppleScript aimed at one app, and turns its failures into errors that name that app.
struct AppleScriptRunner {
    private static let notAuthorizedError = -1743
    private static let appNotRunningError = -600

    let appName: String

    func run(_ source: String) throws(TermquiltError) -> String {
        guard let script = NSAppleScript(source: source) else {
            throw .appleScriptFailed(code: 0, message: "script failed to compile")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw mapError(errorInfo)
        }
        return result.stringValue ?? ""
    }

    private func mapError(_ info: NSDictionary) -> TermquiltError {
        let code = info[NSAppleScript.errorNumber] as? Int ?? 0
        switch code {
        case Self.notAuthorizedError:
            return .automationDenied(app: appName)
        case Self.appNotRunningError:
            return .terminalNotRunning
        default:
            return .appleScriptFailed(code: code, message: info[NSAppleScript.errorMessage] as? String ?? "unknown error")
        }
    }
}

/// The running copies of one app, found by bundle identifier.
struct RunningApp {
    let bundleIdentifiers: [String]
    let fallbackName: String

    var instances: [NSRunningApplication] {
        bundleIdentifiers.flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
    }

    /// The window list uses the localized app name, so ask macOS rather than assume English.
    var ownerNames: Set<String> {
        Set(instances.map { $0.localizedName ?? fallbackName })
    }

    /// Identifies this run of the app. Changes when it relaunches.
    var session: String {
        guard let instance = instances.first else { return "" }
        let launched = instance.launchDate?.timeIntervalSince1970 ?? 0
        return "\(instance.processIdentifier)-\(launched)"
    }
}

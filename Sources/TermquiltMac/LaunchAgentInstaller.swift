import Foundation
import TermquiltCore

/// Installs the launchd job that starts the hotkey agent at login.
public struct LaunchAgentInstaller {
    private static let launchctlPath = "/bin/launchctl"
    /// launchd tears a job down in the background, so `bootout` returning doesn't mean it's gone.
    private static let pollInterval: TimeInterval = 0.25
    private static let pollAttempts = 20
    private static let bootstrapAttempts = 3

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var plistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(LaunchAgentPlist.label).plist")
    }
    private var logURL: URL {
        home.appendingPathComponent("Library/Logs/termquilt.log")
    }
    private var domainTarget: String { "gui/\(getuid())" }
    private var serviceTarget: String { "\(domainTarget)/\(LaunchAgentPlist.label)" }

    public init() {}

    public func install() throws(TermquiltError) -> [String] {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            throw .launchAgentFailed("can't tell where the termquilt binary is")
        }
        let contents = LaunchAgentPlist.contents(executablePath: executable, logPath: logURL.path)
        try writePlist(contents)
        try stopAgent()
        try startAgent()

        let keys = HotkeyAction.allCases.map { "  \($0.label)" }
        let buildWarning = executable.contains("/.build/")
            ? ["Warning: this points at a build folder and will break if that's cleaned. Prefer `make install`."]
            : []
        return ["Hotkeys are on and will start at login:"] + keys + buildWarning + [
            "macOS may ask to let termquilt control your terminal. Allow it.",
            "Log: \(logURL.path)",
        ]
    }

    public func uninstall() throws(TermquiltError) -> [String] {
        let wasInstalled = FileManager.default.fileExists(atPath: plistURL.path)
        let wasRunning = isAgentLoaded()
        try stopAgent()
        if wasInstalled {
            do {
                try FileManager.default.removeItem(at: plistURL)
            } catch {
                throw .launchAgentFailed("the hotkeys are off, but \(plistURL.path) remains: \(error.localizedDescription)")
            }
        }
        return [wasInstalled || wasRunning ? "Hotkeys removed." : "Hotkeys weren't installed."]
    }

    private func isAgentLoaded() -> Bool {
        launchctl(["print", serviceTarget]).status == 0
    }

    private func stopAgent() throws(TermquiltError) {
        guard isAgentLoaded() else { return }
        let result = launchctl(["bootout", serviceTarget])
        var attempts = 0
        while isAgentLoaded() {
            guard attempts < Self.pollAttempts else {
                throw .launchAgentFailed("the running agent wouldn't stop: \(result.output)")
            }
            attempts += 1
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
    }

    private func startAgent() throws(TermquiltError) {
        var lastResult = launchctl(["bootstrap", domainTarget, plistURL.path])
        for _ in 1..<Self.bootstrapAttempts where lastResult.status != 0 {
            Thread.sleep(forTimeInterval: Self.pollInterval)
            lastResult = launchctl(["bootstrap", domainTarget, plistURL.path])
        }
        guard lastResult.status == 0 else {
            let detail = lastResult.output.isEmpty ? "launchctl exited with \(lastResult.status)" : lastResult.output
            throw .launchAgentFailed("the hotkeys aren't running right now: \(detail)")
        }
    }

    private func writePlist(_ contents: [String: Any]) throws(TermquiltError) {
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            throw .launchAgentFailed(error.localizedDescription)
        }
    }

    private func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.launchctlPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}

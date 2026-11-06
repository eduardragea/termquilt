/// Makes several terminal apps look like one, so all their windows go into the same grid.
///
/// Each app numbers its own windows, so IDs are moved into a separate range per app. An app's range
/// comes from its position in `backends`, which keeps a window's ID stable as other apps open and
/// close. That position is saved in undo files, so new apps belong at the end of the list.
///
/// One app refusing to cooperate, usually for lack of a macOS permission, doesn't stop the others.
/// The problem comes back through `notes()` instead.
public final class CompositeTerminal: TerminalBackend {
    /// Far above any real window ID, which macOS keeps within 32 bits.
    private static let idRange = 1 << 40

    private let backends: [any TerminalBackend]
    private var listFailures: [TermquiltError] = []
    private var applyFailures: [TermquiltError] = []

    public init(backends: [any TerminalBackend]) {
        self.backends = backends
    }

    private var running: [(slot: Int, backend: any TerminalBackend)] {
        backends.enumerated().compactMap { slot, backend in
            backend.isRunning() ? (slot, backend) : nil
        }
    }

    public var ownerNames: Set<String> {
        Set(running.flatMap(\.backend.ownerNames))
    }

    public var sessionIdentifier: String {
        running.map { "\($0.slot):\($0.backend.sessionIdentifier)" }.joined(separator: ",")
    }

    public func isRunning() -> Bool {
        !running.isEmpty
    }

    /// The windows have already moved by now, so one app refusing mustn't lose that for the rest.
    public func bringToFront() throws(TermquiltError) {
        let apps = running
        var failures: [TermquiltError] = []
        for app in apps {
            do {
                try app.backend.bringToFront()
            } catch {
                failures.append(error)
            }
        }
        applyFailures += failures
        if let first = failures.first, failures.count == apps.count {
            throw first
        }
    }

    /// True unless an app from the saved session has since quit or restarted. Another terminal
    /// opening doesn't matter, because it can't have any of the saved windows.
    public func matchesSession(_ saved: String) -> Bool {
        let current = Set(sessionIdentifier.split(separator: ","))
        return saved.split(separator: ",").allSatisfy(current.contains)
    }

    public func listWindows() throws(TermquiltError) -> [TerminalWindow] {
        let apps = running
        var windows: [TerminalWindow] = []
        var failures: [TermquiltError] = []
        for app in apps {
            do {
                windows += try app.backend.listWindows().map { $0.withID($0.id + app.slot * Self.idRange) }
            } catch {
                failures.append(error)
            }
        }
        listFailures = failures
        if let first = failures.first, failures.count == apps.count {
            throw first
        }
        return windows
    }

    public func apply(_ placements: [WindowPlacement]) throws(TermquiltError) -> [Int] {
        let bySlot = Dictionary(grouping: placements) { $0.windowID / Self.idRange }
        var failedIDs: [Int] = []
        var failures: [TermquiltError] = []
        for (slot, group) in bySlot.sorted(by: { $0.key < $1.key }) where backends.indices.contains(slot) {
            do {
                let failed = try backends[slot].apply(group.map { $0.withID($0.windowID % Self.idRange) })
                failedIDs += failed.map { $0 + slot * Self.idRange }
            } catch {
                failures.append(error)
                failedIDs += group.map(\.windowID)
            }
        }
        applyFailures = failures
        if let first = failures.first, failures.count == bySlot.count {
            throw first
        }
        return failedIDs
    }

    /// Each problem is reported once. Hotkeys keep this object alive for days, so a problem from an
    /// earlier press mustn't reappear after it's been fixed.
    public func notes() -> [String] {
        let failures = listFailures + applyFailures
        listFailures = []
        applyFailures = []
        let all = failures.map(\.description) + running.flatMap { $0.backend.notes() }
        return all.reduce(into: [String]()) { notes, note in
            if !notes.contains(note) { notes.append(note) }
        }
    }
}

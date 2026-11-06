import Testing
@testable import TermquiltCore

/// Repeatable random numbers, so a failure here can be replayed. This is SplitMix64.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        let first = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
        let second = (first ^ (first >> 27)) &* 0x94D0_49BB_1331_11EB
        return second ^ (second >> 31)
    }
}

/// One press of the hotkey has to finish the job: the next press, with nothing else changed, moves nothing.
@Suite struct SettledPlanTests {
    let odyssey = Display(
        name: "Odyssey", frame: Rect(x: 0, y: 0, width: 5120, height: 1440),
        visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1332), scale: 1, isBuiltIn: false
    )
    let metrics = TerminalMetrics(scale: 1)

    func settled(_ tiled: [Rect], stack: [ScreenWindow], font: FontChoice = .automatic) -> TilePlan {
        makeSettledTilePlan(
            tiledFrames: tiled, windowsFrontToBack: stack, terminalOwners: ["Terminal"],
            display: odyssey, mode: .around, font: font, metrics: metrics
        )
    }

    func terminal(_ frame: Rect) -> ScreenWindow {
        ScreenWindow(owner: "Terminal", frame: frame)
    }

    /// The stack after a tile: terminals in their new slots and in front, everything else where it was.
    func stack(after plan: TilePlan, tiled: [Rect], before: [ScreenWindow]) -> [ScreenWindow] {
        let moved = Set(tiled)
        return plan.layout.cells.map(terminal) + before.filter { $0.owner != "Terminal" || !moved.contains($0.frame) }
    }

    func randomFrame(_ generator: inout SeededGenerator) -> Rect {
        Rect(
            x: Int.random(in: 0...3800, using: &generator),
            y: Int.random(in: 30...800, using: &generator),
            width: Int.random(in: 300...2400, using: &generator),
            height: Int.random(in: 250...1250, using: &generator)
        )
    }

    @Test func anAppThatWouldEndUpPartlyCoveredGetsItsRoomOnTheFirstPress() {
        let apps = [
            ScreenWindow(owner: "A0", frame: Rect(x: 2804, y: 572, width: 1822, height: 649)),
            ScreenWindow(owner: "A1", frame: Rect(x: 1171, y: 420, width: 2295, height: 770)),
            ScreenWindow(owner: "A2", frame: Rect(x: 29, y: 30, width: 2330, height: 1032)),
            ScreenWindow(owner: "A3", frame: Rect(x: 575, y: 104, width: 927, height: 985)),
        ]
        let frames = [
            Rect(x: 1315, y: 638, width: 670, height: 602), Rect(x: 4134, y: 326, width: 924, height: 505),
            Rect(x: 2892, y: 279, width: 1024, height: 472), Rect(x: 4311, y: 161, width: 620, height: 300),
            Rect(x: 1050, y: 305, width: 764, height: 592), Rect(x: 222, y: 545, width: 1104, height: 345),
            Rect(x: 4083, y: 90, width: 591, height: 562), Rect(x: 1153, y: 403, width: 976, height: 642),
            Rect(x: 3167, y: 420, width: 506, height: 382), Rect(x: 2618, y: 205, width: 935, height: 386),
        ]
        let result = settled(frames, stack: frames.map(terminal) + apps)
        #expect(result.keptClear.map(\.owner).contains("A1"))
        #expect(!result.layout.cells.contains { $0.intersects(apps[1].frame) })
    }

    @Test func aTerminalOutsideTheMatchStillCoversWhatItCovers() {
        // The same desktop as above, except a terminal that isn't being arranged sits over A1 and
        // stays there. A1 therefore never becomes visible, so it doesn't earn cramped terminals.
        let apps = [
            ScreenWindow(owner: "A0", frame: Rect(x: 2804, y: 572, width: 1822, height: 649)),
            ScreenWindow(owner: "A1", frame: Rect(x: 1171, y: 420, width: 2295, height: 770)),
            ScreenWindow(owner: "A2", frame: Rect(x: 29, y: 30, width: 2330, height: 1032)),
            ScreenWindow(owner: "A3", frame: Rect(x: 575, y: 104, width: 927, height: 985)),
        ]
        let frames = [
            Rect(x: 1315, y: 638, width: 670, height: 602), Rect(x: 4134, y: 326, width: 924, height: 505),
            Rect(x: 2892, y: 279, width: 1024, height: 472), Rect(x: 4311, y: 161, width: 620, height: 300),
            Rect(x: 1050, y: 305, width: 764, height: 592), Rect(x: 222, y: 545, width: 1104, height: 345),
            Rect(x: 4083, y: 90, width: 591, height: 562), Rect(x: 1153, y: 403, width: 976, height: 642),
            Rect(x: 3167, y: 420, width: 506, height: 382), Rect(x: 2618, y: 205, width: 935, height: 386),
        ]
        let bystander = terminal(apps[1].frame)
        let result = settled(frames, stack: frames.map(terminal) + [bystander] + apps)
        #expect(result.covered.map(\.owner).contains("A1"))
    }

    @Test func aDesktopThatIsAlreadySettledPlansTheSameAsBefore() {
        let browser = ScreenWindow(owner: "Browser", frame: Rect(x: 1671, y: 30, width: 1975, height: 1252))
        let frames = (0..<12).map { Rect(x: $0 * 20, y: 30, width: 600, height: 400) }
        let stack = [browser] + frames.map(terminal)
        let once = makeTilePlan(
            windowCount: 12, display: odyssey, mode: .around,
            otherApps: otherAppWindows(windowsFrontToBack: stack, display: odyssey.visibleFrame, ignoringOwners: ["Terminal"]),
            font: .automatic, metrics: metrics
        )
        #expect(settled(frames, stack: stack) == once)
    }

    @Test(arguments: [FontChoice.automatic, .fixed(12), .fixed(15), .fixed(18)])
    func aSecondPressMovesNothingOnRandomDesktops(font: FontChoice) {
        var generator = SeededGenerator(state: 2026)
        for caseNumber in 0..<250 {
            let apps = (0..<Int.random(in: 1...6, using: &generator)).map { index in
                ScreenWindow(owner: "App \(index)", frame: randomFrame(&generator))
            }
            let tiled = (0..<Int.random(in: 1...14, using: &generator)).map { _ in randomFrame(&generator) }
            // Terminals left out of a --match stay where they are, in the stack and on screen.
            let bystanders = (0..<Int.random(in: 0...3, using: &generator)).map { _ in randomFrame(&generator) }
            let before = (apps + (tiled + bystanders).map(terminal)).shuffled(using: &generator)

            let first = settled(tiled, stack: before, font: font)
            let second = settled(first.layout.cells, stack: stack(after: first, tiled: tiled, before: before), font: font)
            #expect(second.layout == first.layout, "case \(caseNumber)")
        }
    }
}

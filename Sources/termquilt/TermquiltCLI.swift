import ArgumentParser
import TermquiltCore
import TermquiltMac

@main
struct TermquiltCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "termquilt",
        abstract: "Arrange every terminal window into a tidy grid with one readable font.",
        version: "0.1.0",
        subcommands: [Tile.self, Bigger.self, Smaller.self, Undo.self, Status.self, Hotkeys.self],
        defaultSubcommand: Tile.self
    )
}

enum LayoutFlag: String, EnumerableFlag {
    case around
    case full

    static func help(for value: LayoutFlag) -> ArgumentHelp? {
        switch value {
        case .around: return "Go around other apps when there's room (the default). Remembered per display."
        case .full: return "Use the whole screen, over other apps. Remembered per display."
        }
    }

    var mode: LayoutMode {
        switch self {
        case .around: return .around
        case .full: return .full
        }
    }
}

struct TargetFlags: ParsableArguments {
    @Option(help: "Where to put the terminals: laptop, external, a number from `status`, or part of a name.")
    var display: String?

    @Flag var layout: LayoutFlag?

    @Option(help: "Only arrange windows whose title contains this text.")
    var match: String?

    @Flag(help: "Show what would happen without changing anything.")
    var dryRun = false

    func options(font: FontOption = .saved) -> TileOptions {
        TileOptions(
            font: font,
            layout: layout?.mode,
            display: display.map(DisplaySelector.init(parsing:)) ?? .automatic,
            match: match,
            dryRun: dryRun
        )
    }
}

func printLines(_ lines: [String]) {
    lines.forEach { print($0) }
}

struct Tile: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fill the free space on a display with every terminal window (the default command)."
    )

    @Option(help: "Font size in points, remembered per display. Use \"auto\" to fit automatically again.")
    var font: String?

    @OptionGroup var target: TargetFlags

    func run() throws {
        let fontOption = try font.map { (text: String) throws -> FontOption in try FontOption(parsing: text) } ?? .saved
        printLines(try TermquiltApp.live().tile(target.options(font: fontOption)))
    }
}

struct Bigger: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Make the text one point bigger everywhere and re-tile.")

    @OptionGroup var target: TargetFlags

    func run() throws {
        printLines(try TermquiltApp.live().adjustFont(by: 1, target.options()))
    }
}

struct Smaller: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Make the text one point smaller everywhere and re-tile.")

    @OptionGroup var target: TargetFlags

    func run() throws {
        printLines(try TermquiltApp.live().adjustFont(by: -1, target.options()))
    }
}

struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Go back to the layout before the last change. Run again to redo.")

    func run() throws {
        printLines(try TermquiltApp.live().undo())
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List displays, their saved settings, terminal windows, and which apps a tile would avoid."
    )

    @Option(help: "Report for this display: laptop, external, a number, or part of a name.")
    var display: String?

    @Option(help: "Only count windows whose title contains this text.")
    var match: String?

    func run() throws {
        let options = TileOptions(
            display: display.map(DisplaySelector.init(parsing:)) ?? .automatic,
            match: match
        )
        printLines(try TermquiltApp.live().status(options))
    }
}

struct Hotkeys: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the global hotkeys.",
        subcommands: [Install.self, Uninstall.self, Run.self]
    )

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn on the hotkeys and start them at login.")

        func run() throws {
            printLines(try LaunchAgentInstaller().install())
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn off the hotkeys.")

        func run() throws {
            printLines(try LaunchAgentInstaller().uninstall())
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Hold the hotkeys in the foreground. launchd runs this for you after `install`."
        )

        func run() throws {
            try MainActor.assumeIsolated {
                try HotkeyAgent.run(app: TermquiltApp.live())
            }
        }
    }
}

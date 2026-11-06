/// AppleScript for Terminal.app, and parsing of what it returns.
///
/// Generated scripts only ever interpolate integers, so window titles and other
/// outside text can never end up in script source.
public enum TerminalScript {
    fileprivate static let unitSeparator: Character = "\u{1F}"
    fileprivate static let recordSeparator: Character = "\u{1E}"
    fileprivate static let fieldCount = 9

    /// Lists visible, non-minimized windows. Settings and other non-terminal
    /// windows have no selected tab, so the `try` skips exactly those.
    public static let list = """
    tell application "Terminal"
    	set unitSep to character id 31
    	set recordSep to character id 30
    	set windowLines to {}
    	repeat with w in windows
    		try
    			if (visible of w) and not (miniaturized of w) then
    				set t to selected tab of w
    				set b to bounds of w
    				set end of windowLines to (id of w as text) & unitSep & (item 1 of b as text) & unitSep & (item 2 of b as text) & unitSep & (item 3 of b as text) & unitSep & (item 4 of b as text) & unitSep & (number of columns of t as text) & unitSep & (number of rows of t as text) & unitSep & ((font size of t) as integer as text) & unitSep & (name of w)
    			end if
    		end try
    	end repeat
    	set AppleScript's text item delimiters to recordSep
    	return windowLines as text
    end tell
    """

    /// Raises every Terminal window above other apps. Tested against the alternative:
    /// `NSRunningApplication.activate(options: .activateAllWindows)` raised only one of twelve.
    public static let activate = #"tell application "Terminal" to activate"#

    /// Applies placements and returns the IDs of any windows that could not be
    /// changed, usually because they closed in the meantime.
    public static func apply(_ placements: [WindowPlacement]) -> String {
        """
        tell application "Terminal"
        	set failed to {}
        \(placements.map(applyBlock).joined(separator: "\n"))
        	set AppleScript's text item delimiters to ","
        	return failed as text
        end tell
        """
    }

    /// The font goes first: changing it resizes the window to keep its character
    /// grid, so setting the bounds any earlier would be undone.
    private static func applyBlock(_ placement: WindowPlacement) -> String {
        let frame = placement.frame
        return """
        	try
        		set w to window id \(placement.windowID)
        \(fontLines(placement))		set bounds of w to {\(frame.x), \(frame.y), \(frame.maxX), \(frame.maxY)}
        	on error
        		set end of failed to \(placement.windowID)
        	end try
        """
    }

    private static func fontLines(_ placement: WindowPlacement) -> String {
        let sizes: [Int]
        switch placement.fontAction {
        case .none:
            return ""
        case .set:
            sizes = [placement.fontSize]
        case .refresh:
            let nudged = placement.fontSize < FontLimits.maximum ? placement.fontSize + 1 : placement.fontSize - 1
            sizes = [nudged, placement.fontSize]
        }
        let setters = sizes.map { "\t\t\tset font size of t to \($0)\n" }.joined()
        return "\t\trepeat with t in tabs of w\n\(setters)\t\tend repeat\n"
    }
}

public func parseWindowList(_ raw: String) throws(TermquiltError) -> [TerminalWindow] {
    var windows: [TerminalWindow] = []
    for record in raw.split(separator: TerminalScript.recordSeparator) {
        windows.append(try parseWindowRecord(record))
    }
    return windows
}

private func parseWindowRecord(_ record: Substring) throws(TermquiltError) -> TerminalWindow {
    let fields = record.split(
        separator: TerminalScript.unitSeparator,
        maxSplits: TerminalScript.fieldCount - 1,
        omittingEmptySubsequences: false
    )
    guard fields.count == TerminalScript.fieldCount else {
        throw .malformedWindowList("expected \(TerminalScript.fieldCount) fields, got \(fields.count)")
    }
    let numbers = fields.dropLast().compactMap { Int($0) }
    guard numbers.count == TerminalScript.fieldCount - 1 else {
        throw .malformedWindowList("non-numeric field in window record")
    }

    let (left, top, right, bottom) = (numbers[1], numbers[2], numbers[3], numbers[4])
    guard right > left, bottom > top else {
        throw .malformedWindowList("window \(numbers[0]) has empty bounds")
    }
    return TerminalWindow(
        id: numbers[0],
        title: String(fields[TerminalScript.fieldCount - 1]),
        frame: Rect(x: left, y: top, width: right - left, height: bottom - top),
        grid: CharGrid(columns: numbers[5], rows: numbers[6]),
        fontSize: numbers[7]
    )
}

public func parseFailedIDs(_ raw: String) -> [Int] {
    raw.split(separator: ",").compactMap { Int($0.trimmingPrefix(" ")) }
}

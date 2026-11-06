/// AppleScript for iTerm2, which can move its windows but has no way to set a font from a script.
///
/// As with Terminal, generated scripts only ever interpolate integers.
public enum ITermScript {
    public static let bundleIdentifier = "com.googlecode.iterm2"

    /// Skips hotkey windows, which slide in and out on their own and don't belong in a grid. The
    /// `0` is the font field, which iTerm2 has no way to report.
    public static let list = """
    tell application id "\(bundleIdentifier)"
    	set unitSep to character id 31
    	set recordSep to character id 30
    	set windowLines to {}
    	repeat with w in windows
    		try
    			if (visible of w) and not (miniaturized of w) and not (is hotkey window of w) then
    				set s to current session of w
    				set b to bounds of w
    				set end of windowLines to (id of w as text) & unitSep & (item 1 of b as text) & unitSep & (item 2 of b as text) & unitSep & (item 3 of b as text) & unitSep & (item 4 of b as text) & unitSep & (columns of s as text) & unitSep & (rows of s as text) & unitSep & "\(TerminalWindow.unknownFont)" & unitSep & (name of w)
    			end if
    		end try
    	end repeat
    	set AppleScript's text item delimiters to recordSep
    	return windowLines as text
    end tell
    """

    public static let activate = #"tell application id "\#(bundleIdentifier)" to activate"#

    public static func apply(_ placements: [WindowPlacement]) -> String {
        let blocks = placements.map { placement -> String in
            let frame = placement.frame
            return """
            	try
            		set bounds of window id \(placement.windowID) to {\(frame.x), \(frame.y), \(frame.maxX), \(frame.maxY)}
            	on error
            		set end of failed to \(placement.windowID)
            	end try
            """
        }
        return """
        tell application id "\(bundleIdentifier)"
        	set failed to {}
        \(blocks.joined(separator: "\n"))
        	set AppleScript's text item delimiters to ","
        	return failed as text
        end tell
        """
    }
}

public func parseITermWindowList(_ raw: String, appName: String) throws(TermquiltError) -> [TerminalWindow] {
    try parseWindowList(raw).map { window in
        TerminalWindow(
            id: window.id, title: window.title, frame: window.frame, grid: window.grid,
            fontSize: TerminalWindow.unknownFont, appName: appName, canSetFont: false
        )
    }
}

/// AppleScript for Ghostty 1.3 and newer. It can set a font on a terminal but can't report one, and
/// it has no way to move a window.
public enum GhosttyScript {
    public static let bundleIdentifier = "com.mitchellh.ghostty"

    public static func setFont(_ size: Int) -> String {
        """
        tell application id "\(bundleIdentifier)"
        	repeat with t in terminals
        		perform action "set_font_size:\(size)" on t
        	end repeat
        end tell
        """
    }
}

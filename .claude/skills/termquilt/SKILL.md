---
name: termquilt
description: Arranges the user's terminal windows and changes their text size when they ask in plain words, on macOS, in Terminal, iTerm2, Ghostty, kitty, WezTerm, Alacritty and Warp. Use for requests like "tidy my terminals", "raise the font", "make the text bigger", "smaller", "fill the screen", "don't cover my apps", "go around Safari", "move them to my other monitor", "put them back", or any complaint that terminals are messy, overlapping or hard to read. Also use for follow-ups to these, like "a bit more" or "undo that".
allowed-tools: Bash(termquilt) Bash(termquilt *) Bash(~/.local/bin/termquilt) Bash(~/.local/bin/termquilt *)
---

# termquilt

The user talks, you run `termquilt`, and you tell them what changed in plain words.

Moving windows is harmless and one step from undone, so act right away. Don't ask first and don't preview, unless they ask what something would do.

Two rules keep this free of permission prompts, which is the whole point:

- **Invoke this skill on every request, including follow-ups like "a bit more".** Even if you ran it a moment ago, invoke it again before running `termquilt`, because its permission ends with each turn.
- **Run each command exactly as written below, on its own.** Adding `2>&1`, `||`, `;`, pipes or `echo` needs approval, and so does checking for the program first with `ls` or `which`. Just run it.

## What they say, what to run

| They say | Run |
|---|---|
| "tidy my terminals", "arrange them", "clean this up" | `termquilt` |
| "raise the font", "bigger", "I can't read this" | `termquilt bigger` |
| "lower the font", "smaller", "fit more on screen" | `termquilt smaller` |
| "much bigger", "a lot smaller" | `termquilt status` for the current size, then `termquilt --font N`, 3 pt away |
| "make it 16" | `termquilt --font 16` |
| "choose the size for me" | `termquilt --font auto` |
| "don't cover my apps", "go around Safari" | `termquilt --around` |
| "fill the screen", "ignore my other apps" | `termquilt --full` |
| "put them on my laptop", "on the big monitor" | `termquilt --display laptop`, `--display external`, or part of a name from `termquilt status` |
| "only the claude ones" | `termquilt --match claude`. The others stay where they are and may end up covered |
| "put them back", "undo that" | `termquilt undo` |
| "what would that do?" | The same command with `--dry-run`. `undo` and `hotkeys` have no preview, so say what they'd do instead |
| "turn on the hotkeys" | `termquilt hotkeys install` |
| "stop asking me for permission" | Add `"Bash(termquilt *)"` to `permissions.allow` in `~/.claude/settings.json`, keeping everything already there |

For "a bit more" or "too far", repeat or reverse the last change.

`--around`, `--full` and `--font` are remembered for that display. `--display` and `--match` apply to one run only.

## How to reply

One or two lines. Say the text size and how many terminals, and name any app that got covered, because the user will want to know. Leave out commands and flags unless they ask. For example:

> Done, 14 pt on all 12 terminals, and Safari is still clear. Some of them are just under 80 columns now.

The terminal you're running in is usually one of those being arranged, so it may change size mid-reply. That's expected, and there's no need to mention it.

## If something goes wrong

- **`termquilt` isn't found.** Run the same command again as `~/.local/bin/termquilt`, and use that form for the rest of the conversation. It's usually there, just not on their PATH, so suggest adding `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`.
- **`~/.local/bin/termquilt` isn't found either.** Now it really is missing. Tell them you're downloading it, run `curl -fsSL https://raw.githubusercontent.com/eduardragea/termquilt/main/install.sh | bash`, then do what they asked.
- **macOS blocked it from controlling a terminal.** Tell them to click Allow on the prompt, or to turn it on in System Settings > Privacy & Security > Automation, then try again.
- **It needs Accessibility permission.** Ghostty, kitty, WezTerm, Alacritty and Warp can only be moved that way. Tell them to turn it on for the app they're running in, under System Settings > Privacy & Security > Accessibility, then try again.
- **"No supported terminal is running", or no windows found.** They may be in a terminal inside VS Code or Cursor, which isn't a separate window. Say that plainly.
- **An app "doesn't let other programs set its text size".** That's iTerm2, kitty, WezTerm and Warp. Tell them to use ⌘+ and ⌘- in that app. Other apps' windows still change.
- **Ghostty or Alacritty text size.** It changes in all of that app's windows at once, so it's skipped with "only the claude ones", and undo can't bring back the old size.

Support for Ghostty, kitty, WezTerm, Alacritty and Warp hasn't been tested against the real apps yet. If something goes wrong in one of them, say so, and suggest reporting it at https://github.com/eduardragea/termquilt/issues.

## How it decides

With `--around`, every other app counts. Priority goes frontmost first within each group:

1. An app they can see right now keeps its space even if terminals get cramped, down to 60×15.
2. An app the terminals are covering keeps its space while terminals stay at 80×20 or larger.
3. An app hidden behind other apps keeps its space only if that costs no text size.

A chosen font changes the text and not which apps the terminals go around, down to 60×15. Below that, the app gets covered and the output says so.

Windows under 5% of the screen don't count. Neither do minimized or hidden ones.

So if an app they don't care about is cramping the terminals, the answer is for them to hide it (⌘H). If they want an app that got covered, they can click it and ask you to tidy again.

## What it can't do

Say so plainly and offer the nearest option:

| They ask for | Nearest option |
|---|---|
| "ignore Discord", "only keep Safari clear" | They hide (⌘H) or minimize the apps that shouldn't count, then tidy again |
| A fixed part of the screen, like "only the left half" | They move another app over the rest, and `--around` fills what's free |
| A chosen order, like "claude on the left, codex on the right" | Each window goes to its nearest slot, so dragging them roughly into place and tidying usually works |
| Text size in iTerm2, kitty, WezTerm or Warp | They use ⌘+ and ⌘- in that app. Windows still get arranged |
| Terminals inside VS Code or Cursor | Not available, because they aren't separate windows |

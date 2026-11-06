# Contributing

Bug reports and pull requests are welcome. Only the maintainer can merge into `main`, so every change goes through a pull request and gets reviewed. For anything big, open an issue first so we can agree on the shape of it.

The most useful thing you can do right now is try a terminal the README marks "Not yet" and report what happens.

## Setting up

You need Swift 6, which comes with Xcode 16 or newer.

```sh
git clone https://github.com/eduardragea/termquilt.git
cd termquilt
make test           # unit tests
make test-install   # builds a release and tests install.sh in throwaway home folders
make install        # installs your build to ~/.local/bin
make install-skill  # links the skill in this repo into ~/.claude/skills, so edits apply at once
```

## Where things are

| Path | What's there |
|---|---|
| `Sources/TermquiltCore` | All the decisions: free space, layout, font, settings, undo. No macOS calls, and fully unit tested |
| `Sources/TermquiltMac` | The parts that talk to macOS: each terminal app, the window list, hotkeys, launchd |
| `Sources/termquilt` | The command line |
| `.claude/skills/termquilt` | The Claude Code skill |
| `install.sh` | What people run to install it |

## Before you open a pull request

- Write the test first. New behaviour goes in `TermquiltCore` wherever it can.
- Run `make test`, and `make test-install` if you changed the installer or the skill.
- If you changed how windows actually move, run `make integration` too, and `make integration-iterm` if you have iTerm2. They open a few throwaway windows and arrange only those, using their own temporary settings, and fail if any other window changes. They cover your screen for about ten seconds, so don't type into a terminal while they run.
- If you changed what the tool can do, update `README.md` and the skill so they still tell the truth.

## Adding another terminal app

Each one is a `TerminalBackend`, listed in `TerminalApps.all`. Add new ones at the end of that list, because an app's position is part of the window IDs saved for undo.

If the app has no window scripting, `AccessibilityTerminal` already handles moving its windows, so you only need to add its bundle identifier. Font size is the hard part, because every app exposes it differently.

To move an app out of "Not yet" in the README, run it for real and say what you tested in your pull request.

## Releasing

Bump the version in `Sources/termquilt/TermquiltCLI.swift`, merge to `main`, then push a tag such as `v0.2.0`. GitHub builds the program and publishes the release, and the tag has to match the version or it stops.

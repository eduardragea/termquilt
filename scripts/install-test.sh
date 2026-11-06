#!/usr/bin/env bash
# Runs install.sh the way a stranger would, against a locally built release, in throwaway home
# folders. It never touches your real ~/.local/bin or ~/.claude, and moves no windows.
set -euo pipefail

DIST="$(cd "${1:?usage: install-test.sh path/to/dist}" && pwd)"
INSTALLER="$(cd "$(dirname "$0")/.." && pwd)/install.sh"
ARCHIVE="termquilt-macos.tar.gz"
PASSED=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { PASSED=$((PASSED + 1)); echo "  ok: $1"; }
fail() { echo "  FAILED: $1" >&2; exit 1; }
fresh_home() { mktemp -d "$WORK/home.XXXXXX"; }

# Usage: run_installer HOME RELEASE_DIR [installer options]. Prints what the installer printed.
run_installer() {
  local home="$1" release="$2"
  shift 2
  env -u CLAUDE_CONFIG_DIR -u TERMQUILT_BIN_DIR -u TERMQUILT_CONFIG_DIR \
    HOME="$home" PATH="${TEST_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" TERMQUILT_RELEASE_URL="file://$release" \
    bash -s -- "$@" < "$INSTALLER" 2>&1
}

expect_nothing_installed() {
  [[ ! -e "$1/.local/bin/termquilt" && ! -e "$1/.local/bin/.termquilt.new" && ! -e "$1/.claude/skills/termquilt" ]] \
    || fail "$2 left files behind"
}

# Usage: fake_release VERSION HOTKEY_EXIT_CODE. Prints a folder holding a release of a stand-in
# program, so these tests can check updates and hotkeys without ever calling launchctl for real.
fake_release() {
  local dir
  dir="$(fresh_home)"
  cat > "$dir/termquilt" <<PROGRAM
#!/bin/sh
case "\$1" in
  --version) echo "$1" ;;
  hotkeys) echo "\$*" >> "\$(dirname "\$0")/hotkey-calls"; exit $2 ;;
esac
PROGRAM
  chmod +x "$dir/termquilt"
  echo "skill for $1" > "$dir/SKILL.md"
  tar -czf "$dir/$ARCHIVE" -C "$dir" termquilt SKILL.md
  (cd "$dir" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
  echo "$dir"
}

echo "Fresh install"
HOME_DIR="$(fresh_home)"
OUT="$(run_installer "$HOME_DIR" "$DIST")"
"$HOME_DIR/.local/bin/termquilt" --version >/dev/null || fail "the installed program doesn't run"
pass "installs a program that runs"
grep -q '^name: termquilt$' "$HOME_DIR/.claude/skills/termquilt/SKILL.md" || fail "the skill wasn't installed"
pass "installs the skill"
[[ "$OUT" == *"tidy my terminals"* && "$OUT" == *"/reload-skills"* ]] || fail "no next steps: $OUT"
pass "says what to do next"
[[ "$OUT" == *"isn't on your PATH"* ]] || fail "no PATH advice: $OUT"
pass "explains how to fix PATH when it's missing"

echo "Install when ~/.local/bin is already on PATH"
HOME_DIR="$(fresh_home)"
OUT="$(TEST_PATH="$HOME_DIR/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" run_installer "$HOME_DIR" "$DIST")"
[[ "$OUT" != *"isn't on your PATH"* ]] || fail "PATH advice given when not needed"
pass "gives no PATH advice"

echo "Updating"
NEWER="$(fake_release 9.9.9 0)"
OUT="$(run_installer "$HOME_DIR" "$NEWER")"
[[ "$("$HOME_DIR/.local/bin/termquilt" --version)" == "9.9.9" ]] || fail "the program wasn't updated"
[[ "$(cat "$HOME_DIR/.claude/skills/termquilt/SKILL.md")" == "skill for 9.9.9" ]] || fail "the skill wasn't updated"
pass "installing again replaces the program and the skill"
[[ ! -e "$HOME_DIR/.local/bin/hotkey-calls" ]] || fail "it touched hotkeys that were never turned on"
pass "leaves hotkeys alone if they were never turned on"

mkdir -p "$HOME_DIR/Library/LaunchAgents"
touch "$HOME_DIR/Library/LaunchAgents/io.github.eduardragea.termquilt.plist"
run_installer "$HOME_DIR" "$NEWER" >/dev/null
[[ "$(cat "$HOME_DIR/.local/bin/hotkey-calls")" == "hotkeys install" ]] || fail "running hotkeys weren't restarted"
pass "restarts the hotkeys if they're on, so they use the new version"

FAILING="$(fake_release 9.9.10 1)"
OUT="$(run_installer "$HOME_DIR" "$FAILING")" || fail "a hotkey restart failure shouldn't fail the install: $OUT"
[[ "$OUT" == *"Couldn't restart the hotkeys"* ]] || fail "no warning about the hotkeys: $OUT"
[[ "$(cat "$HOME_DIR/.claude/skills/termquilt/SKILL.md")" == "skill for 9.9.10" ]] || fail "the skill was left behind"
pass "if the hotkeys won't restart, it says so and still finishes"

echo "A custom Claude config folder"
HOME_DIR="$(fresh_home)"
CLAUDE_DIR="$(fresh_home)"
env HOME="$HOME_DIR" PATH=/usr/bin:/bin:/usr/sbin:/sbin CLAUDE_CONFIG_DIR="$CLAUDE_DIR" TERMQUILT_RELEASE_URL="file://$DIST" \
  bash -s < "$INSTALLER" >/dev/null 2>&1
[[ -f "$CLAUDE_DIR/skills/termquilt/SKILL.md" ]] || fail "CLAUDE_CONFIG_DIR was ignored"
[[ ! -e "$HOME_DIR/.claude" ]] || fail "it also wrote to ~/.claude"
pass "puts the skill where CLAUDE_CONFIG_DIR says, and only there"

echo "A developer's linked skill"
HOME_DIR="$(fresh_home)"
LINKED="$(fresh_home)"
echo "my edits" > "$LINKED/SKILL.md"
mkdir -p "$HOME_DIR/.claude/skills"
ln -s "$LINKED" "$HOME_DIR/.claude/skills/termquilt"
OUT="$(run_installer "$HOME_DIR" "$DIST")"
[[ "$(cat "$LINKED/SKILL.md")" == "my edits" && -L "$HOME_DIR/.claude/skills/termquilt" ]] || fail "it overwrote a linked skill"
pass "leaves it alone"

echo "Bad downloads"
HOME_DIR="$(fresh_home)"
EMPTY="$(fresh_home)"
if OUT="$(run_installer "$HOME_DIR" "$EMPTY")"; then fail "a missing release should fail"; fi
[[ "$OUT" == *"Nothing was installed"* ]] || fail "unclear message: $OUT"
expect_nothing_installed "$HOME_DIR" "a missing release"
pass "a missing release fails clearly and installs nothing"

DAMAGED="$(fresh_home)"
cp "$DIST/$ARCHIVE" "$DIST/$ARCHIVE.sha256" "$DAMAGED/"
printf 'x' >> "$DAMAGED/$ARCHIVE"
if OUT="$(run_installer "$HOME_DIR" "$DAMAGED")"; then fail "a damaged download should fail"; fi
[[ "$OUT" == *"damaged"* ]] || fail "unclear message: $OUT"
expect_nothing_installed "$HOME_DIR" "a damaged download"
pass "a damaged download fails clearly and installs nothing"

INCOMPLETE="$(fresh_home)"
echo "not a program" > "$INCOMPLETE/SKILL.md"
tar -czf "$INCOMPLETE/$ARCHIVE" -C "$INCOMPLETE" SKILL.md
(cd "$INCOMPLETE" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
if OUT="$(run_installer "$HOME_DIR" "$INCOMPLETE")"; then fail "an incomplete download should fail"; fi
[[ "$OUT" == *"missing files"* ]] || fail "unclear message: $OUT"
expect_nothing_installed "$HOME_DIR" "an incomplete download"
pass "an incomplete download fails clearly and installs nothing"

NO_CHECKSUM="$(fresh_home)"
cp "$DIST/$ARCHIVE" "$NO_CHECKSUM/"
if OUT="$(run_installer "$HOME_DIR" "$NO_CHECKSUM")"; then fail "a missing checksum should fail"; fi
[[ "$OUT" == *"checksum"* ]] || fail "unclear message: $OUT"
expect_nothing_installed "$HOME_DIR" "a missing checksum"
pass "a missing checksum fails clearly and installs nothing"

BROKEN="$(fresh_home)"
printf '#!/bin/sh\nexit 1\n' > "$BROKEN/termquilt"
chmod +x "$BROKEN/termquilt"
echo "skill" > "$BROKEN/SKILL.md"
tar -czf "$BROKEN/$ARCHIVE" -C "$BROKEN" termquilt SKILL.md
(cd "$BROKEN" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
if OUT="$(run_installer "$HOME_DIR" "$BROKEN")"; then fail "a program that won't run should fail"; fi
[[ "$OUT" == *"won't run"* ]] || fail "unclear message: $OUT"
expect_nothing_installed "$HOME_DIR" "a program that won't run"
pass "a program that won't run here fails clearly and installs nothing"

echo "Folders it can't write to"
HOME_DIR="$(fresh_home)"
mkdir -p "$HOME_DIR/.claude"
touch "$HOME_DIR/.claude/skills"
if OUT="$(run_installer "$HOME_DIR" "$DIST")"; then fail "a blocked skills folder should fail"; fi
[[ "$OUT" == *"Nothing was installed"* ]] || fail "unclear message: $OUT"
[[ ! -e "$HOME_DIR/.local/bin/termquilt" && ! -e "$HOME_DIR/.local/bin/.termquilt.new" ]] || fail "it installed the program without the skill"
pass "a blocked skills folder fails clearly and doesn't install half of it"

HOME_DIR="$(fresh_home)"
mkdir -p "$HOME_DIR/.local"
touch "$HOME_DIR/.local/bin"
if OUT="$(run_installer "$HOME_DIR" "$DIST")"; then fail "a blocked bin folder should fail"; fi
[[ "$OUT" == *"Nothing was installed"* ]] || fail "unclear message: $OUT"
[[ ! -e "$HOME_DIR/.claude/skills/termquilt" ]] || fail "it installed the skill without the program"
pass "a blocked program folder fails clearly and doesn't install half of it"

echo "Wrong machine and wrong options"
HOME_DIR="$(fresh_home)"
FAKE_BIN="$(fresh_home)"
printf '#!/bin/sh\necho Linux\n' > "$FAKE_BIN/uname"
chmod +x "$FAKE_BIN/uname"
if OUT="$(TEST_PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" run_installer "$HOME_DIR" "$DIST")"; then fail "Linux should be refused"; fi
[[ "$OUT" == *"only runs on macOS"* ]] || fail "unclear message: $OUT"
pass "refuses anything but macOS"
if OUT="$(run_installer "$HOME_DIR" "$DIST" --nonsense)"; then fail "an unknown option should fail"; fi
[[ "$OUT" == *"unknown option"* ]] || fail "unclear message: $OUT"
expect_nothing_installed "$HOME_DIR" "an unknown option"
pass "refuses an unknown option"

echo "Uninstall"
HOME_DIR="$(fresh_home)"
run_installer "$HOME_DIR" "$DIST" >/dev/null
mkdir -p "$HOME_DIR/.config/termquilt"
echo '{}' > "$HOME_DIR/.config/termquilt/preferences.json"
mkdir -p "$HOME_DIR/keep-me" "$HOME_DIR/.claude/skills/another-skill"
touch "$HOME_DIR/.local/bin/another-program"
run_installer "$HOME_DIR" "$DIST" --uninstall >/dev/null
expect_nothing_installed "$HOME_DIR" "uninstall"
[[ ! -e "$HOME_DIR/.config/termquilt" ]] || fail "settings were left behind"
pass "removes the program, the skill and the settings"
[[ -d "$HOME_DIR/keep-me" && -d "$HOME_DIR/.claude/skills/another-skill" && -f "$HOME_DIR/.local/bin/another-program" ]] \
  || fail "uninstall removed something else"
pass "leaves everything else alone"
run_installer "$HOME_DIR" "$DIST" --uninstall >/dev/null || fail "a second uninstall failed"
pass "running it twice is fine"

HOME_DIR="$(fresh_home)"
LINKED="$(fresh_home)"
echo "my edits" > "$LINKED/SKILL.md"
mkdir -p "$HOME_DIR/.claude/skills"
ln -s "$LINKED" "$HOME_DIR/.claude/skills/termquilt"
run_installer "$HOME_DIR" "$DIST" --uninstall >/dev/null
[[ ! -e "$HOME_DIR/.claude/skills/termquilt" && "$(cat "$LINKED/SKILL.md")" == "my edits" ]] || fail "it followed a linked skill"
pass "removes only the link to a linked skill, not what it points at"

echo "Uninstall with settings somewhere unusual"
# Regression: this once deleted the whole folder, which could be someone's dotfiles or home.
HOME_DIR="$(fresh_home)"
SHARED="$(fresh_home)"
echo '{}' > "$SHARED/preferences.json"
echo '{}' > "$SHARED/undo.json"
echo "precious" > "$SHARED/my-dotfile"
run_installer "$HOME_DIR" "$DIST" >/dev/null
env -u CLAUDE_CONFIG_DIR -u TERMQUILT_BIN_DIR HOME="$HOME_DIR" PATH=/usr/bin:/bin:/usr/sbin:/sbin TERMQUILT_CONFIG_DIR="$SHARED" \
  bash -s -- --uninstall < "$INSTALLER" >/dev/null 2>&1
[[ "$(cat "$SHARED/my-dotfile")" == "precious" ]] || fail "it deleted someone else's file"
[[ ! -e "$SHARED/preferences.json" && ! -e "$SHARED/undo.json" ]] || fail "it left termquilt's own settings"
pass "removes termquilt's files and leaves the folder's other files alone"

echo "Uninstall with the hotkeys on"
HOME_DIR="$(fresh_home)"
FAKE_BIN="$(fresh_home)"
cat > "$FAKE_BIN/launchctl" <<PROGRAM
#!/bin/sh
echo "\$*" >> "$FAKE_BIN/launchctl-calls"
PROGRAM
chmod +x "$FAKE_BIN/launchctl"
mkdir -p "$HOME_DIR/Library/LaunchAgents"
touch "$HOME_DIR/Library/LaunchAgents/io.github.eduardragea.termquilt.plist"
TEST_PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" run_installer "$HOME_DIR" "$DIST" --uninstall >/dev/null
[[ "$(cat "$FAKE_BIN/launchctl-calls")" == "bootout gui/$(id -u)/io.github.eduardragea.termquilt" ]] || fail "the hotkey agent wasn't stopped"
[[ ! -e "$HOME_DIR/Library/LaunchAgents/io.github.eduardragea.termquilt.plist" ]] || fail "the hotkey agent would come back at login"
pass "stops the hotkeys and removes them, even with the program already gone"

echo "$PASSED checks passed."

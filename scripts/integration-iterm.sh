#!/usr/bin/env bash
# Drives the real binary against real iTerm2 windows, without touching yours.
#
# It opens its own windows, which set their own unique title, and uses --match so only those are
# arranged, with config in a temporary folder. It fails if any other iTerm2 or Terminal window changed.
# The test windows are always closed on exit, though iTerm2 can take a while to make them disappear.
set -euo pipefail

BINARY="${1:?usage: integration-iterm.sh path/to/termquilt}"
TAG="termquilt-it-$$"
WINDOW_COUNT=3
PASSED=0

export TERMQUILT_CONFIG_DIR
TERMQUILT_CONFIG_DIR="$(mktemp -d)"
HOLD_SCRIPT="$(mktemp)"
IDS=""
FRONT_APP=""

frontmost_app() {
  osascript -l JavaScript -e 'ObjC.import("AppKit"); ObjC.unwrap($.NSWorkspace.sharedWorkspace.frontmostApplication.localizedName)'
}

cleanup() {
  for id in ${IDS//,/ }; do
    osascript -e "tell application \"iTerm\" to tell current session of window id $id to close" >/dev/null 2>&1 || true
  done
  if [[ -n "$FRONT_APP" ]]; then
    osascript -e "tell application \"$FRONT_APP\" to activate" >/dev/null 2>&1 || true
  fi
  rm -rf "$TERMQUILT_CONFIG_DIR"
  rm -f "$HOLD_SCRIPT"
}
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "  ok: $1"; }
fail() { echo "  FAILED: $1" >&2; exit 1; }

# id|left|top|right|bottom, one line per window, sorted by id.
iterm_state() {
  osascript <<'SCRIPT' | tr '\r' '\n' | sort -n
tell application "iTerm"
  set out to ""
  repeat with w in windows
    set b to bounds of w
    set out to out & (id of w) & "|" & (item 1 of b) & "|" & (item 2 of b) & "|" & (item 3 of b) & "|" & (item 4 of b) & linefeed
  end repeat
  return out
end tell
SCRIPT
}

terminal_state() {
  osascript <<'SCRIPT' | tr '\r' '\n' | sort -n
tell application "Terminal"
  set out to ""
  repeat with w in windows
    try
      set b to bounds of w
      set out to out & (id of w) & "|" & (item 1 of b) & "|" & (item 2 of b) & "|" & (item 3 of b) & "|" & (item 4 of b) & "|" & (font size of selected tab of w) & linefeed
    end try
  end repeat
  return out
end tell
SCRIPT
}

test_windows() { iterm_state | grep -E "^(${IDS//,/|})\|"; }
other_windows() { iterm_state | grep -vE "^(${IDS//,/|})\|" || true; }

# iTerm2 ignores a scripted session name, so each window runs this to title itself.
open_test_windows() {
  printf '#!/bin/sh\nprintf "\\033]0;%s\\007"\nexec sleep 600\n' "$TAG" > "$HOLD_SCRIPT"
  osascript <<SCRIPT
tell application "iTerm"
  set ids to {}
  repeat with n from 1 to $WINDOW_COUNT
    set w to (create window with default profile command "/bin/sh $HOLD_SCRIPT")
    delay 0.5
    set bounds of w to {(100 + n * 60), (100 + n * 40), (700 + n * 60), (500 + n * 40)}
    set end of ids to id of w
  end repeat
  set AppleScript's text item delimiters to ","
  return ids as text
end tell
SCRIPT
}

# Fails unless the test windows never overlap and together cover the display's usable area exactly.
check_tiled() {
  test_windows | python3 -I -c '
import sys
usable = [int(v) for v in sys.argv[1].split(",")]
rows = [line.strip().split("|") for line in sys.stdin if line.strip()]
frames = [tuple(map(int, row[1:5])) for row in rows]
assert len(frames) == int(sys.argv[2]), f"expected {sys.argv[2]} windows, saw {len(frames)}"
for index, a in enumerate(frames):
    for b in frames[index + 1:]:
        assert a[2] <= b[0] or b[2] <= a[0] or a[3] <= b[1] or b[3] <= a[1], f"overlap {a} {b}"
area = sum((f[2] - f[0]) * (f[3] - f[1]) for f in frames)
assert area == usable[0] * usable[1], f"covers {area}, usable {usable[0] * usable[1]}"
' "$USABLE" "$WINDOW_COUNT" || fail "layout check"
}

FRONT_APP="$(frontmost_app)"
echo "Opening $WINDOW_COUNT test windows..."
IDS="$(open_test_windows)"
BEFORE_ITERM="$(other_windows)"
BEFORE_TERMINAL="$(terminal_state)"
BEFORE_TEST="$(test_windows)"

TARGET=(--display 1 --match "$TAG")
USABLE="$("$BINARY" status | sed -nE 's/^Display 1: .*usable area ([0-9]+)×([0-9]+).*/\1,\2/p')"
[[ -n "$USABLE" ]] || fail "couldn't read usable area from status"

echo "Status"
OUT="$("$BINARY" status "${TARGET[@]}")"
[[ "$OUT" == *"$WINDOW_COUNT terminal windows"* && "$OUT" == *"iTerm2"* && "$OUT" == *"$TAG"* ]] || fail "status didn't list the windows: $OUT"
pass "status lists iTerm2 windows and their grids"

echo "Dry run"
OUT="$("$BINARY" "${TARGET[@]}" --full --dry-run)"
[[ "$OUT" == *"Dry run"* && "$(test_windows)" == "$BEFORE_TEST" ]] || fail "dry run: $OUT"
pass "dry run changes nothing"

echo "Arrange"
OUT="$("$BINARY" "${TARGET[@]}" --full)"
echo "    ${OUT//$'\n'/$'\n    '}"
[[ "$OUT" == *"$WINDOW_COUNT terminals"* ]] || fail "unexpected output: $OUT"
[[ "$OUT" != *" pt,"* ]] || fail "it claimed a text size it doesn't control: $OUT"
check_tiled
pass "fills the screen exactly, with no overlaps"

echo "Re-arrange"
OUT="$("$BINARY" "${TARGET[@]}")"
[[ "$OUT" == *"Already tidy"* ]] || fail "second run moved windows: $OUT"
pass "a second run changes nothing"

echo "Text size"
STATE="$(test_windows)"
OUT="$("$BINARY" bigger "${TARGET[@]}")"
[[ "$OUT" == *"iTerm2"* && "$OUT" == *"⌘+"* ]] || fail "no explanation: $OUT"
[[ "$(test_windows)" == "$STATE" ]] || fail "asking for bigger text moved windows"
pass "bigger explains the limit and moves nothing"

echo "Undo"
"$BINARY" undo >/dev/null
[[ "$(test_windows)" == "$BEFORE_TEST" ]] || fail "undo didn't restore the original frames"
pass "undo restores exact frames"

echo "Your other windows"
[[ "$(other_windows)" == "$BEFORE_ITERM" ]] || fail "another iTerm2 window changed"
pass "no other iTerm2 window changed"
[[ "$(terminal_state)" == "$BEFORE_TERMINAL" ]] || fail "a Terminal window changed"
pass "no Terminal window changed"

echo "$PASSED checks passed."

#!/usr/bin/env bash
# Drives the real binary against real Terminal windows, without touching yours.
#
# It opens its own windows with a unique title, uses --match so only those are arranged, and keeps
# config in a temporary folder. It fails if any other Terminal window changed size, position or font.
# The test windows are always closed on exit.
#
# Set COVERING_APP to a running app with a window on this display (say COVERING_APP=Safari) to also
# check that covered terminals come to the front. That app comes forward for a moment during the test.
set -euo pipefail

BINARY="${1:?usage: integration-test.sh path/to/termquilt}"
TAG="termquilt-it-$$"
WINDOW_COUNT=5
PASSED=0

export TERMQUILT_CONFIG_DIR
TERMQUILT_CONFIG_DIR="$(mktemp -d)"
IDS=""
FRONT_APP=""

cleanup() {
  if [[ -n "$IDS" ]]; then
    for id in ${IDS//,/ }; do
      osascript -e "tell application \"Terminal\" to close window id $id" >/dev/null 2>&1 || true
    done
  fi
  # Covered test windows bring Terminal forward, so hand focus back to whatever had it.
  if [[ -n "$FRONT_APP" ]]; then
    osascript -e "tell application \"$FRONT_APP\" to activate" >/dev/null 2>&1 || true
  fi
  rm -rf "$TERMQUILT_CONFIG_DIR"
}
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "  ok: $1"; }
fail() { echo "  FAILED: $1" >&2; exit 1; }

# id|left|top|right|bottom|font, one line per window, sorted by id.
windows_state() {
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

frontmost_app() {
  osascript -l JavaScript -e 'ObjC.import("AppKit"); ObjC.unwrap($.NSWorkspace.sharedWorkspace.frontmostApplication.localizedName)'
}

test_windows() { windows_state | grep -E "^(${IDS//,/|})\|"; }
other_windows() { windows_state | grep -vE "^(${IDS//,/|})\|"; }

# What a tile of the test windows would keep clear of, under the current settings.
keep_clear_list() { "$BINARY" status "${TARGET[@]}" | grep '^Keeping clear of' || true; }
display_one_settings() { "$BINARY" status | sed -n '/^Display 1: /p'; }

open_test_windows() {
  osascript <<SCRIPT
tell application "Terminal"
  set ids to {}
  repeat with n from 1 to $WINDOW_COUNT
    set t to do script ""
    delay 0.2
    set custom title of t to "$TAG"
    set title displays custom title of t to true
    set w to first window whose selected tab is t
    set bounds of w to {(100 + n * 60), (100 + n * 40), (700 + n * 60), (500 + n * 40)}
    set end of ids to id of w
  end repeat
  set AppleScript's text item delimiters to ","
  return ids as text
end tell
SCRIPT
}

# Fails unless the test windows share the expected font, never overlap,
# and together cover the display's usable area exactly.
check_tiled() {
  local expected_font="$1"
  test_windows | python3 -I -c '
import sys
font, usable = sys.argv[1], [int(v) for v in sys.argv[2].split(",")]
rows = [line.strip().split("|") for line in sys.stdin if line.strip()]
frames = [tuple(map(int, row[1:5])) for row in rows]
assert all(row[5].split(".")[0] == font for row in rows), f"fonts: {[row[5] for row in rows]}"
for index, a in enumerate(frames):
    for b in frames[index + 1:]:
        assert a[2] <= b[0] or b[2] <= a[0] or a[3] <= b[1] or b[3] <= a[1], f"overlap {a} {b}"
area = sum((f[2] - f[0]) * (f[3] - f[1]) for f in frames)
assert area == usable[0] * usable[1], f"covers {area}, usable {usable[0] * usable[1]}"
' "$expected_font" "$USABLE" || fail "layout check at $expected_font pt"
}

# Fails if a test window overlaps anything `status` says it is keeping clear of.
check_keeps_clear() {
  local keep_clear="$1"
  test_windows | python3 -I -c '
import re, sys
rows = [line.strip().split("|") for line in sys.stdin if line.strip()]
frames = [tuple(map(int, row[1:5])) for row in rows]
avoid = [tuple(map(int, m)) for m in re.findall(r"(\d+)×(\d+) at (-?\d+),(-?\d+)", sys.argv[1])]
print(f"    keeping clear of {len(avoid)} window(s)")
for w, h, x, y in avoid:
    for f in frames:
        assert f[2] <= x or x + w <= f[0] or f[3] <= y or y + h <= f[1], f"{f} overlaps {(x, y, w, h)}"
' "$keep_clear" || fail "a terminal overlaps a window it should avoid"
}

FRONT_APP="$(frontmost_app)"
echo "Opening $WINDOW_COUNT test windows..."
IDS="$(open_test_windows)"
BEFORE_OTHERS="$(other_windows)"
BEFORE_TEST="$(test_windows)"
FRONT_BEFORE="$(osascript -e 'tell application "Terminal" to id of front window')"

# Display 1 is what the usable area below describes, whichever monitor automatic would pick.
TARGET=(--display 1 --match "$TAG")
USABLE="$("$BINARY" status | sed -nE 's/^Display 1: .*usable area ([0-9]+)×([0-9]+).*/\1,\2/p')"
[[ -n "$USABLE" ]] || fail "couldn't read usable area from status"

echo "Keep clear of other apps"
KEEP_CLEAR="$(keep_clear_list)"
OUT="$("$BINARY" "${TARGET[@]}")"
echo "    ${OUT//$'\n'/$'\n    '}"
check_keeps_clear "$KEEP_CLEAR"
if [[ -n "$KEEP_CLEAR" ]]; then
  pass "terminals stay out of other apps"
else
  echo "  skipped: no other apps are open on this display, so there was nothing to keep clear of"
fi
"$BINARY" undo >/dev/null

echo "Dry run"
OUT="$("$BINARY" "${TARGET[@]}" --full --dry-run --font 13)"
[[ "$OUT" == *"Dry run"* ]] || fail "dry run output: $OUT"
[[ "$(test_windows)" == "$BEFORE_TEST" ]] || fail "dry run moved windows"
pass "dry run changes nothing"

echo "Flags"
if "$BINARY" "${TARGET[@]}" --around --full --dry-run >/dev/null 2>&1; then
  fail "--around and --full together should be refused"
fi
pass "--around and --full together are refused"

echo "Tile with a fixed font"
OUT="$("$BINARY" "${TARGET[@]}" --full --font 13)"
echo "    $OUT"
[[ "$OUT" == *"$WINDOW_COUNT terminals"* ]] || fail "unexpected output: $OUT"
check_tiled 13
pass "fills the screen exactly, no overlaps, one font"
[[ "$(osascript -e 'tell application "Terminal" to id of front window')" == "$FRONT_BEFORE" ]] \
  || fail "tiling changed which window is in front"
pass "front window stays in front"

echo "Re-tile"
OUT="$("$BINARY" "${TARGET[@]}")"
[[ "$OUT" == *"Already tidy"* ]] || fail "re-tile wasn't a no-op: $OUT"
pass "a second run with no flags is a no-op, so the font and full layout were remembered"
SETTINGS="$(display_one_settings)"
[[ "$SETTINGS" == *"layout: full screen, font: 13 pt" ]] || fail "status doesn't show the saved settings: $SETTINGS"
pass "status shows the saved settings"

if [[ -n "${COVERING_APP:-}" ]]; then
  echo "Comes to the front when covered by $COVERING_APP"
  osascript -e "tell application \"$COVERING_APP\" to activate" -e 'delay 0.5'
  [[ "$(frontmost_app)" == "$COVERING_APP" ]] || fail "$COVERING_APP didn't come forward: $(frontmost_app)"
  OUT="$("$BINARY" "${TARGET[@]}" --full)"
  echo "    $OUT"
  [[ "$OUT" == *"came to the front"* ]] || fail "no mention of coming to the front: $OUT"
  osascript -e 'delay 0.5'
  [[ "$(frontmost_app)" == "Terminal" ]] || fail "Terminal isn't frontmost: $(frontmost_app)"
  pass "a covered tile brings Terminal to the front"
  OUT="$("$BINARY" "${TARGET[@]}" --full)"
  [[ "$OUT" != *"came to the front"* ]] || fail "raised again with nothing covering it: $OUT"
  pass "and doesn't raise again once nothing covers it"
else
  echo "  skipped: set COVERING_APP to check that covered terminals come to the front"
fi

echo "Bigger"
"$BINARY" bigger "${TARGET[@]}" --full >/dev/null
check_tiled 14
pass "bigger goes to 14 pt and still fills the screen"
STATE_AT_14="$(test_windows)"

echo "Automatic font"
OUT="$("$BINARY" "${TARGET[@]}" --full --font auto)"
echo "    $OUT"
STATE_AUTO="$(test_windows)"
[[ "$STATE_AUTO" != "$STATE_AT_14" ]] || fail "automatic font changed nothing"
pass "automatic font re-fits"

echo "Undo"
"$BINARY" undo >/dev/null
[[ "$(test_windows)" == "$STATE_AT_14" ]] || fail "undo didn't restore the previous layout"
pass "undo restores exact frames and font"
"$BINARY" undo >/dev/null
[[ "$(test_windows)" == "$STATE_AUTO" ]] || fail "second undo didn't redo"
pass "undo again redoes"

echo "Back to going around other apps"
"$BINARY" "${TARGET[@]}" --around >/dev/null
SETTINGS="$(display_one_settings)"
[[ "$SETTINGS" == *"layout: around other apps"* ]] || fail "status still shows the old layout: $SETTINGS"
pass "--around is remembered"
OUT="$("$BINARY" "${TARGET[@]}")"
[[ "$OUT" == *"Already tidy"* ]] || fail "re-tiling around other apps wasn't a no-op: $OUT"
pass "a second run changes nothing"
KEEP_CLEAR="$(keep_clear_list)"
check_keeps_clear "$KEEP_CLEAR"
if [[ -n "$KEEP_CLEAR" ]]; then
  pass "terminals left the whole-screen layout and stay out of other apps"
else
  echo "  skipped: no other apps are open on this display, so there was nothing to keep clear of"
fi

echo "Your other windows"
AFTER_OTHERS="$(other_windows)"
if [[ "$AFTER_OTHERS" != "$BEFORE_OTHERS" ]]; then
  diff <(echo "$BEFORE_OTHERS") <(echo "$AFTER_OTHERS") >&2 || true
  fail "another Terminal window changed (id|left|top|right|bottom|font)"
fi
pass "no other Terminal window changed"

echo "$PASSED checks passed."

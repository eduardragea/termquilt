#!/usr/bin/env bash
# Installs termquilt and its skill for Claude Code and Codex. Short enough to read before you run it.
#
#   curl -fsSL https://raw.githubusercontent.com/eduardragea/termquilt/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/eduardragea/termquilt/main/install.sh | bash -s -- --uninstall
#
# The program goes in ~/.local/bin, and the skill in ~/.claude/skills/termquilt for Claude Code and
# ~/.agents/skills/termquilt for Codex. It doesn't need sudo or Xcode, and it doesn't edit your shell
# profile or your settings for either tool.
#
# Everything is inside functions, so a download cut off halfway can't run half a script.
set -euo pipefail

REPO_URL="https://github.com/eduardragea/termquilt"
# The tests point this at a local folder.
RELEASE_URL="${TERMQUILT_RELEASE_URL:-$REPO_URL/releases/latest/download}"
ARCHIVE="termquilt-macos.tar.gz"
BIN_DIR="${TERMQUILT_BIN_DIR:-$HOME/.local/bin}"
SKILL_DIRS=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/termquilt" "$HOME/.agents/skills/termquilt")
CONFIG_DIR="${TERMQUILT_CONFIG_DIR:-$HOME/.config/termquilt}"
HOTKEY_LABEL="io.github.eduardragea.termquilt"
HOTKEY_AGENT="$HOME/Library/LaunchAgents/$HOTKEY_LABEL.plist"
WORK_DIR=""

fail() {
  echo "termquilt: $1" >&2
  exit 1
}

remove_work_dir() {
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

download_and_check() {
  WORK_DIR="$(mktemp -d)"
  trap remove_work_dir EXIT

  echo "Downloading termquilt..."
  curl -fsSL "$RELEASE_URL/$ARCHIVE" -o "$WORK_DIR/$ARCHIVE" \
    || fail "couldn't download $RELEASE_URL/$ARCHIVE. Nothing was installed. To build it yourself, see $REPO_URL#build-from-source"
  curl -fsSL "$RELEASE_URL/$ARCHIVE.sha256" -o "$WORK_DIR/$ARCHIVE.sha256" \
    || fail "couldn't download the checksum for $ARCHIVE. Nothing was installed."
  (cd "$WORK_DIR" && shasum -a 256 -c "$ARCHIVE.sha256" >/dev/null 2>&1) \
    || fail "the download is damaged (its checksum doesn't match). Nothing was installed."

  tar -xzf "$WORK_DIR/$ARCHIVE" -C "$WORK_DIR" || fail "couldn't unpack the download. Nothing was installed."
  [[ -x "$WORK_DIR/termquilt" && -f "$WORK_DIR/SKILL.md" ]] || fail "the download is missing files. Nothing was installed."
  "$WORK_DIR/termquilt" --version >/dev/null 2>&1 || fail "the program won't run here. It needs macOS 13 or newer. Nothing was installed."
}

discard_staged_files() {
  local dir
  rm -f "$BIN_DIR/.termquilt.new"
  for dir in "${SKILL_DIRS[@]}"; do
    if [[ ! -L "$dir" && -f "$dir/.SKILL.md.new" ]]; then
      rm -f "$dir/.SKILL.md.new"
      rmdir "$dir" 2>/dev/null || true
    fi
  done
}

# Writes everything next to where it belongs, then moves it into place, so a full disk or a
# blocked folder can't leave a half-finished install behind.
place_files() {
  local dir
  mkdir -p "$BIN_DIR" || fail "couldn't create $BIN_DIR. Nothing was installed."
  install -m 755 "$WORK_DIR/termquilt" "$BIN_DIR/.termquilt.new" || fail "couldn't write to $BIN_DIR. Nothing was installed."

  for dir in "${SKILL_DIRS[@]}"; do
    if [[ -L "$dir" ]]; then
      echo "Left your linked skill alone: $dir"
    elif ! mkdir -p "$dir" || ! cp "$WORK_DIR/SKILL.md" "$dir/.SKILL.md.new"; then
      discard_staged_files
      fail "couldn't write to $dir. Nothing was installed."
    fi
  done

  for dir in "${SKILL_DIRS[@]}"; do
    # Already moved if both tools were pointed at the same folder.
    if [[ ! -L "$dir" && -f "$dir/.SKILL.md.new" ]]; then
      mv -f "$dir/.SKILL.md.new" "$dir/SKILL.md"
    fi
  done
  mv -f "$BIN_DIR/.termquilt.new" "$BIN_DIR/termquilt"
}

# A running hotkey agent keeps using the old program until it restarts.
restart_hotkeys() {
  if [[ -f "$HOTKEY_AGENT" ]]; then
    "$BIN_DIR/termquilt" hotkeys install >/dev/null 2>&1 \
      || echo "Couldn't restart the hotkeys, so they may still be on the old version. To fix that, run: termquilt hotkeys install"
  fi
}

explain_next_steps() {
  echo
  echo "termquilt $("$BIN_DIR/termquilt" --version) is installed."
  echo "  Program: $BIN_DIR/termquilt"
  echo "  Skill:   ${SKILL_DIRS[0]} (Claude Code)"
  echo "           ${SKILL_DIRS[1]} (Codex)"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      echo
      echo "$BIN_DIR isn't on your PATH yet. Add this line to ~/.zshrc, then open a new terminal:"
      echo "  export PATH=\"$BIN_DIR:\$PATH\""
      ;;
  esac
  echo
  echo "Now ask Claude or Codex to \"tidy my terminals\", then to \"raise the font\"."
  echo "If Claude doesn't pick up the skill straight away, run /reload-skills. In Codex, restart it."
  echo "In Codex, termquilt has to run outside the sandbox, so approve it when Codex asks."
  echo "macOS will ask once to let it control your terminal. Click Allow."
  echo "It works with Terminal, iTerm2, Ghostty, kitty, WezTerm, Alacritty and Warp."
}

install_everything() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "termquilt only runs on macOS. Nothing was installed."
  download_and_check
  place_files
  restart_hotkeys
  explain_next_steps
}

# Removes only files termquilt made, by name, and folders only if that leaves them empty. The
# settings folder can be set to anywhere, so nothing here deletes a folder's contents wholesale.
uninstall_everything() {
  if [[ -f "$HOTKEY_AGENT" ]]; then
    launchctl bootout "gui/$(id -u)/$HOTKEY_LABEL" >/dev/null 2>&1 || true
    rm -f "$HOTKEY_AGENT"
  fi
  rm -f "$BIN_DIR/termquilt"
  local dir
  for dir in "${SKILL_DIRS[@]}"; do
    if [[ -L "$dir" ]]; then
      rm -f "$dir"
    else
      rm -f "$dir/SKILL.md"
      rmdir "$dir" 2>/dev/null || true
    fi
  done
  rm -f "$CONFIG_DIR/preferences.json" "$CONFIG_DIR/undo.json"
  rmdir "$CONFIG_DIR" 2>/dev/null || true
  rm -f "$HOME/Library/Logs/termquilt.log"
  echo "Removed termquilt, its skills, its hotkeys and its settings."
}

main() {
  case "${1:-}" in
    "") install_everything ;;
    --uninstall) uninstall_everything ;;
    *) fail "unknown option \"$1\". Use --uninstall, or no options to install." ;;
  esac
}

main "$@"

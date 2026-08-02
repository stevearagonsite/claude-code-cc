#!/usr/bin/env bash
# Manual installer for claude-code-cc (Homebrew users don't need this).
#
#   ./install.sh                 install
#   ./install.sh --with-skill    also link the Claude Code skill
#   ./install.sh --uninstall     undo
#
# Everything is symlinked, so `git pull` is enough to update.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${CC_BIN_DIR:-$HOME/.local/bin}"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
SKILL_DIR="$HOME/.claude/skills/claude-profiles"
SOURCE_LINE="source \"$REPO/cc.zsh\""

with_skill=0
uninstall=0
for arg in "$@"; do
  case "$arg" in
    --with-skill) with_skill=1 ;;
    --uninstall)  uninstall=1 ;;
    -h|--help)    sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$uninstall" -eq 1 ]; then
  rm -f "$BIN_DIR/cc-profiles"
  [ -L "$SKILL_DIR" ] && rm -f "$SKILL_DIR"
  if [ -f "$ZSHRC" ] && grep -qF "$SOURCE_LINE" "$ZSHRC"; then
    grep -vF "$SOURCE_LINE" "$ZSHRC" > "$ZSHRC.tmp" && mv "$ZSHRC.tmp" "$ZSHRC"
    echo "removed the source line from $ZSHRC"
  fi
  echo "uninstalled. Your profiles in ~/.claude-profiles and their Keychain items were kept."
  exit 0
fi

case "$(uname -s)" in
  Darwin) ;;
  *) echo "claude-code-cc currently supports macOS only (it uses the Keychain)." >&2; exit 1 ;;
esac

mkdir -p "$BIN_DIR"
ln -sf "$REPO/bin/cc-profiles" "$BIN_DIR/cc-profiles"
echo "linked $BIN_DIR/cc-profiles"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "warning: $BIN_DIR is not in your PATH — add it so 'cc -l' works" >&2 ;;
esac

if [ -f "$ZSHRC" ] && grep -qF "$SOURCE_LINE" "$ZSHRC"; then
  echo "$ZSHRC already sources cc.zsh"
else
  printf '\n# claude-code-cc\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
  echo "added the source line to $ZSHRC"
fi

if [ "$with_skill" -eq 1 ]; then
  mkdir -p "$(dirname "$SKILL_DIR")"
  if [ -e "$SKILL_DIR" ] && [ ! -L "$SKILL_DIR" ]; then
    echo "warning: $SKILL_DIR exists and is not a symlink — left untouched" >&2
  else
    ln -sfn "$REPO/skills/claude-profiles" "$SKILL_DIR"
    echo "linked $SKILL_DIR"
  fi
fi

cat <<EOF

Done. Open a new shell (or run: exec zsh), then:

  cc -a work        create a profile by cloning your current session
  cc -p work        switch to it, then run /login with the other account
  cc -l             see what's left on each account
EOF

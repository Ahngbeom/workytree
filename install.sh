#!/bin/sh
# workytree installer. Usage: curl -fsSL <raw-url>/install.sh | sh   (or: sh install.sh from a checkout)
set -eu
REPO_URL="${WORKYTREE_REPO_URL:-https://github.com/Ahngbeom/workytree.git}"
INSTALL_DIR="${WORKYTREE_INSTALL_DIR:-$HOME/.local/share/workytree}"
BIN_DIR="${WORKYTREE_BIN_DIR:-$HOME/.local/bin}"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"

if [ -x "$INSTALL_DIR/bin/workytree" ]; then
  if [ -d "$INSTALL_DIR/.git" ] && [ -z "${WORKYTREE_INSTALL_DIR:-}" ]; then
    echo "workytree: updating $INSTALL_DIR"
    # R46: a failed --ff-only pull (local modifications, diverged history, ...) must never
    # be swallowed -- continuing past it would run the rest of this script (symlink, .zshrc)
    # against a checkout that is NOT what it claims to be, then print "done" as if the
    # update succeeded. Abort instead: nothing below this line has run yet, so the existing
    # install (symlink, .zshrc line, $INSTALL_DIR's current contents) is left exactly as it
    # was before this invocation -- stale, but honestly stale, not silently misreported.
    if ! git -C "$INSTALL_DIR" pull -q --ff-only; then
      echo "workytree: failed to update $INSTALL_DIR (local modifications or a diverged/non-fast-forward history?)" >&2
      echo "workytree: install aborted -- resolve it in $INSTALL_DIR (e.g. 'git status', 'git stash'), then re-run this installer" >&2
      exit 1
    fi
  fi
else
  echo "workytree: cloning into $INSTALL_DIR"
  git clone -q "$REPO_URL" "$INSTALL_DIR"
fi

mkdir -p "$BIN_DIR"
ln -sfn "$INSTALL_DIR/bin/workytree" "$BIN_DIR/workytree"
chmod +x "$INSTALL_DIR/bin/workytree"
echo "workytree: linked $BIN_DIR/workytree"

SOURCE_LINE="[ -s \"$INSTALL_DIR/shell/workytree.zsh\" ] && source \"$INSTALL_DIR/shell/workytree.zsh\""
touch "$ZSHRC"
# R47: the old dedup check (`grep -F "shell/workytree.zsh"`) matched that substring ANYWHERE
# in the file, so a line already sourcing workytree from a DIFFERENT install dir counted as
# "already sources" -- reinstalling to a new WORKYTREE_INSTALL_DIR then silently left the
# shell pointed at the old, possibly-now-deleted location, with no sign anything was wrong
# until that old path stopped existing. Check for an EXACT match of the line THIS run would
# write (-Fx: whole-line, fixed-string) first -- that, and only that, means "already correct,
# nothing to do". A broader match on the bare substring still means "some workytree source
# line exists here", but if it isn't the exact one above it must be stale (a prior install
# elsewhere): replace it in place -- along with the header comment this installer always
# pairs it with -- rather than leaving the dangling old line, or appending a second workytree
# source line next to it (either of which would source workytree twice, or leave a footgun
# for whichever path happens to still exist on disk).
if grep -Fxq "$SOURCE_LINE" "$ZSHRC"; then
  echo "workytree: $ZSHRC already sources the shell integration"
elif grep -Fq "shell/workytree.zsh" "$ZSHRC"; then
  cp "$ZSHRC" "$ZSHRC.bak-$(date +%Y%m%d-%H%M%S)"
  grep -v -e 'shell/workytree\.zsh' -e '^# workytree shell integration$' "$ZSHRC" > "$ZSHRC.tmp"
  mv "$ZSHRC.tmp" "$ZSHRC"
  printf '\n# workytree shell integration\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
  echo "workytree: $ZSHRC sourced workytree from a different location; updated it to point at $INSTALL_DIR (backup created)"
else
  cp "$ZSHRC" "$ZSHRC.bak-$(date +%Y%m%d-%H%M%S)"
  printf '\n# workytree shell integration\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
  echo "workytree: added shell integration to $ZSHRC (backup created)"
fi

case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "workytree: note — add $BIN_DIR to your PATH" ;; esac
echo "workytree: done. Open a new shell, then run: workytree init"

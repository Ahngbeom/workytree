#!/bin/sh
# workytree installer. Usage: curl -fsSL <raw-url>/install.sh | sh   (or: sh install.sh from a checkout)
set -eu
REPO_URL="${WORKYTREE_REPO_URL:-https://github.com/Ahngbeom/workytree.git}"
INSTALL_DIR="${WORKYTREE_INSTALL_DIR:-$HOME/.local/share/workytree}"
BIN_DIR="${WORKYTREE_BIN_DIR:-$HOME/.local/bin}"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"

# die <msg>: the ONLY way this script ends on a real failure -- always workytree's own
# message, on stderr, never a bare command's raw diagnostic standing in as the explanation.
# R49: every command below whose failure would otherwise let `set -eu` kill the script with
# no "workytree:" prefix (or, worse, mid-write with debris left behind) is now guarded with
# `|| die "..."` or an explicit `if ! ...; then ...; die ...; fi`.
die() { echo "workytree: $*" >&2; exit 1; }

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
  git clone -q "$REPO_URL" "$INSTALL_DIR" || die "failed to clone $REPO_URL into $INSTALL_DIR"
fi

mkdir -p "$BIN_DIR" || die "could not create $BIN_DIR"
ln -sfn "$INSTALL_DIR/bin/workytree" "$BIN_DIR/workytree" || die "could not link $BIN_DIR/workytree -> $INSTALL_DIR/bin/workytree"
chmod +x "$INSTALL_DIR/bin/workytree" || die "could not mark $INSTALL_DIR/bin/workytree executable"
echo "workytree: linked $BIN_DIR/workytree"

SOURCE_LINE="[ -s \"$INSTALL_DIR/shell/workytree.zsh\" ] && source \"$INSTALL_DIR/shell/workytree.zsh\""
touch "$ZSHRC" || die "could not create/touch $ZSHRC"
# R48: R47's replace-a-stale-path fix matched any line CONTAINING "shell/workytree.zsh" --
# which also matches prose mentioning the path, an unrelated alias quoting it, or (worst)
# a line the user deliberately COMMENTED OUT, silently deleting the first two and
# reactivating the third as a live line. Match the exact SHAPE this installer itself
# writes instead -- "[ -s "<path>/shell/workytree.zsh" ] && source
# "<path>/shell/workytree.zsh"", for any <path> -- not a bare substring, so a line has to
# structurally BE one of our own source statements (active or commented-out) before this
# script will touch it. Anything that merely mentions the path in some other shape is left
# alone, unconditionally, and reported rather than silently skipped.
ACTIVE_RE='^[[:space:]]*\[ -s "[^"]*shell/workytree\.zsh" \] && source "[^"]*shell/workytree\.zsh"[[:space:]]*$'
DISABLED_RE='^[[:space:]]*#[[:space:]]*\[ -s "[^"]*shell/workytree\.zsh" \] && source "[^"]*shell/workytree\.zsh"[[:space:]]*$'
if grep -Fxq "$SOURCE_LINE" "$ZSHRC"; then
  echo "workytree: $ZSHRC already sources the shell integration"
elif grep -Eq "$ACTIVE_RE" "$ZSHRC"; then
  # A DIFFERENT active source line exists (R47) -- replace it (and the header comment this
  # installer always pairs with it) rather than leaving it stale or appending a duplicate
  # live line. -E, matching ACTIVE_RE's shape, so only a genuine source statement is ever
  # removed here -- never prose, an alias, or a commented-out line (DISABLED_RE, checked
  # below, is a superset match that would also hit ACTIVE_RE if not excluded by the elif
  # ordering: an active line is matched here first and never falls through).
  #
  # R49: filter FIRST, into a temp file, before touching $ZSHRC itself -- a backup is only
  # ever created immediately before (and alongside) an actual replacement, so a mid-step
  # failure can never leave an orphaned backup with nothing to show for it. `grep -v` exits
  # 1 when EVERY input line matched one of the -e patterns, i.e. nothing survives the
  # filter -- for a .zshrc that WAS nothing but our own stale block, an empty temp file here
  # is the correct, INTENDED result, not a failure. Only an exit status > 1 is a genuine
  # grep error. Every failure path below removes the temp file before dying, so it never
  # lingers regardless of which step failed.
  : > "$ZSHRC.tmp" || die "could not create a temporary file next to $ZSHRC"
  grep_rc=0
  grep -Ev -e "$ACTIVE_RE" -e '^# workytree shell integration$' "$ZSHRC" > "$ZSHRC.tmp" || grep_rc=$?
  if [ "$grep_rc" -gt 1 ]; then
    rm -f "$ZSHRC.tmp"
    die "could not filter $ZSHRC (grep exited $grep_rc); left it untouched"
  fi
  cp "$ZSHRC" "$ZSHRC.bak-$(date +%Y%m%d-%H%M%S)" || { rm -f "$ZSHRC.tmp"; die "could not back up $ZSHRC before updating it; left it untouched"; }
  mv "$ZSHRC.tmp" "$ZSHRC" || { rm -f "$ZSHRC.tmp"; die "could not replace $ZSHRC with the filtered content (a backup was made; the original is otherwise untouched)"; }
  printf '\n# workytree shell integration\n%s\n' "$SOURCE_LINE" >> "$ZSHRC" || die "could not append the workytree source line to $ZSHRC (a backup was made, and the stale line was already removed -- re-run this installer)"
  echo "workytree: $ZSHRC sourced workytree from a different location; replaced that line with one pointing at $INSTALL_DIR (backup created)"
elif grep -Eq "$DISABLED_RE" "$ZSHRC"; then
  # The user commented this out on purpose -- never silently reactivate it, and never add a
  # second, live line next to it without saying so (R48). Leave the file untouched (no
  # backup: nothing was written) and name what was found so the user can decide.
  echo "workytree: $ZSHRC has a commented-out workytree source line; leaving it disabled as you left it (not adding a live one) -- edit $ZSHRC yourself to re-enable or replace it"
else
  if grep -Fq "shell/workytree.zsh" "$ZSHRC"; then
    echo "workytree: note -- $ZSHRC mentions \"shell/workytree.zsh\" on a line that isn't a workytree source statement; leaving that line untouched"
  fi
  cp "$ZSHRC" "$ZSHRC.bak-$(date +%Y%m%d-%H%M%S)" || die "could not back up $ZSHRC before adding the shell integration; left it untouched"
  printf '\n# workytree shell integration\n%s\n' "$SOURCE_LINE" >> "$ZSHRC" || die "could not append the workytree source line to $ZSHRC (a backup was made)"
  echo "workytree: added shell integration to $ZSHRC (backup created)"
fi

case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "workytree: note — add $BIN_DIR to your PATH" ;; esac
echo "workytree: done. Open a new shell, then run: workytree init"

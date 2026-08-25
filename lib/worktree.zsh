# Worktree-inspection helpers. Shared by `remove` (Task 6) and `prune` (Task 7) — kept out
# of lib/cmd/remove.zsh so prune never has to source a sibling command module (R4).

# worktree_status <path>: porcelain listing, for DISPLAY only (cmd_remove prints it to the
# user before/while acting). Fails OPEN on a git error (empty output looks identical to
# "clean") -- never use this for a safety decision. Safety code below runs its own probe via
# _worktree_dirt_kind, which fails CLOSED (R24).
worktree_status() { git -C "$1" status --porcelain --untracked-files=normal 2>/dev/null; }

# _worktree_dirt_kind <path>: single source of truth for how dirty a worktree is w.r.t. the
# .idea/-is-discardable rule. Runs `git status --porcelain` exactly ONCE -- a second,
# independent probe moments later could observe different reality (e.g. permissions
# changing mid-run) and disagree with the first, which is exactly the kind of gap that could
# let an inspection failure get silently reclassified as "just .idea/ dirt" and
# auto-discarded. Classifies the result into REPLY as one of:
#   clean      - nothing dirty.
#   idea-only  - only .idea/ entries are dirty (discardable IDE state).
#   real       - at least one dirty entry lies outside .idea/, or is a rename/copy (which
#                always counts as real work, regardless of destination path).
#   unknown    - the probe itself could not be trusted: git exited nonzero, or wrote
#                anything to stderr. A worktree with an unreadable subdirectory (chmod 000)
#                makes `git status` exit 0 while only warning on stderr and silently
#                omitting whatever it couldn't read -- an empty, "clean"-looking listing
#                that is actually incomplete. R24: "cannot determine" must never be treated
#                as clean, or as merely "dirty" (that would still auto-discard it as
#                idea-only) -- callers must refuse outright and say so.
# Sets WT_DIRT_DETAIL and WT_DIRT_RC for callers that want to show the user why:
#   kind clean/idea-only/real -> WT_DIRT_DETAIL is the porcelain listing, WT_DIRT_RC=0.
#   kind unknown               -> WT_DIRT_DETAIL is git's raw (possibly multi-line) stderr
#                                  (or, in the rare case git exited nonzero with nothing on
#                                  stderr, an empty string), WT_DIRT_RC is git's exit code.
# R26: callers must show this stderr verbatim rather than squash/summarize it -- a benign
# warning (e.g. an overly long .gitattributes line) and a real problem look identical once
# reduced to "git status exited 0", so the raw text is what lets a user tell them apart.
typeset -g WT_DIRT_DETAIL='' WT_DIRT_RC=0
_worktree_dirt_kind() {
  # R16: never name a local `path` -- even `local path` silently destroys $PATH for the
  # rest of this scope, so `git`/`mktemp` below would vanish with no visible error.
  local err_file rc err out line entry
  WT_DIRT_DETAIL='' WT_DIRT_RC=0
  err_file="$(mktemp 2>/dev/null)" || { REPLY=unknown; WT_DIRT_DETAIL="(could not allocate a temp file to check git status)"; return; }
  out="$(git -C "$1" status --porcelain --untracked-files=normal 2>"$err_file")"; rc=$?
  err="$(<"$err_file" 2>/dev/null)"
  rm -f "$err_file"
  if (( rc != 0 )) || [[ -n "$err" ]]; then
    REPLY=unknown
    WT_DIRT_RC=$rc
    WT_DIRT_DETAIL="$err"
    return
  fi
  if [[ -z "$out" ]]; then REPLY=clean; return; fi
  WT_DIRT_DETAIL="$out"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Rename/copy markers can appear in either status column (staged X or unstaged Y); a
    # worktree-side-only rename (column Y) hasn't been observed from real git (2.50.1), but
    # anchor on both defensively rather than assume column 1 is the only place R/C shows up.
    case "$line" in [RC]?*|?[RC]*) REPLY=real; return ;; esac
    entry="${line:3}"
    # git wraps a path in double quotes (escaping embedded `"`/`\`) whenever it contains a
    # space, control char, or -- with the default core.quotepath -- a non-ASCII byte. Left
    # unstripped, that leading `"` would break the `.idea/*` prefix match below, so a
    # genuinely .idea-only file with e.g. a space in its name would be misclassified as real
    # work (a safe-but-wrong-per-spec direction). Strip the wrapping quotes before comparing.
    [[ "$entry" == \"*\" ]] && { entry="${entry#\"}"; entry="${entry%\"}"; }
    # R25: no bare ".idea" alternative here -- that would also match a regular FILE literally
    # named ".idea" holding real content, and silently discard it. git already emits a
    # trailing slash for a collapsed, entirely-untracked .idea/ directory (".idea/"), which
    # .idea/* matches fine (`*` matches zero-width).
    case "$entry" in .idea/*) ;; *) REPLY=real; return ;; esac
  done <<< "$out"
  REPLY=idea-only
}

# is_dirty_worktree <path>: true if dirty, OR if that can't be determined (R24 fail-closed).
is_dirty_worktree() { _worktree_dirt_kind "$1"; [[ "$REPLY" != clean ]]; }

# has_non_idea_changes <path>: true if any dirty entry lies outside .idea/ (real work to
# protect), OR if the inspection itself could not be trusted (R24 fail-closed) -- either
# way the caller must refuse without --force.
has_non_idea_changes() { _worktree_dirt_kind "$1"; [[ "$REPLY" == real || "$REPLY" == unknown ]]; }

# has_dirty_submodule <path>: true if any submodule (recursively) has its own uncommitted
# changes, OR if that can't be determined. `git submodule foreach` runs the probe once per
# submodule and stops at the first nonzero exit, propagating that exit code; with no
# submodules at all it runs nothing and exits 0. Any nonzero exit here therefore means
# "found a dirty one" (or some other failure) -- fail closed rather than assume clean. This
# check is independent of _worktree_dirt_kind: a submodule can be configured (via
# submodule.<name>.ignore) to not show up in the SUPERPROJECT's own status at all, so a
# clean top-level `git status` does not imply a clean submodule.
has_dirty_submodule() {
  git -C "$1" submodule foreach --recursive --quiet \
    'test -z "$(git status --porcelain --untracked-files=normal 2>/dev/null)" || exit 1' >/dev/null 2>&1
  (( $? != 0 ))
}

has_initialized_submodules() {
  [[ -n "$(git -C "$1" submodule foreach --recursive --quiet 'printf "%s\n" "$sm_path"' 2>/dev/null)" ]]
}

# dir_is_cruft_only <dir>: true if <dir> contains nothing but .idea/ entries, .DS_Store
# files, or nothing at all. NOT used by `remove` (which works entirely off git's own dirty
# state via _worktree_dirt_kind) -- this is for Task 7 (prune), which deletes an orphaned
# directory outright on a "cruft only" verdict, so it applies the same R24 fail-closed rule:
# `find` failing (e.g. a subdirectory it can't read) or writing to stderr means "not cruft",
# never "cruft". Reads NUL-delimited find output rather than newline-delimited, so a
# filename containing an embedded newline can't be split into fragments that individually
# look like cruft when the real path doesn't; `! -type d` (rather than `-type f`) so a
# symlink or other non-regular entry counts as real content instead of being invisible to
# the scan.
#
# R28/C-2: `find` reports each entry PREFIXED by the argument you gave it ("$1/..."), so
# matching an entry's path is only safe RELATIVE to $1 -- matching the raw absolute path
# (as an earlier version of this function did, via a bare `*/.idea/*` glob) means ANY
# ".idea" path component ABOVE the candidate, including the candidate's own name or an
# ancestor of worktree_root, makes the glob match every file inside and misreports real
# content as cruft. Reproduced twice: a ticket directory literally named ".idea" had a real
# file inside it deleted, and a worktree_root nested under "~/.idea/wts" made every orphan
# underneath look like cruft regardless of content. Every entry is stripped of the "$1/"
# prefix before classification, so only path components INSIDE the candidate count. This is
# Task 6's helper; prune (Task 7) is its first DELETING caller, which is exactly what turns
# a misclassification into permanent, unrecoverable loss -- so getting the anchor right here
# is squarely in scope for this task.
dir_is_cruft_only() {
  local f rel base out_file err_file rc err
  out_file="$(mktemp 2>/dev/null)" || return 1
  err_file="$(mktemp 2>/dev/null)" || { rm -f "$out_file"; return 1; }
  find "$1" -mindepth 1 ! -type d -print0 >"$out_file" 2>"$err_file"
  rc=$?
  err="$(<"$err_file" 2>/dev/null)"
  rm -f "$err_file"
  if (( rc != 0 )) || [[ -n "$err" ]]; then rm -f "$out_file"; return 1; fi
  base="${1%/}/"
  while IFS= read -r -d '' f; do
    rel="${f#$base}"
    # R25 still holds relative to the candidate: a FILE named exactly ".idea" (no slash
    # after it -- distinct from a ".idea/" DIRECTORY's contents) never matches either
    # alternative below, so it falls through to "real work", regardless of depth.
    case "$rel" in
      .idea/*|*/.idea/*) ;;
      .DS_Store|*/.DS_Store) ;;
      *) rm -f "$out_file"; return 1 ;;
    esac
  done < "$out_file"
  rm -f "$out_file"
  return 0
}

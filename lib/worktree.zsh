# Worktree-inspection helpers. Shared by `remove` (Task 6) and `prune` (Task 7) — kept out
# of lib/cmd/remove.zsh so prune never has to source a sibling command module (R4).

worktree_status() { git -C "$1" status --porcelain --untracked-files=normal 2>/dev/null; }
is_dirty_worktree() { [[ -n "$(worktree_status "$1")" ]]; }

# has_non_idea_changes <path>: true if any dirty entry lies outside .idea/ — real work to
# protect. .idea/ is discardable IDE state. Renames/copies (R/C) always count as real work
# regardless of destination path, so they're rejected before the path is even parsed.
#
# `git status --porcelain` wraps a path in double quotes (backslash-escaping embedded `"`
# and `\`) whenever it contains a space, control char, or — with the default
# core.quotepath — a non-ASCII byte. Left unstripped, that leading `"` would break the
# `.idea/*` prefix match, so a genuinely .idea-only file with e.g. a space in its name
# (".idea/some file.xml") would be misclassified as "real work" and block removal without
# --force. That failure direction is safe (never silently discards real work) but wrong per
# spec, so the surrounding quotes are stripped before the prefix check.
has_non_idea_changes() {
  # R16: never name a local `path` — even `local path` silently destroys $PATH for the
  # rest of this scope (and any subshell it forks, e.g. the process substitution below),
  # so `git` inside worktree_status would vanish with no visible error.
  local line entry
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in R*|C*) return 0 ;; esac
    entry="${line:3}"
    [[ "$entry" == \"*\" ]] && { entry="${entry#\"}"; entry="${entry%\"}"; }
    case "$entry" in .idea/*|.idea) ;; *) return 0 ;; esac
  done < <(worktree_status "$1")
  return 1
}

# has_dirty_submodule <path>: true if any submodule (recursively) has its own uncommitted
# changes, OR if that can't be determined. `git submodule foreach` runs the probe once per
# submodule and stops at the first nonzero exit, propagating that exit code; with no
# submodules at all it runs nothing and exits 0. Any nonzero exit here therefore means
# "found a dirty one" (or some other failure) — fail closed rather than assume clean.
has_dirty_submodule() {
  git -C "$1" submodule foreach --recursive --quiet \
    'test -z "$(git status --porcelain --untracked-files=normal 2>/dev/null)" || exit 1' >/dev/null 2>&1
  (( $? != 0 ))
}

has_initialized_submodules() {
  [[ -n "$(git -C "$1" submodule foreach --recursive --quiet 'printf "%s\n" "$sm_path"' 2>/dev/null)" ]]
}

# dir_is_cruft_only <dir>: true if <dir> contains nothing but .idea/ files, .DS_Store
# files, or nothing at all. Used by remove's IDE-state auto-discard, and by prune (Task 7)
# to decide an orphaned directory is safe to delete outright.
dir_is_cruft_only() {
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in */.idea/*) ;; */.DS_Store) ;; *) return 1 ;; esac
  done < <(find "$1" -type f 2>/dev/null)
  return 0
}

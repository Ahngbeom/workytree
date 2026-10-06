# _prune_candidate_is_contained <candidate_canon> <root_a> <root_b>: true only if
# candidate_canon lies strictly under BOTH roots. N-1: pulled out of the sweep loops as its
# own function specifically so it can be driven directly by a test with a candidate string
# that lies outside the roots -- `find`'s own output in this file can never actually produce
# such a candidate (see the note at each call site: no `-L` is used anywhere below, and
# `-type d` never matches a symlink under find's default `-P` behavior, confirmed
# empirically -- a symlinked <kind> component is neither listed nor descended into), so a
# test that only drives prune_repo end-to-end could never reach the "candidate escaped"
# branch of this predicate. Calling it directly, the same way tests/prune_internal.test.zsh
# already reaches prune_repo's other internals, is what makes it provable at all.
_prune_candidate_is_contained() {
  local candidate="$1" root_a="$2" root_b="$3"
  [[ "$candidate" == "$root_a"/* && "$candidate" == "$root_b"/* ]]
}

# _prune_scan <project> <repo> <repo_path>: the read-only half of prune_repo -- the
# worktree_root safety checks, the set of live worktrees, and the unregistered
# <kind>/<ticket> directories under <worktree_root>/<repo>. `status` calls it without prune's
# `git worktree prune` first, so it changes nothing. Sets WT_SCAN_ROOT (raw) and
# WT_SCAN_ROOT_CANON, WT_SCAN_CFG_ROOT_CANON, WT_SCAN_REGISTERED (canonical path -> 1) and
# WT_SCAN_ORPHANS (raw candidate paths). rc 0 scanned, 1 refused (error printed), 2 no
# worktree dir for the repo.
typeset -g WT_SCAN_ROOT='' WT_SCAN_ROOT_CANON='' WT_SCAN_CFG_ROOT_CANON=''
typeset -gA WT_SCAN_REGISTERED
typeset -ga WT_SCAN_ORPHANS
_prune_scan() {
  local project="$1" repo="$2" repo_path="$3"
  local repo_wt_root repo_wt_root_canon repo_path_canon
  local configured_wt_root configured_wt_root_canon
  WT_SCAN_REGISTERED=() WT_SCAN_ORPHANS=()
  repo_wt_root="$(worktree_parent "$project" "$repo")"

  # C-1 layer 2 / I-3: anchor every deletion target to the CONFIGURED worktree_root itself --
  # not merely to repo_wt_root, a value DERIVED from it by concatenating the repo name.
  # require_config (lib/resolve.zsh) already rejects a project with a missing/empty
  # worktree_root (R27, layer 1) for every command that calls it, but that is a config-time
  # check: this scan must not assume its caller ran require_config, and a worktree_root that
  # is non-empty but still dangerous (e.g. configured as "/" outright) passes layer 1 without
  # trouble. Re-derive and re-check the configured root here, independently -- and BEFORE the
  # `-d "$repo_wt_root"` existence check below: canonicalization (`:A`) works on a path that
  # doesn't exist yet, and an unsafe root must be refused unconditionally, not only on the
  # filesystem coincidence that something already happens to exist there.
  repo_wt_root_canon="${repo_wt_root:A}"
  repo_path_canon="${repo_path:A}"
  configured_wt_root="$(project_worktree_root "$project")"
  configured_wt_root_canon="${configured_wt_root:A}"
  if [[ -z "$configured_wt_root_canon" || "$configured_wt_root_canon" == "/" ]]; then
    error "refusing to prune $repo: project '$project' has no safe worktree_root (\"$configured_wt_root_canon\")"
    return 1
  fi
  # A repo name containing ".." (reachable via a hand-edited or, later, `repo add --name`
  # registered alias -- see is_safe_repo_name/R29 in lib/resolve.zsh) can make
  # worktree_parent's "$worktree_root/$repo" concatenation canonicalize OUTSIDE
  # worktree_root entirely, so repo_wt_root_canon must be re-checked against the configured
  # root directly rather than trusted just because it was built from worktree_parent.
  if [[ "$repo_wt_root_canon" != "$configured_wt_root_canon"/* ]]; then
    error "refusing to prune $repo: computed worktree directory ($repo_wt_root_canon) is not inside the configured worktree_root ($configured_wt_root_canon)"
    return 1
  fi
  if [[ "$repo_wt_root_canon" == "$repo_path_canon" ]]; then
    error "refusing to prune $repo: worktree directory equals the repo path itself ($repo_wt_root_canon)"
    return 1
  fi
  WT_SCAN_ROOT="$repo_wt_root" WT_SCAN_ROOT_CANON="$repo_wt_root_canon"
  WT_SCAN_CFG_ROOT_CANON="$configured_wt_root_canon"

  [[ -d "$repo_wt_root" ]] || return 2

  # Build the set of live worktree paths ONCE per repo, canonicalized (:A) on both sides so
  # a symlinked worktree_root/repo_root (macOS's /var -> /private/var, which has already
  # bitten this project twice) can't make a live worktree look unregistered. Read via
  # `<(...)`/`<<<`, never a `cmd | while` pipe -- zsh runs a pipe's right-hand side in a
  # subshell, and this associative array would vanish the instant the loop ends.
  #
  # R24 fail-closed: if `git worktree list --porcelain` itself fails, an EMPTY registered
  # set would make every live worktree look orphaned and eligible for deletion below --
  # refuse to touch anything for this repo rather than risk that.
  local wt_porcelain rc wt_line wtpath
  wt_porcelain="$(git -C "$repo_path" worktree list --porcelain 2>&1)"; rc=$?
  if (( rc != 0 )); then
    error "could not list worktrees for $repo (git exited $rc); refusing to touch its directories:"
    print -r -- "$wt_porcelain" | sed 's/^/  /' >&2
    return 1
  fi
  while IFS= read -r wt_line; do
    [[ "$wt_line" == "worktree "* ]] || continue
    wtpath="${wt_line#worktree }"
    WT_SCAN_REGISTERED[${wtpath:A}]=1
  done <<< "$wt_porcelain"
  # A real git repo always registers at least its main worktree; an empty set here means the
  # porcelain output could not be parsed as expected -- not that no worktrees exist.
  if (( ${#WT_SCAN_REGISTERED} == 0 )); then
    error "could not determine live worktrees for $repo; refusing to touch its directories"
    return 1
  fi

  local dir dir_canon
  while IFS= read -r -d '' dir; do
    [[ -n "$dir" ]] || continue
    dir_canon="${dir:A}"
    # Containment guard: the candidate must actually resolve under BOTH repo_wt_root_canon
    # and the configured root directly. find's -mindepth/-maxdepth already scoped the walk
    # (using default -P behavior -- no -L flag -- so a symlinked <kind>/<ticket> component
    # is never even listed, let alone descended into; verified empirically), but never let
    # the loop's shape alone decide what gets deleted -- see _prune_candidate_is_contained.
    _prune_candidate_is_contained "$dir_canon" "$repo_wt_root_canon" "$configured_wt_root_canon" || continue
    [[ -n "${WT_SCAN_REGISTERED[$dir_canon]:-}" ]] && continue
    WT_SCAN_ORPHANS+=("$dir")
  # M-2: NUL-delimited, matching dir_is_cruft_only's own convention -- a newline-delimited
  # read would split a directory name containing an embedded newline into fragments, so
  # prune_repo's warning/removal would name a nonexistent path and the real orphan would never be
  # inspected at all.
  done < <(find "$repo_wt_root" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
  return 0
}

# prune_repo <project> <repo> <repo_path>: clears git's stale worktree registrations for
# <repo_path>, then sweeps <worktree_root>/<repo>/<kind>/<ticket> (depth 2) for directories
# that are NOT registered as live worktrees, deleting one only when dir_is_cruft_only
# confirms it holds nothing but discardable cruft (R24: unregistered + cruft-only ->
# delete; anything else, including "couldn't tell" -> keep and warn). Finally drops
# <kind> parent dirs left holding no live worktree and only cruft.
#
# Every `rm -rf` target here is guarded explicitly rather than trusted to the shape of the
# `find` calls that produced it (see the containment checks below) -- this function deletes
# real directories on the verdict of dir_is_cruft_only, and Task 6 (`remove`) already showed
# once that a guard which merely LOOKS sufficient can fail open.
prune_repo() {
  local project="$1" repo="$2" repo_path="$3"
  info "pruning worktrees for $repo"

  # M-1: an earlier version merged git's stderr into stdout (`2>&1 | sed`) and discarded the
  # pipeline's exit code entirely (a `cmd | sed` pipeline's $? is sed's, not git's) -- so a
  # genuine git failure here was reported as ordinary stdout chatter, on stdout, with no
  # visible sign anything had gone wrong. Capture stdout/stderr separately, route each to the
  # matching stream, and keep git's own exit code.
  local prune_out_file prune_err_file prune_rc
  prune_out_file="$(mktemp 2>/dev/null)" && prune_err_file="$(mktemp 2>/dev/null)"
  if [[ -n "$prune_out_file" && -n "$prune_err_file" ]]; then
    git -C "$repo_path" worktree prune --verbose >"$prune_out_file" 2>"$prune_err_file"
    prune_rc=$?
    [[ -s "$prune_out_file" ]] && sed 's/^/  /' "$prune_out_file"
    [[ -s "$prune_err_file" ]] && sed 's/^/  /' "$prune_err_file" >&2
    rm -f "$prune_out_file" "$prune_err_file"
  else
    git -C "$repo_path" worktree prune --verbose >/dev/null 2>&1
    prune_rc=$?
  fi
  (( prune_rc == 0 )) || warn "  git worktree prune exited $prune_rc for $repo; continuing"

  _prune_scan "$project" "$repo" "$repo_path"
  case $? in
    1) return 1 ;;
    2) dim "  no worktree dir for $repo"; return 0 ;;
  esac

  # found tracks whether the sweep below ever identified an unregistered candidate -- in
  # EITHER loop (M-4: an earlier version only set this in the depth-2 loop, so a repo whose
  # only orphan was an empty <kind> dir removed by the second loop still printed "no orphan
  # dirs found", contradicting its own "removed" line just above it).
  local dir found=0
  for dir in "${WT_SCAN_ORPHANS[@]}"; do
    found=1
    if dir_is_cruft_only "$dir"; then
      # M-3: report a failed rm instead of leaving the orphan unexplained.
      if rm -rf -- "$dir"; then
        success "  removed orphan: $dir"
      else
        error "  failed to remove orphan (left in place): $dir"
      fi
    else
      warn "  skipped orphan with real files (remove manually if intended): $dir"
    fi
  done

  local kdir kdir_canon keep w
  while IFS= read -r -d '' kdir; do
    [[ -n "$kdir" ]] || continue
    kdir_canon="${kdir:A}"
    _prune_candidate_is_contained "$kdir_canon" "$WT_SCAN_ROOT_CANON" "$WT_SCAN_CFG_ROOT_CANON" || continue
    keep=0
    for w in "${(@k)WT_SCAN_REGISTERED}"; do
      [[ "$w" == "$kdir_canon"/* ]] && { keep=1; break; }
    done
    (( keep )) && continue
    found=1
    if dir_is_cruft_only "$kdir"; then
      if rm -rf -- "$kdir"; then
        success "  removed orphan kind dir: $kdir"
      else
        error "  failed to remove orphan kind dir (left in place): $kdir"
      fi
    else
      # N-4: every path that sets `found` must also say something -- an earlier version
      # left this branch silent, so a <kind> dir holding only a loose real file (never
      # visited by the depth-2 loop above, since a FILE directly under <kind> isn't a
      # depth-2 DIRECTORY) made `wt prune` print no summary line at all: not "removed",
      # not "skipped orphan", not even "no orphan dirs found" (found was already 1).
      warn "  skipped orphan kind dir with real files (remove manually if intended): $kdir"
    fi
  done < <(find "$WT_SCAN_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  (( found )) || dim "  no orphan dirs found"
  return 0
}

# cmd_prune [repo]: prune one repo, or (with no argument) every repo across every project
# (honoring --project if given).
cmd_prune() {
  require_config
  (( $# <= 1 )) || usage_error "usage: workytree prune [repo]"
  if (( $# == 1 )); then
    # R16: never name a local `path` -- it silently destroys $PATH for the rest of this
    # scope (even `local path`), taking `git`/`find` with it. Use repo_path throughout.
    local r project repo_path
    r="$(resolve_repo "$1")" || exit $?
    project="${r%%$'\t'*}" repo_path="${r#*$'\t'}"
    prune_repo "$project" "$1" "$repo_path"
    return
  fi
  # I-2: track a failure flag ACROSS the loop and exit 1 if any repo's sweep was refused, so
  # a script can distinguish a refused sweep from a genuinely clean one -- the single-repo
  # path above already does this implicitly by returning prune_repo's own exit code. The loop
  # reads via process substitution (`< <(...)`), never a `cmd | while` pipe: zsh runs a
  # pipe's right-hand side in a subshell, and a flag set inside one would not survive past
  # the loop -- process substitution keeps the while loop itself in THIS shell.
  local name project repo_path
  local -i any_failed=0
  while IFS=$'\t' read -r name project repo_path; do
    prune_repo "$project" "$name" "$repo_path" || any_failed=1
  done < <(all_repos "$WT_PROJECT_OPT")
  return $(( any_failed ? 1 : 0 ))
}

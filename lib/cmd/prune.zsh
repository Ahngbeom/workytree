# prune_repo <project> <repo> <repo_path>: clears git's stale worktree registrations for
# <repo_path>, then sweeps <worktree_root>/<repo>/<kind>/<ticket> (depth 2) for directories
# that are NOT registered as live worktrees, deleting one only when dir_is_cruft_only
# confirms it holds nothing but discardable cruft (R24: unregistered + cruft-only ->
# delete; anything else, including "couldn't tell" -> keep and warn). Finally drops
# <kind> parent dirs left holding no live worktree and only cruft.
#
# Every `rm -rf` target here is guarded explicitly rather than trusted to the shape of the
# `find` calls that produced it (see the two containment checks below) -- this function
# deletes real directories on the verdict of dir_is_cruft_only, and Task 6 (`remove`) already
# showed once that a guard which merely LOOKS sufficient can fail open.
prune_repo() {
  local project="$1" repo="$2" repo_path="$3"
  local repo_wt_root repo_wt_root_canon repo_path_canon
  repo_wt_root="$(worktree_parent "$project" "$repo")"
  info "pruning worktrees for $repo"
  git -C "$repo_path" worktree prune --verbose 2>&1 | sed 's/^/  /'

  [[ -d "$repo_wt_root" ]] || { dim "  no worktree dir for $repo"; return 0; }

  repo_wt_root_canon="${repo_wt_root:A}"
  repo_path_canon="${repo_path:A}"
  # Guard the deletion root itself before touching anything under it. `project add` doesn't
  # exist yet in this codebase to validate worktree_root at config-write time, so an empty
  # or missing `worktree_root` is reachable today (e.g. a hand-edited config) and would
  # otherwise turn repo_wt_root into "/" or "/$repo" at filesystem root -- and every rm -rf
  # below is only as safe as this root is. R24: refuse rather than guess.
  if [[ -z "$repo_wt_root_canon" || "$repo_wt_root_canon" == "/" ]]; then
    error "refusing to prune $repo: computed worktree directory is unsafe (\"$repo_wt_root_canon\")"
    return 1
  fi
  if [[ "$repo_wt_root_canon" == "$repo_path_canon" ]]; then
    error "refusing to prune $repo: worktree directory equals the repo path itself ($repo_wt_root_canon)"
    return 1
  fi

  # Build the set of live worktree paths ONCE per repo, canonicalized (:A) on both sides so
  # a symlinked worktree_root/repo_root (macOS's /var -> /private/var, which has already
  # bitten this project twice) can't make a live worktree look unregistered. Read via
  # `<(...)`/`<<<`, never a `cmd | while` pipe -- zsh runs a pipe's right-hand side in a
  # subshell, and this associative array would vanish the instant the loop ends.
  #
  # R24 fail-closed: if `git worktree list --porcelain` itself fails, an EMPTY registered
  # set would make every live worktree look orphaned and eligible for deletion below --
  # refuse to touch anything for this repo rather than risk that. (The brief's sample code
  # swallowed this with `2>/dev/null` and no exit-code check; that is a fail-OPEN bug, fixed
  # here per R24.)
  local -A registered
  local wt_porcelain rc wt_line wtpath
  wt_porcelain="$(git -C "$repo_path" worktree list --porcelain 2>&1)"; rc=$?
  if (( rc != 0 )); then
    error "could not list worktrees for $repo (git exited $rc); refusing to touch its directories:"
    print -r -- "$wt_porcelain" | sed 's/^/  /'
    return 1
  fi
  while IFS= read -r wt_line; do
    [[ "$wt_line" == "worktree "* ]] || continue
    wtpath="${wt_line#worktree }"
    registered[${wtpath:A}]=1
  done <<< "$wt_porcelain"
  # A real git repo always registers at least its main worktree; an empty set here means the
  # porcelain output could not be parsed as expected -- not that no worktrees exist.
  if (( ${#registered} == 0 )); then
    error "could not determine live worktrees for $repo; refusing to touch its directories"
    return 1
  fi

  local dir dir_canon found=0
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    dir_canon="${dir:A}"
    # Containment guard: the candidate must actually resolve under repo_wt_root_canon.
    # find's -mindepth/-maxdepth already scoped the walk, but a symlinked child could
    # canonicalize somewhere else entirely -- never let the loop's shape alone decide what
    # gets deleted.
    [[ "$dir_canon" == "$repo_wt_root_canon"/* ]] || continue
    [[ -n "${registered[$dir_canon]:-}" ]] && continue
    found=1
    if dir_is_cruft_only "$dir"; then
      rm -rf -- "$dir" && success "  removed orphan: $dir"
    else
      warn "  skipped orphan with real files (remove manually if intended): $dir"
    fi
  done < <(find "$repo_wt_root" -mindepth 2 -maxdepth 2 -type d 2>/dev/null)

  local kdir kdir_canon keep w
  while IFS= read -r kdir; do
    [[ -n "$kdir" ]] || continue
    kdir_canon="${kdir:A}"
    [[ "$kdir_canon" == "$repo_wt_root_canon"/* ]] || continue
    keep=0
    for w in "${(@k)registered}"; do
      [[ "$w" == "$kdir_canon"/* ]] && { keep=1; break; }
    done
    (( keep )) && continue
    dir_is_cruft_only "$kdir" && rm -rf -- "$kdir"
  done < <(find "$repo_wt_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

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
  local name project repo_path
  while IFS=$'\t' read -r name project repo_path; do
    prune_repo "$project" "$name" "$repo_path"
  done < <(all_repos "$WT_PROJECT_OPT")
}

# remove_branch <repo_path> <branch> <force>: best-effort branch delete after the worktree
# using it is already gone. The branch name must be captured by the caller BEFORE removing
# the worktree — `git branch --show-current` needs the worktree to still exist.
remove_branch() {
  local repo_path="$1" branch="$2" force="$3" flag='-d'
  [[ -n "$branch" ]] || { warn "no branch to delete (detached HEAD); skipping"; return 0; }
  (( force )) && flag='-D'
  if git -C "$repo_path" branch "$flag" "$branch" 2>/dev/null; then success "deleted branch: $branch"
  elif (( force )); then warn "failed to delete branch: $branch"
  else warn "branch not deleted (likely unmerged): $branch"; warn "re-run remove with --branch-force (-B) to force-delete it"; fi
}

# cmd_remove <repo> <kind> <ticket> [--force] [-b|--branch] [-B|--branch-force]
# Flags may appear anywhere among the arguments, interleaved with the positionals; any
# other dash-prefixed argument is a usage error. A literal `--` ends option parsing, so a
# repo/kind/ticket value that happens to start with `-` is still reachable. Exactly 3
# non-flag arguments are required.
cmd_remove() {
  require_config
  local -a pos
  local -i force_remove=0 delete_branch=0 force_branch=0 saw_dashdash=0
  local arg
  for arg in "$@"; do
    if (( saw_dashdash )); then pos+=("$arg"); continue; fi
    case "$arg" in
      --)                 saw_dashdash=1 ;;
      --force)            force_remove=1 ;;
      --branch|-b)        delete_branch=1 ;;
      --branch-force|-B)  delete_branch=1; force_branch=1 ;;
      -*)                 usage_error "unknown flag: $arg" ;;
      *)                  pos+=("$arg") ;;
    esac
  done
  (( ${#pos} == 3 )) || usage_error "usage: workytree remove <repo> <kind> <ticket> [--force] [-b|--branch] [-B|--branch-force]"
  local repo="${pos[1]}" kind="${pos[2]}" ticket="${pos[3]}"

  local r project repo_path target branch
  r="$(resolve_repo "$repo")" || exit $?
  project="${r%%$'\t'*}" repo_path="${r#*$'\t'}"
  target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
  [[ -d "$target" ]] || die "worktree path not found: $target"
  # Capture the branch name before the worktree is removed — afterwards there is nothing
  # left at $target to ask git about.
  branch="$(git -C "$target" branch --show-current 2>/dev/null || true)"

  info "removing worktree"; print -r -- "  path: $target"; [[ -n "$branch" ]] && print -r -- "  branch: $branch"
  git -C "$target" status --short --branch | sed 's/^/  /'

  # A single probe decides everything below (_worktree_dirt_kind). Calling
  # has_non_idea_changes and then is_dirty_worktree separately would each run their own
  # `git status`, and a SECOND probe could fail independently of the first: if that happened
  # here, a probe failure reaching the idea-only branch would get silently discarded as
  # "just .idea/ dirt" without --force -- exactly the false-accept this function exists to
  # prevent.
  # Named dirt_kind, NOT kind: `kind` is already a local holding the ticket's kind (e.g.
  # "fix") from line 35 above. Reusing that name here for the dirt-classification result
  # once caused a genuine zsh quirk: re-declaring an already-local, already-assigned
  # variable with a bare `local kind` (no `=`) makes zsh PRINT "kind=fix" to stdout instead
  # of silently shadowing it -- caught by inspecting real command output during
  # verification, not by any test.
  local dirt_kind
  _worktree_dirt_kind "$target"; dirt_kind="$REPLY"

  local -i idea_only=0
  if [[ "$dirt_kind" == unknown ]]; then
    (( force_remove )) || die "could not verify worktree status ($WT_DIRT_DETAIL); refusing without --force"
    warn "worktree status could not be verified ($WT_DIRT_DETAIL); proceeding only because --force was given"
  elif [[ "$dirt_kind" == real ]] || has_dirty_submodule "$target"; then
    (( force_remove )) || die "worktree has changes outside .idea/ (or a dirty submodule); use --force to remove"
  elif [[ "$dirt_kind" == idea-only ]]; then
    idea_only=1
    warn "worktree only has IDE state under .idea/ — discarding it:"; print -r -- "$WT_DIRT_DETAIL" | sed 's/^/  /'
  fi
  if (( force_remove || idea_only )) || has_initialized_submodules "$target"; then
    git -C "$repo_path" worktree remove --force "$target" || die "failed to remove worktree"
  else
    git -C "$repo_path" worktree remove "$target" || die "failed to remove worktree"
  fi
  git -C "$repo_path" worktree prune 2>/dev/null
  [[ -e "$target" ]] && { warn "worktree dir lingered after remove; deleting leftover: $target"; rm -rf "$target"; }
  success "removed: $target"
  (( delete_branch )) && remove_branch "$repo_path" "$branch" "$force_branch"
  return 0
}

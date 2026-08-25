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
# other dash-prefixed argument is a usage error. Exactly 3 non-flag arguments are required.
cmd_remove() {
  require_config
  local -a pos
  local -i force_remove=0 delete_branch=0 force_branch=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force)           force_remove=1 ;;
      --branch|-b)       delete_branch=1 ;;
      --branch-force|-B) delete_branch=1; force_branch=1 ;;
      -*)                usage_error "unknown flag: $arg" ;;
      *)                 pos+=("$arg") ;;
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

  local -i idea_only=0
  if has_non_idea_changes "$target" || has_dirty_submodule "$target"; then
    (( force_remove )) || die "worktree has changes outside .idea/ (or a dirty submodule); use --force to remove"
  elif is_dirty_worktree "$target"; then
    idea_only=1
    warn "worktree only has IDE state under .idea/ — discarding it:"; worktree_status "$target" | sed 's/^/  /'
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

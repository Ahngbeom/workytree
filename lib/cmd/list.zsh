cmd_list() {
  require_config
  (( $# <= 1 )) || usage_error "usage: workytree list [repo]"
  local r repo_path n p
  if (( $# == 1 )); then
    r="$(resolve_repo "$1")" || exit $?
    repo_path="${r#*$'\t'}"
    info "repo: $1 (${r%%$'\t'*})"; success "path: $repo_path"
    git -C "$repo_path" worktree list | sed 's/^/  /'; return $?
  fi
  all_repos "$WT_PROJECT_OPT" | while IFS=$'\t' read -r n p repo_path; do
    info "repo: $n ($p)"
    git -C "$repo_path" worktree list | sed 's/^/  /'
  done
}

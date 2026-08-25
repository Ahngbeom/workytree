# create_do <project> <repo> <repo_path> <kind> <ticket> <base>
# Prints the summary, adds the worktree, and prints the path as the LAST line.
create_do() {
  local project="$1" repo="$2" repo_path="$3" kind="$4" ticket="$5" base="$6"
  local target branch base_label result
  target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
  branch="$kind/$ticket"
  info "source repo: $repo_path"
  info "target path: $target"
  info "branch name: $branch"
  if [[ -e "$target" ]]; then
    info "base ref: n/a (existing worktree)"
    success "result: reused"; print -r -- "$target"; return 0
  fi
  mkdir -p "${target:h}" || die "failed to create parent directory for $target"
  if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
    info "base ref: n/a (existing branch)"
    git -C "$repo_path" worktree add "$target" "$branch" || die "failed to create worktree"
  else
    info "base ref: $base"
    git -C "$repo_path" worktree add --no-track -b "$branch" "$target" "${base%% *}" || die "failed to create worktree"
  fi
  success "result: created"
  print -r -- "$target"
}

cmd_create() {
  require_config
  local -a pos; pos=("$@")
  (( ${#pos} <= 4 )) || usage_error "usage: workytree create [repo] [kind] [ticket] [base]"
  local repo="" kind="" ticket="" base="" project="" repo_path="" r inferred=""
  inferred="$(infer_current_repo 2>/dev/null)" || inferred=""

  if (( ${#pos} )) && { (( ${#pos} == 4 )) || is_known_repo "${pos[1]}" || [[ -z "$inferred" ]]; }; then
    repo="${pos[1]}"; pos=("${pos[@]:1}")
  fi
  kind="${pos[1]:-}" ticket="${pos[2]:-}" base="${pos[3]:-}"

  if [[ -n "$repo" ]]; then
    r="$(resolve_repo "$repo")" || exit $?
    project="${r%%$'\t'*}" repo_path="${r#*$'\t'}"
  elif [[ -n "$inferred" ]]; then
    project="${inferred%%$'\t'*}"; r="${inferred#*$'\t'}"; repo="${r%%$'\t'*}"; repo_path="${r#*$'\t'}"
    if prompt_available; then
      prompt_confirm "repo: $repo ($repo_path) — use this repo?" y || { repo="" repo_path=""; }
    fi
  fi

  if [[ -z "$repo_path" ]]; then
    prompt_available || usage_error "repo is required: workytree create <repo> <kind> <ticket> [base]"
    create_pick_repo   # sets project repo repo_path (Task 5)
  fi

  if [[ -z "$kind" ]]; then
    prompt_available || usage_error "kind is required: workytree create [repo] <kind> <ticket> [base]"
    prompt_choose "kind" 1 $(config_kinds); kind="$REPLY"
  fi
  if [[ -z "$ticket" ]]; then
    prompt_available || usage_error "ticket is required: workytree create [repo] <kind> <ticket> [base]"
    prompt_input "ticket" ""; ticket="$REPLY"
  fi

  local target; target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
  if [[ -z "$base" && ! -e "$target" ]] && ! git -C "$repo_path" show-ref --verify --quiet "refs/heads/$kind/$ticket"; then
    local auto; auto="$(default_base_ref "$repo_path")" || exit $?
    if prompt_available; then prompt_input "base branch" "$auto"; base="$REPLY"; else base="$auto"; fi
    [[ "$base" == "$auto" ]] && base="$auto (auto-detected)"
  fi

  if prompt_available && [[ ! -e "$target" ]]; then
    dim "──────────────────────────────" >&2
    print -u2 -r -- "repo:    $repo → $repo_path"
    print -u2 -r -- "target:  $target"
    print -u2 -r -- "branch:  $kind/$ticket${base:+  (base: $base)}"
    prompt_confirm "Create?" y || exit 130
  fi
  create_do "$project" "$repo" "$repo_path" "$kind" "$ticket" "$base"
}

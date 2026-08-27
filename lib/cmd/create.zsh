# _wt_worktree_is_registered <repo_path> <target>: true if <target> is registered as a
# worktree of <repo_path> in `git worktree list`. Scoping the check to $repo_path (rather
# than e.g. `git -C "$target" rev-parse --git-dir`) directly answers "is this a worktree of
# THIS repo", which is what the reuse decision needs (R21). Both sides are canonicalized
# with :A, matching the comparison convention already used in lib/resolve.zsh.
#
# The loop reads via process substitution rather than piping into the while (`cmd | while
# ...; done`), and tracks the match in an explicit flag rather than the loop's own exit
# status: a pipe's while runs in a subshell, and `git worktree list --porcelain` always ends
# each entry (and the whole listing) with non-matching lines (HEAD/branch/blank) that fall
# through to `continue` -- and `continue` resets $? to 0, so the seemingly-natural "trust the
# loop's exit status" version reports a match even when none occurred.
_wt_worktree_is_registered() {
  local repo_path="$1" target="$2" want line wtpath
  local -i found=0
  want="${target:A}"
  while IFS= read -r line; do
    [[ "$line" == worktree\ * ]] || continue
    wtpath="${line#worktree }"
    [[ "${wtpath:A}" == "$want" ]] && { found=1; break; }
  done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null)
  (( found ))
}

# wt_branch_name <kind> <ticket>: the one place "$kind/$ticket" is joined into a branch name.
# Coherence cleanup: this used to be reconstructed independently in three spots below (the
# show-ref probe, the confirmation summary, and create_do's own copy) -- three separate copies
# of the same join that could silently drift apart. Every caller now routes through here.
wt_branch_name() { print -r -- "$1/$2"; }

# create_pick_repo: interactive project -> repo selection. Sets project, repo, repo_path in
# the CALLER's scope (cmd_create's locals) -- deliberately not `local` here.
#
# R53: labels, not bare names, are offered to the picker. Two repos sharing a basename within
# the SAME project (e.g. src/alpha/api and src/beta/api) used to show as two IDENTICAL "api"
# entries -- indistinguishable on screen, and picking either one re-resolved by NAME via
# resolve_repo, which fails with the same intra-project ambiguity error either way. Instead,
# every row from all_repos is kept (name + path), a row's label is disambiguated with its path
# whenever its name is not unique among this project's repos, and the chosen label is mapped
# straight back to ITS OWN row's repo_path -- never re-resolved by name -- so picking either
# duplicate actually succeeds.
create_pick_repo() {
  local -a rows labels
  if [[ -n "$WT_PROJECT_OPT" ]]; then project="$WT_PROJECT_OPT"
  elif (( ${#WT_PROJECTS} > 1 )); then prompt_choose "project" 0 "${WT_PROJECTS[@]}"; project="$REPLY"
  else project="${WT_PROJECTS[1]}"; fi
  rows=( ${(f)"$(all_repos "$project")"} )
  (( ${#rows} )) || die "no repos found under project '$project' ($(project_repo_root "$project"))"
  local row n rp
  local -A name_count
  for row in "${rows[@]}"; do name_count[${row%%$'\t'*}]=$(( ${name_count[${row%%$'\t'*}]:-0} + 1 )) ; done
  for row in "${rows[@]}"; do
    n="${row%%$'\t'*}"; rp="${row##*$'\t'}"
    (( name_count[$n] > 1 )) && labels+=("$n ($rp)") || labels+=("$n")
  done
  prompt_choose "repo" 0 "${labels[@]}"
  local -i sel_idx=${labels[(Ie)$REPLY]}
  (( sel_idx )) || die "internal error: could not match the chosen repo"
  row="${rows[$sel_idx]}"
  repo="${row%%$'\t'*}"
  repo_path="${row##*$'\t'}"
}

# create_do <project> <repo> <repo_path> <kind> <ticket> <base_ref> [base_label]
# Prints the summary, adds the worktree, and prints the path as the LAST line. base_ref is
# the raw ref handed to git; base_label is the human-facing display text (may carry the
# "(auto-detected)" suffix) -- kept apart so a ref is never reconstructed by splitting a
# label string (R22).
create_do() {
  local project="$1" repo="$2" repo_path="$3" kind="$4" ticket="$5" base_ref="$6" base_label="${7:-$6}"
  local target branch
  target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
  branch="$(wt_branch_name "$kind" "$ticket")"
  info "source repo: $repo_path"
  info "target path: $target"
  info "branch name: $branch"
  if [[ -e "$target" ]]; then
    if _wt_worktree_is_registered "$repo_path" "$target"; then
      info "base ref: n/a (existing worktree)"
      success "result: reused"; print -r -- "$target"; return 0
    fi
    die "target path exists but is not a worktree of $repo_path: $target (remove it, or run 'workytree prune' once available)"
  fi
  mkdir -p "${target:h}" || die "failed to create parent directory for $target"
  if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
    info "base ref: n/a (existing branch)"
    git -C "$repo_path" worktree add "$target" "$branch" || die "failed to create worktree"
  else
    info "base ref: $base_label"
    git -C "$repo_path" worktree add --no-track -b "$branch" "$target" "$base_ref" || die "failed to create worktree"
  fi
  success "result: created"
  print -r -- "$target"
}

cmd_create() {
  require_config
  local -a pos
  local -i want_ai=0 saw_dashdash=0
  local arg
  # Only `--ai` is filtered out; every other dash-prefixed token still stays positional, as
  # it always has. Making every `-*` a usage error the way remove does would break input
  # that passes today -- that's out of scope for this task. `--` is the escape hatch for
  # passing a literal `--ai` as a repo name.
  for arg in "$@"; do
    if (( saw_dashdash )); then pos+=("$arg"); continue; fi
    case "$arg" in
      --)   saw_dashdash=1 ;;
      --ai) want_ai=1 ;;
      *)    pos+=("$arg") ;;
    esac
  done
  (( ${#pos} <= 4 )) || usage_error "usage: workytree create [repo] [kind] [ticket] [base] [--ai]"
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
    prompt_choose "kind" 1 ${(f)"$(config_kinds)"}; kind="$REPLY"
  fi
  if [[ -z "$ticket" ]]; then
    prompt_available || usage_error "ticket is required: workytree create [repo] <kind> <ticket> [base]"
    prompt_input "ticket" ""; ticket="$REPLY"
  fi

  local target; target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
  # base_ref/base_label split: see the note on create_do (R22).
  local base_ref="$base" base_label="$base"
  if [[ -z "$base_ref" && ! -e "$target" ]] && ! git -C "$repo_path" show-ref --verify --quiet "refs/heads/$(wt_branch_name "$kind" "$ticket")"; then
    local auto; auto="$(default_base_ref "$repo_path")" || exit $?
    if prompt_available; then prompt_input "base branch" "$auto"; base_ref="$REPLY"; else base_ref="$auto"; fi
    base_label="$base_ref"
    [[ "$base_ref" == "$auto" ]] && base_label="$auto (auto-detected)"
  fi

  if prompt_available && [[ ! -e "$target" ]]; then
    dim "──────────────────────────────" >&2
    print -u2 -r -- "repo:    $repo → $repo_path"
    print -u2 -r -- "target:  $target"
    print -u2 -r -- "branch:  $(wt_branch_name "$kind" "$ticket")${base_label:+  (base: $base_label)}"
    prompt_confirm "Create?" y || exit 130
  fi
  create_do "$project" "$repo" "$repo_path" "$kind" "$ticket" "$base_ref" "$base_label"
  ai_maybe_offer "$project" "$want_ai"
}

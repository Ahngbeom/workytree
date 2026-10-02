# remove_branch <repo_path> <branch> <force>: best-effort branch delete after the worktree
# using it is already gone. The branch name must be captured by the caller BEFORE removing
# the worktree — `git branch --show-current` needs the worktree to still exist.
remove_branch() {
  local repo_path="$1" branch="$2" force="$3" flag='-d' out
  [[ -n "$branch" ]] || { warn "no branch to delete (detached HEAD); skipping"; return 1; }
  (( force )) && flag='-D'
  if out="$(git -C "$repo_path" branch "$flag" "$branch" 2>&1)"; then success "deleted branch: $branch"; return 0; fi
  if (( force )); then
    warn "failed to delete branch: $branch. git said:"; _wt_indent_and_cap "$out" >&2
    hint "inspect it with: git -C $repo_path branch -vv --list $branch"
  else
    warn "branch not deleted (likely unmerged): $branch"
    hint "re-run remove with --branch-force (-B) to force-delete it"
  fi
  return 1
}

# _wt_remote_branch <repo_path> <branch>: reply=(remote remote_branch) for the branch's remote
# counterpart -- its upstream, else the first remote (origin first) holding a same-named
# tracking ref. Must run before the local branch is deleted: that also deletes its upstream
# config, and the lookup would then silently fall back to name matching.
_wt_remote_branch() {
  local repo_path="$1" branch="$2" up r
  local -a remotes
  reply=()
  up="$(git -C "$repo_path" for-each-ref --format='%(upstream:remotename)%09%(upstream:lstrip=3)' "refs/heads/$branch" 2>/dev/null)"
  if [[ -n "${up%%$'\t'*}" && "${up%%$'\t'*}" != . && -n "${up#*$'\t'}" ]]; then
    reply=("${up%%$'\t'*}" "${up#*$'\t'}"); return 0
  fi
  remotes=( ${(f)"$(git -C "$repo_path" remote 2>/dev/null)"} )
  (( ${remotes[(Ie)origin]} )) && remotes=(origin "${(@)remotes:#origin}")
  for r in "${remotes[@]}"; do
    git -C "$repo_path" show-ref --verify --quiet "refs/remotes/$r/$branch" && { reply=("$r" "$branch"); return 0; }
  done
  return 1
}

remove_remote_branch() {
  local repo_path="$1" remote="$2" rbranch="$3" out
  if out="$(git -C "$repo_path" push "$remote" --delete "$rbranch" 2>&1)"; then
    success "deleted remote branch: $remote/$rbranch"; return 0
  fi
  warn "failed to delete remote branch: $remote/$rbranch. git said:"; _wt_indent_and_cap "$out" >&2
  hint "if it is already gone upstream, drop the stale ref: git -C $repo_path fetch --prune $remote"
  hint "otherwise check network, credentials and branch protection, then retry: git -C $repo_path push $remote --delete $rbranch"
  return 1
}

_rm_is_inside() { [[ "${1:A}/" == "${2:A}/"* ]]; }

# _rm_managed_worktrees [repo] [kind]: "project<TAB>repo<TAB>kind<TAB>ticket" for each linked
# worktree (a directory holding a .git file) at <worktree_root>/<repo>/<kind>/<ticket>.
_rm_managed_worktrees() {
  local rpat="${1:+${(b)1}}" kpat="${2:+${(b)2}}" p root d rel
  local -a projects
  projects=("${WT_PROJECTS[@]}")
  [[ -n "$WT_PROJECT_OPT" ]] && projects=("$WT_PROJECT_OPT")
  for p in "${projects[@]}"; do
    root="$(project_worktree_root "$p")"
    [[ -n "$root" && -d "$root" ]] || continue
    for d in "$root"/${~rpat:-*}/${~kpat:-*}/*(N/); do
      [[ -f "$d/.git" ]] || continue
      rel="${d#$root/}"
      print -r -- "$p"$'\t'"${rel%%/*}"$'\t'"${${rel#*/}%%/*}"$'\t'"${rel##*/}"
    done
  done
}

# _rm_pick_worktree [repo] [kind]: interactive choice of the worktree to remove. Sets repo,
# kind and ticket in the CALLER's scope (cmd_remove's locals), and pins WT_PROJECT_OPT to the
# chosen row's project so resolve_repo cannot turn a same-named repo in another project into
# an ambiguity error.
_rm_pick_worktree() {
  local -a rows labels f
  local row label
  local -i i chosen=0 multi=0
  rows=( ${(f)"$(_rm_managed_worktrees "$@")"} )
  (( ${#rows} )) || die_with_hints "no worktrees to remove${1:+ for $1}${2:+ $2}" \
    "list them with: workytree list${1:+ $1}" "create one with: workytree create"
  for row in "${rows[@]}"; do
    f=("${(@ps:\t:)row}")
    _rm_is_inside "$PWD" "$(worktree_path "${f[@]}")" || continue
    prompt_confirm "remove the worktree you are in (${f[2]} ${f[3]}/${f[4]})?" y && chosen=1
    break
  done
  if (( ! chosen )); then
    (( ${#${(u)rows[@]%%$'\t'*}} > 1 )) && multi=1
    for row in "${rows[@]}"; do
      f=("${(@ps:\t:)row}")
      label="${f[2]}  ${f[3]}/${f[4]}"
      (( multi )) && label+="  [${f[1]}]"
      labels+=("$label")
    done
    prompt_choose "worktree to remove" 0 "${labels[@]}"
    i=${labels[(Ie)$REPLY]}
    (( i )) || die "internal error: could not match the chosen worktree"
    f=("${(@ps:\t:)rows[$i]}")
  fi
  WT_PROJECT_OPT="${f[1]}" repo="${f[2]}" kind="${f[3]}" ticket="${f[4]}"
}

# _rm_pick_destination <target> <repo_path>: REPLY = directory to cd into after removal.
_rm_pick_destination() {
  local target="$1" repo_path="$2" p
  local -a labels values
  local -i i
  if ! _rm_is_inside "$PWD" "$target"; then labels+=("stay here ($PWD)"); values+=("$PWD"); fi
  labels+=("source repo ($repo_path)" "parent dir (${target:h})")
  values+=("$repo_path" "${target:h}")
  while true; do
    prompt_choose "after removal, move to" 1 "${labels[@]}"
    i=${labels[(Ie)$REPLY]}
    (( i )) && { REPLY="${values[$i]}"; return 0; }
    p="${REPLY/#\~/$HOME}"; p="${p:A}"
    [[ -d "$p" ]] && ! _rm_is_inside "$p" "$target" && { REPLY="$p"; return 0; }
    warn "not a directory, or inside the worktree being removed: $REPLY"
    hint "pick a number from the list, or type the path of an existing directory"
  done
}

# _rm_print_results <rows...>: summary table; each row is "<ok|fail|skip><TAB><text>".
_rm_print_results() {
  local row mark
  ui_rule summary
  for row in "$@"; do
    case "${row%%$'\t'*}" in
      ok)   mark="${WT_C_OK}✓${WT_C_RESET}" ;;
      fail) mark="${WT_C_ERR}✗${WT_C_RESET}" ;;
      *)    mark="${WT_C_DIM}–${WT_C_RESET}" ;;
    esac
    print -u2 -r -- "  $mark ${row#*$'\t'}"
  done
}

# cmd_remove [repo] [kind] [ticket] [--force] [-b|--branch] [-B|--branch-force] [-r|--remote] [--to <dir>]
# Flags may appear anywhere among the arguments, interleaved with the positionals; any
# other dash-prefixed argument is a usage error. A literal `--` ends option parsing, so a
# repo/kind/ticket value that happens to start with `-` is still reachable. Fewer than 3
# non-flag arguments opens the worktree picker, which needs a terminal.
cmd_remove() {
  require_config
  # stdout carries only the post-removal directory, as the LAST line (the shell wrapper cd's
  # there). Everything human-facing goes to stderr so it shows live while the wrapper is
  # still capturing stdout.
  local -i out_fd
  exec {out_fd}>&1 1>&2
  local -a pos
  local -i force_remove=0 delete_branch=0 force_branch=0 delete_remote=0 saw_dashdash=0 to_given=0
  local arg dest=""
  while (( $# )); do
    arg="$1"; shift
    if (( saw_dashdash )); then pos+=("$arg"); continue; fi
    case "$arg" in
      --)                 saw_dashdash=1 ;;
      --force)            force_remove=1 ;;
      --branch|-b)        delete_branch=1 ;;
      --branch-force|-B)  delete_branch=1; force_branch=1 ;;
      --remote|-r)        delete_remote=1 ;;
      --to)               (( $# )) || usage_error "--to requires a directory"; dest="$1"; to_given=1; shift ;;
      --to=*)             dest="${arg#--to=}"; to_given=1 ;;
      -*)                 usage_error "unknown flag: $arg" ;;
      *)                  pos+=("$arg") ;;
    esac
  done
  local usage="usage: workytree remove [repo] [kind] [ticket] [--force] [-b|--branch] [-B|--branch-force] [-r|--remote] [--to <dir>]"
  (( ${#pos} <= 3 )) || usage_error "$usage"
  local repo="${pos[1]:-}" kind="${pos[2]:-}" ticket="${pos[3]:-}"
  if (( ${#pos} < 3 )); then
    prompt_available || usage_error "$usage (repo, kind and ticket are required without a terminal)"
    _rm_pick_worktree "$repo" "$kind"   # sets repo kind ticket, and WT_PROJECT_OPT
  fi

  local r project repo_path target branch
  r="$(resolve_repo "$repo")" || exit $?
  project="${r%%$'\t'*}" repo_path="${r#*$'\t'}"
  target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
  [[ -d "$target" ]] || die_with_hints "worktree path not found: $target" \
    "list existing worktrees with: workytree list $repo" \
    "if the directory was deleted by hand, clean up git's record with: workytree prune $repo"
  if (( to_given )); then
    dest="${dest/#\~/$HOME}"; dest="${dest:A}"
    [[ -d "$dest" ]] || die_with_hints "--to: not a directory: $dest" "pass an existing directory, e.g. --to $repo_path"
    _rm_is_inside "$dest" "$target" && die_with_hints "--to: inside the worktree being removed: $dest" "pass a directory outside $target"
  fi
  # Capture the branch name before the worktree is removed — afterwards there is nothing
  # left at $target to ask git about.
  branch="$(git -C "$target" branch --show-current 2>/dev/null || true)"
  local -i interactive=0
  prompt_available && interactive=1

  info "removing worktree"; print -r -- "  path: $target"; [[ -n "$branch" ]] && print -r -- "  branch: $branch"
  git -C "$target" status --short --branch | sed 's/^/  /'

  # A single probe decides everything below (_worktree_dirt_kind). Calling it twice under two
  # different names for two different questions ("is it dirty" / "is any of that dirt outside
  # .idea/") would each run their own `git status`, and a SECOND probe could fail independently
  # of the first: if that happened here, a probe failure reaching the idea-only branch would
  # get silently discarded as "just .idea/ dirt" without --force -- exactly the false-accept
  # this function exists to prevent.
  # Named dirt_kind, NOT kind: `kind` is already a local holding the ticket's kind (e.g.
  # "fix") above. Reusing that name here for the dirt-classification result
  # once caused a genuine zsh quirk: re-declaring an already-local, already-assigned
  # variable with a bare `local kind` (no `=`) makes zsh PRINT "kind=fix" to stdout instead
  # of silently shadowing it -- caught by inspecting real command output during
  # verification, not by any test.
  local dirt_kind
  _worktree_dirt_kind "$target"; dirt_kind="$REPLY"

  local -i idea_only=0
  if [[ "$dirt_kind" == unknown ]]; then
    # R26: do not narrow the fail-closed rule (a benign warning and a real problem both
    # reduce to "git status exited nonzero or wrote to stderr", and any allowlist to tell
    # them apart is brittle across git versions/locales) -- instead make the refusal
    # honest. Show git's actual stderr so the user can judge for themselves, and don't
    # claim --force will fix anything: for a chmod-000 subdirectory it won't (`git
    # worktree remove --force` still can't unlink through a directory it can't read), so
    # promising that remedy would be a lie the user discovers the hard way.
    if (( force_remove )); then
      warn "could not verify worktree status (git status exited $WT_DIRT_RC); proceeding only because --force was given. git said:"
      _wt_indent_and_cap "$WT_DIRT_DETAIL"
    else
      die_with_hints $'could not verify worktree status (git status exited '"$WT_DIRT_RC"$'); refusing to guess whether it is safe to remove. git said:
'"$(_wt_indent_and_cap "$WT_DIRT_DETAIL")"$'
(--force overrides this refusal, but may not resolve the underlying problem)' \
        "if git reports an unreadable directory, restore access (e.g. chmod -R u+rwX $target) and retry"
    fi
  elif [[ "$dirt_kind" == real ]] || has_dirty_submodule "$target"; then
    if (( ! force_remove )); then
      local -a dirty_hints
      dirty_hints=("keep the work: commit it, or stash it with: git -C $target stash -u" "discard it: re-run with --force")
      (( interactive )) || die_with_hints "worktree has changes outside .idea/ (or a dirty submodule); use --force to remove" "${dirty_hints[@]}"
      warn "worktree has changes outside .idea/ (or a dirty submodule)"
      if prompt_confirm "discard these changes and force-remove the worktree?" n; then
        force_remove=1
      else
        local h; for h in "${dirty_hints[@]}"; do hint "$h"; done
        exit 130
      fi
    fi
  elif [[ "$dirt_kind" == idea-only ]]; then
    idea_only=1
    warn "worktree only has IDE state under .idea/ — discarding it:"; print -r -- "$WT_DIRT_DETAIL" | sed 's/^/  /'
  fi

  local remote="" rbranch=""
  if [[ -n "$branch" ]] && (( interactive || delete_remote )); then
    wt_fetch_origin "$repo_path"
    _wt_remote_branch "$repo_path" "$branch" && { remote="${reply[1]}" rbranch="${reply[2]}"; }
  fi
  local -i merged=0
  [[ -n "$branch" ]] && git -C "$repo_path" merge-base --is-ancestor "refs/heads/$branch" HEAD 2>/dev/null && merged=1

  if (( interactive )) && [[ -n "$branch" ]]; then
    if (( ! delete_branch )); then
      if (( merged )); then prompt_confirm "delete local branch '$branch'? (merged)" y && delete_branch=1
      else prompt_confirm "delete local branch '$branch'? (not merged)" n && delete_branch=1; fi
    fi
    if (( delete_branch && ! force_branch && ! merged )); then
      if prompt_confirm "'$branch' has unmerged commits that would be lost — force-delete it?" n; then force_branch=1
      else delete_branch=0; fi
    fi
    if (( ! delete_remote )) && [[ -n "$remote" ]]; then
      prompt_confirm "delete remote branch '$remote/$rbranch' too? (pushes a delete to $remote)" n && delete_remote=1
    fi
  fi
  if (( delete_remote )) && [[ -z "$remote" ]]; then
    warn "no remote branch known for '${branch:-(detached HEAD)}'; skipping remote delete"
    hint "if it exists upstream, refresh tracking refs first: git -C $repo_path fetch --all"
    delete_remote=0
  fi
  (( interactive && WT_CAN_CD && ! to_given )) && { _rm_pick_destination "$target" "$repo_path"; dest="$REPLY"; }
  [[ -z "$dest" ]] && _rm_is_inside "$PWD" "$target" && dest="$repo_path"

  if (( interactive )); then
    local branch_plan="keep" remote_plan="keep"
    (( delete_branch )) && branch_plan="delete" && (( force_branch )) && branch_plan="force-delete"
    [[ -z "$remote" ]] && remote_plan="none known"
    (( delete_remote )) && remote_plan="delete"
    ui_rule plan
    printf '  %-14s %-14s %s\n' "worktree" "remove$( (( force_remove )) && print -n ' (force)')" "$target" \
      "local branch" "$branch_plan" "${branch:-(detached HEAD)}" \
      "remote branch" "$remote_plan" "${remote:+$remote/$rbranch}"
    [[ -n "$dest" ]] && printf '  %-14s %s\n' "then move to" "$dest"
    prompt_confirm "Proceed?" y || exit 130
  fi

  local -i step=0 total=$(( 1 + delete_branch + delete_remote ))
  local -a results
  # The caller's cwd may be the worktree about to be deleted; leave it first so nothing
  # spawned after the removal starts in a vanished directory.
  builtin cd -- "$repo_path" 2>/dev/null
  ui_progress $(( ++step )) $total "removing worktree"
  local -a remove_hints
  remove_hints=("if the worktree is locked: git -C $repo_path worktree unlock $target"
    "close editors or shells holding files inside it, then retry"
    "check git's view of it: git -C $repo_path worktree list")
  if (( force_remove || idea_only )) || has_initialized_submodules "$target"; then
    git -C "$repo_path" worktree remove --force "$target" || die_with_hints "failed to remove worktree" "${remove_hints[@]}"
  else
    git -C "$repo_path" worktree remove "$target" || die_with_hints "failed to remove worktree" "${remove_hints[@]}"
  fi
  git -C "$repo_path" worktree prune 2>/dev/null
  [[ -e "$target" ]] && { warn "worktree dir lingered after remove; deleting leftover: $target"; rm -rf "$target"; }
  success "removed: $target"
  results+=("ok"$'\t'"worktree       removed       $target")

  if (( delete_branch )); then
    ui_progress $(( ++step )) $total "deleting local branch $branch"
    if remove_branch "$repo_path" "$branch" "$force_branch"; then results+=("ok"$'\t'"local branch   deleted       $branch")
    else results+=("fail"$'\t'"local branch   not deleted   ${branch:-(detached HEAD)}"); fi
  else
    results+=("skip"$'\t'"local branch   kept          ${branch:-(detached HEAD)}")
  fi
  if (( delete_remote )); then
    ui_progress $(( ++step )) $total "deleting remote branch $remote/$rbranch"
    if remove_remote_branch "$repo_path" "$remote" "$rbranch"; then results+=("ok"$'\t'"remote branch  deleted       $remote/$rbranch")
    else results+=("fail"$'\t'"remote branch  not deleted   $remote/$rbranch"); fi
  elif [[ -n "$remote" ]]; then
    results+=("skip"$'\t'"remote branch  kept          $remote/$rbranch")
  fi

  _rm_print_results "${results[@]}"
  if [[ -n "$dest" ]]; then
    (( WT_CAN_CD )) && print -r -- "  → moving to     $dest"
    print -u $out_fd -r -- "$dest"
  fi
  return 0
}

# cmd_project: manage [project] sections. Deliberately does NOT call require_config -- there
# may be no config file yet at all, and `project add` is exactly how the first one gets
# created. (`repo add`, by contrast, needs an existing project to attach to and does call
# require_config -- see lib/cmd/repo.zsh.)
cmd_project() {
  setopt localoptions extendedglob
  local sub="${1:-list}"; (( $# )) && shift
  case "$sub" in
    list)
      (( ${#WT_PROJECTS} )) || { warn "no projects (run 'workytree project add <name> <repo_root> <worktree_root>')"; return 0; }
      local p mark def; def="$(default_project)"
      for p in "${WT_PROJECTS[@]}"; do
        [[ "$p" == "$def" ]] && mark="*" || mark=" "
        printf '%s %-16s repo_root=%s  worktree_root=%s\n' "$mark" "$p" "$(project_repo_root "$p")" "$(project_worktree_root "$p")"
      done ;;
    add)
      (( $# == 3 )) || usage_error "usage: workytree project add <name> <repo_root> <worktree_root>"
      local name="$1" rr="$2" wr="$3"
      [[ "$name" == [A-Za-z0-9_-]## ]] || usage_error "invalid project name: $name (use letters, digits, - and _)"
      [[ -n "$rr" ]] || usage_error "repo_root must not be empty"
      [[ -n "$wr" ]] || usage_error "worktree_root must not be empty"

      # R27: validate BOTH paths up front, before writing anything -- a project add that
      # fails partway through would otherwise leave a section on disk missing one of the two
      # keys require_config demands of every [project]. expand_path mirrors config_get's own
      # normalization (trailing-slash strip etc.), so "repo_root = /" style values that
      # collapse to "" are caught here exactly the way require_config would catch them later.
      local rr_exp wr_exp wr_canon
      rr_exp="$(expand_path "$rr")"
      wr_exp="$(expand_path "$wr")"
      [[ -n "$rr_exp" ]] || die "repo_root resolves to an empty/unusable path: $rr"
      [[ -n "$wr_exp" ]] || die "worktree_root resolves to an empty/unusable path: $wr"

      # R30: refuse an unsafe worktree_root ("/" or a strict ancestor of $HOME) here, at add
      # time, rather than writing it and letting the user discover the problem only when
      # `prune` (or anything else routed through require_config) later refuses to run.
      # is_safe_worktree_root is the SAME function require_config itself calls (lib/resolve.zsh)
      # -- one source of truth for the rule, not a second copy that could drift from it.
      wr_canon="${wr_exp:A}"
      is_safe_worktree_root "$wr_canon" || die "unsafe worktree_root: \"$wr\" (resolves to \"$wr_canon\"): refusing \"/\" or a strict ancestor of the home directory (\"${HOME:A}\")"

      # R27, recovery half: a project section can already exist on disk with only ONE of
      # repo_root/worktree_root set, if a previous `add` was interrupted between its two
      # config_set calls (config_set writes one key at a time -- there is no atomic "write
      # both keys" primitive in lib/config.zsh). Refuse only a genuinely COMPLETE duplicate;
      # an incomplete one is repaired by writing both keys again, same as a fresh add. Either
      # way -- whichever key was missing before this call, and regardless of which key this
      # call's own config_set writes first -- a run that is itself interrupted again still
      # leaves require_config's "missing repo_root/worktree_root" check to fail closed on the
      # next command, never a config that silently looks complete but isn't.
      if project_exists "$name"; then
        if [[ -n "${WT_PCFG[$name.repo_root]:-}" && -n "${WT_PCFG[$name.worktree_root]:-}" ]]; then
          die "project already exists: $name"
        fi
        warn "project '$name' exists but is incomplete (a previous 'project add' may have been interrupted); completing it"
      fi
      config_set "project.$name.repo_root" "$rr"
      config_set "project.$name.worktree_root" "$wr"
      [[ -n "${WT_CFG[default_project]:-}" ]] || config_set default_project "$name"
      success "added project $name (repo_root=$rr_exp, worktree_root=$wr_exp)" ;;
    remove)
      (( $# == 1 )) || usage_error "usage: workytree project remove <name>"
      project_exists "$1" || die "unknown project: $1"
      # Dangling [repo] -> project references: refuse rather than cascade-delete or leave a
      # repo pointing at a project that no longer exists. A repo whose project vanished would
      # make project_repo_root/project_worktree_root resolve to "" for it everywhere
      # downstream (WT_PCFG has no entries for a removed project), turning what should be a
      # clear error into silently-empty paths. Cascading the delete instead risks discarding a
      # repo registration the user did not ask to lose. Refusing keeps the fix explicit and
      # reversible: `workytree repo remove <name>` (or re-point it) first.
      local -a blockers; local r
      for r in "${WT_REPOS[@]}"; do
        [[ "${WT_RCFG[$r.project]:-}" == "$1" ]] && blockers+=("$r")
      done
      (( ${#blockers} == 0 )) || die "cannot remove project '$1': repos still reference it (${(j:, :)blockers}); run 'workytree repo remove <name>' first"
      config_remove_section project "$1"
      if [[ "${WT_CFG[default_project]:-}" == "$1" ]]; then
        if (( ${#WT_PROJECTS} )); then config_set default_project "${WT_PROJECTS[1]}"; else config_unset default_project; fi
      fi
      success "removed project $1" ;;
    default)
      (( $# == 1 )) || usage_error "usage: workytree project default <name>"
      project_exists "$1" || die "unknown project: $1"
      config_set default_project "$1"; success "default project: $1" ;;
    *) usage_error "usage: workytree project list|add <name> <repo_root> <worktree_root>|remove <name>|default <name>" ;;
  esac
}

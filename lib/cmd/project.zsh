# _wt_project_add_check_root <label> <raw>: R31 wrapper around _wt_root_value_problem
# (lib/resolve.zsh) for `project add`'s own up-front validation -- same substantive checks
# require_config runs against an already-loaded config, but reported as an argument error (exit
# 1 die, or exit 2 usage_error for a literally-blank argument) rather than exit 3 (which is
# reserved for describing the state of an already-written config file). Returns normally (no
# problem) or exits the process -- never used inside a command substitution.
_wt_project_add_check_root() {
  local label="$1" raw="$2"
  _wt_root_value_problem "$raw"
  case "$REPLY_PROBLEM" in
    empty)    usage_error "$label must not be empty" ;;
    unset)    die "$label references an unset variable \$$REPLY_DETAIL (\"$raw\")" ;;
    unusable) die "$label resolves to an empty/unusable path: $raw" ;;
    relative) die "$label is not an absolute path after expansion (\"$raw\" resolves to \"$REPLY_DETAIL\"); use an absolute path (\"/...\"), \"~/...\", or a variable (e.g. \"\$HOME/...\") that expands to one" ;;
  esac
}

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

      # R27/R32: validate BOTH raw values up front, before writing anything -- a project add
      # that fails partway through would otherwise leave a section on disk missing one of the
      # two keys require_config demands of every [project]. _wt_root_value_problem
      # (lib/resolve.zsh) is the SAME diagnosis require_config itself runs against an
      # already-loaded config -- one source of truth for what counts as a usable root value,
      # not a second copy that could drift from it. Exit codes differ by design (R31): a bad
      # ARGUMENT here is exit 1/2, while require_config's exit 3 describes the state of the
      # config FILE -- collapsing the two would stop a script from telling "the value you just
      # typed is bad" apart from "your stored config is broken".
      _wt_project_add_check_root repo_root "$rr"
      _wt_project_add_check_root worktree_root "$wr"

      local rr_exp wr_exp rr_canon wr_canon
      rr_exp="$(expand_path "$rr")"
      wr_exp="$(expand_path "$wr")"
      rr_canon="${rr_exp:A}"
      wr_canon="${wr_exp:A}"

      # R30: refuse an unsafe worktree_root ("/" or a strict ancestor of $HOME) here, at add
      # time, rather than writing it and letting the user discover the problem only when
      # `prune` (or anything else routed through require_config) later refuses to run.
      # is_safe_worktree_root is the SAME function require_config itself calls (lib/resolve.zsh)
      # -- one source of truth for the rule, not a second copy that could drift from it.
      is_safe_worktree_root "$wr_canon" || die "unsafe worktree_root: \"$wr\" (resolves to \"$wr_canon\"): refusing \"/\" or a strict ancestor of the home directory (\"${HOME:A}\")"

      # Overlap: not refused (a nested layout can be deliberate) but never silent -- an
      # overlapping repo_root/worktree_root makes scan_project_repos's "-mindepth 2" scan
      # either pick up worktrees as if they were clones, or (repo_root == worktree_root) find
      # nothing at all with no indication why. Warn, naming the exact overlap.
      if [[ "$rr_canon" == "$wr_canon" ]]; then
        warn "project '$name': repo_root and worktree_root are the SAME directory (\"$rr_canon\"); the repo scan will not find anything usable there -- consider separate directories"
      elif [[ "$wr_canon" == "$rr_canon"/* ]]; then
        warn "project '$name': worktree_root (\"$wr_canon\") is nested inside repo_root (\"$rr_canon\"); the repo scan may pick up worktrees as if they were clones -- consider separate directories"
      elif [[ "$rr_canon" == "$wr_canon"/* ]]; then
        warn "project '$name': repo_root (\"$rr_canon\") is nested inside worktree_root (\"$wr_canon\"); pruning may reach directories that hold real clones -- consider separate directories"
      fi

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
      # A default_project naming a project that no longer exists (e.g. a hand-edited config,
      # or the project it named was removed) is treated as UNSET for this purpose -- otherwise
      # a dangling default_project is never repaired short of the user running `project
      # default` by hand, and `project list`'s "*" marker never appears again.
      local cur_default="${WT_CFG[default_project]:-}"
      if [[ -z "$cur_default" ]] || ! project_exists "$cur_default"; then
        config_set default_project "$name"
      fi
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

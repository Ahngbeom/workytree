# Candidate sources for shell completion. One candidate per line; never fails loudly --
# shell/completions/_workytree is the only consumer, and a `die`/error dumped mid-TAB would
# corrupt the user's completion menu. Every branch below degrades to "no candidates" instead
# of erroring on a missing/broken config; only an unknown `what` is a real usage error (exit
# 2), since that reflects a bug in the completion file itself, not user config state.
#
# R16: never name a local `path` (or fpath/cdpath/status/argv/options/watch/SECONDS) -- zsh
# ties `path` to $PATH even as a local, and a stray assignment here would corrupt the
# completion process's PATH for every subprocess it spawns afterward.
cmd___complete() {
  local what="${1:-}"; (( $# )) && shift
  case "$what" in
    commands)
      print -l init create remove prune list repos path cd project repo config help ;;
    projects)
      (( WT_CONFIG_EXISTS )) && print -l -- "${WT_PROJECTS[@]}" ;;
    repos)
      (( WT_CONFIG_EXISTS )) && all_repos "$WT_PROJECT_OPT" 2>/dev/null | cut -f1 ;;
    kinds)
      local repo="${1:-}" r parent
      if (( WT_CONFIG_EXISTS )) && [[ -n "$repo" ]] && r="$(resolve_repo "$repo" 2>/dev/null)"; then
        parent="$(worktree_parent "${r%%$'\t'*}" "$repo")"
        [[ -d "$parent" ]] && find "$parent" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null
      fi
      (( WT_CONFIG_EXISTS )) && config_kinds ;;
    tickets)
      local repo="${1:-}" kind="${2:-}" r parent
      [[ -n "$repo" && -n "$kind" ]] || return 0
      (( WT_CONFIG_EXISTS )) || return 0
      r="$(resolve_repo "$repo" 2>/dev/null)" || return 0
      parent="$(worktree_parent "${r%%$'\t'*}" "$repo" "$kind")"
      [[ -d "$parent" ]] && find "$parent" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort ;;
    branches)
      local repo="${1:-}" r
      [[ -n "$repo" ]] || return 0
      (( WT_CONFIG_EXISTS )) || return 0
      r="$(resolve_repo "$repo" 2>/dev/null)" || return 0
      git -C "${r#*$'\t'}" branch --all --format='%(refname:short)' 2>/dev/null | sed 's#^remotes/##' | awk '!seen[$0]++' ;;
    *)
      usage_error "usage: workytree __complete commands|projects|repos|kinds <repo>|tickets <repo> <kind>|branches <repo>" ;;
  esac
  return 0
}

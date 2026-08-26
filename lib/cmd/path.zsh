cmd_path() {
  require_config
  local r toplevel
  case $# in
    0) infer_current_repo >/dev/null || die "not inside a workytree project (run 'workytree repos')"
       toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" \
         || die "not inside a git work tree (bare repos and .git/ have no working tree to show)"
       print -r -- "$toplevel" ;;
    1) r="$(resolve_repo "$1")" || exit $?; print -r -- "${r#*$'\t'}" ;;
    2) r="$(resolve_repo "$1")" || exit $?; worktree_parent "${r%%$'\t'*}" "$1" "$2" ;;
    3) r="$(resolve_repo "$1")" || exit $?; worktree_path "${r%%$'\t'*}" "$1" "$2" "$3" ;;
    *) usage_error "usage: workytree path [repo [kind [ticket]]]" ;;
  esac
}
cmd_cd() { cmd_path "$@"; }

# workytree shell integration — source this from ~/.zshrc.
# Defines workytree() (and wt() unless disabled) so `create`/`cd` can change the caller's
# directory. bin/workytree is a pure CLI (computes, prints, never cd's); for `create`/`cd`
# the LAST stdout line is the resulting path (see bin/workytree's header comment) — this
# wrapper captures stdout, replays everything except that last line, and `builtin cd`s to it
# when running interactively. :A resolves a symlink (the installer creates ~/.local/bin/wt*
# as a symlink, or sources this file through one), so WORKYTREE_ROOT still lands on the real
# install directory rather than the symlink's own parent.
typeset -g WORKYTREE_ROOT="${${(%):-%x}:A:h:h}"
typeset -g WORKYTREE_BIN="$WORKYTREE_ROOT/bin/workytree"

workytree() {
  case "${1:-}" in
    create|cd) ;;
    *) "$WORKYTREE_BIN" "$@"; return $? ;;
  esac
  local output exit_code target head
  if [[ "$1" == cd ]]; then output="$("$WORKYTREE_BIN" path "${@:2}")"; else output="$("$WORKYTREE_BIN" "$@")"; fi
  exit_code=$?
  # Split "everything except the last line" from "the last line" without a `path`/`fpath`
  # local (R16: `path` is tied to $PATH in zsh, even as a local). Works for empty output, a
  # single-line output (target only), and multi-line output (info lines + target).
  if [[ -n "$output" ]]; then
    target="${output##*$'\n'}"
    head="${output%"$target"}"; head="${head%$'\n'}"
    [[ -n "$head" ]] && print -r -- "$head"
  fi
  (( exit_code == 0 )) || return $exit_code
  if [[ -o interactive && -n "$target" && -d "$target" ]]; then
    builtin cd -- "$target" || return 1
    print -P "%F{70}cd:%f $target"
  elif [[ -n "$target" ]]; then
    print -r -- "$target"
  fi
  return 0
}

# _workytree_alias_enabled: should `wt()` be installed? R8: this must NOT parse the config
# file itself — lib/config.zsh is the single owner of that format, so duplicating its
# grammar here (comments, quoting, section scoping) would just be a second, divergent
# parser waiting to disagree with the first. Ask the CLI instead; a non-zero exit (key
# unset, or no config file at all) means "default enabled", same as bin/workytree's own
# `alias_wt` default.
_workytree_alias_enabled() {
  [[ "${WORKYTREE_ALIAS:-1}" == 0 ]] && return 1
  local val
  val="$("$WORKYTREE_BIN" config get alias_wt 2>/dev/null)" || return 0
  case "${val:l}" in
    false|0|no) return 1 ;;
    *) return 0 ;;
  esac
}

if _workytree_alias_enabled; then
  if (( $+commands[wt] || $+functions[wt] || $+aliases[wt] )); then
    print -u2 "workytree: 'wt' is already defined; not installing the alias (set 'alias_wt = false' to silence)"
  else
    wt() { workytree "$@"; }
  fi
fi

_workytree_register_completion() {
  (( $+functions[compdef] )) || return 0
  local dir="$WORKYTREE_ROOT/shell/completions"
  [[ -d "$dir" ]] || return 0
  (( ${fpath[(Ie)$dir]} )) || fpath=("$dir" $fpath)
  autoload -Uz _workytree 2>/dev/null || return 0
  compdef _workytree workytree
  (( $+functions[wt] )) && compdef _workytree wt
}
_workytree_register_completion

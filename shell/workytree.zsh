# workytree shell integration — source this from ~/.zshrc. Defines workytree() (and wt())
# so create/cd/remove/status can move the caller's shell: bin/workytree prints the path as its
# last stdout line, and workytree() cds there. Modes and the CLI protocol: docs/superpowers/
# specs/2026-10-23-noninteractive-ux-design.md.
typeset -g WORKYTREE_ROOT="${${(%):-%x}:A:h:h}"
typeset -g WORKYTREE_BIN="$WORKYTREE_ROOT/bin/workytree"

# workytree() must not call a `_`-prefixed helper or rely on a non-exported global: shell
# snapshots (Claude Code's Bash tool) keep only workytree() and wt(). No `emulate -L`: it would
# drop the caller's cd options (auto_pushd, chase_links) for the final cd.
workytree() {
  setopt localoptions noksharrays noshwordsplit
  local bin="${WORKYTREE_BIN:-}"
  [[ -n "$bin" && -x "$bin" ]] || bin="${commands[workytree]:-}"
  if [[ -z "$bin" ]]; then
    print -u2 -r -- "workytree: not found on PATH (install it, or set WORKYTREE_BIN)"
    return 127
  fi
  local mode=script
  if [[ -o interactive ]]; then
    if [[ -t 1 ]]; then mode=terminal
    elif (( ZSH_SUBSHELL )); then mode=captured
    else mode=redirected; fi
  fi
  # Mirrors parse_global_opts and cmd_create token for token: the first token that is not a
  # global option is the subcommand, and `--` ends create's own flags.
  local sub="" a
  local -i skip=0 dashdash=0 want_ai=0 no_ai=0 plain=0
  for a in "$@"; do
    [[ "$a" == --no-color ]] && plain=1
    if (( skip )); then skip=0
    elif [[ -z "$sub" ]]; then
      case "$a" in
        --project) skip=1 ;;
        --project=*|--yes|-y|--no-color) ;;
        *) sub="$a" ;;
      esac
    elif (( ! dashdash )); then
      case "$a" in
        --) dashdash=1 ;;
        --ai) want_ai=1 ;;
        --no-ai) no_ai=1 ;;
      esac
    fi
  done
  local ai_skip=""
  if [[ "$sub" == create ]]; then
    if (( no_ai )); then ai_skip=no-ai
    elif [[ "$mode" != terminal ]]; then ai_skip=$mode
    elif [[ ! -t 0 ]]; then ai_skip=stdin
    elif (( ! want_ai && ! ${_WORKYTREE_AI_CONFIGURED:-0} )); then ai_skip=startup
    fi
  fi
  if [[ "$mode" == script || "$sub" != (create|cd|remove|status) ]]; then
    WORKYTREE_SHELL=$mode WORKYTREE_AI_SKIP=$ai_skip "$bin" "$@"
    return
  fi

  local runfile="" output target
  local -i rc
  {
    if [[ "$sub" == create && -z "$ai_skip" ]]; then
      runfile="$(command mktemp "${TMPDIR:-/tmp}/workytree-ai.XXXXXX" 2>/dev/null)" || { runfile=""; ai_skip=tmp; }
    fi
    output="$(WORKYTREE_SHELL=$mode WORKYTREE_AI_RUNFILE=$runfile WORKYTREE_AI_SKIP=$ai_skip "$bin" "$@")"
    rc=$?
    if (( rc )); then
      [[ -n "$output" ]] && print -r -- "$output"
      return $rc
    fi
    target="${output##*$'\n'}"
    [[ "$output" == *$'\n'* ]] && print -r -- "${output%$'\n'*}"
    if [[ -z "$target" || ! -d "$target" ]]; then
      [[ -n "$target" ]] && print -r -- "$target"
      return 0
    fi
    builtin cd -- "$target" || return 1
    if [[ "$mode" != terminal ]]; then
      print -r -- "$target"
    elif (( ! plain )) && [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then
      print -r -- $'\e[38;5;70mcd:\e[0m '"$target"
    else
      print -r -- "cd: $target"
    fi
    if [[ -n "$runfile" && -s "$runfile" ]]; then
      local -a ai_cmd; ai_cmd=( ${(f)"$(<"$runfile")"} )
      command rm -f -- "$runfile"
      (( ${#ai_cmd} )) && "${ai_cmd[@]}"
    fi
    return 0
  } always {
    [[ -n "$runfile" ]] && command rm -f -- "$runfile"
    if [[ ! -d "$PWD" ]]; then
      local up="${PWD:h}"
      while [[ "$up" != / && ! -d "$up" ]]; do up="${up:h}"; done
      builtin cd -- "$up" 2>/dev/null \
        && print -u2 -r -- "workytree: your shell's directory was removed; moved to $up"
    fi
  }
}

# R35: this file must NOT contain a literal `wt() { ... }` anywhere, even inside a branch
# that will not run. zsh parses an entire if/else block at PARSE time, before deciding which
# branch executes -- so if the caller already has `wt` defined as an ALIAS, the parser sees
# `wt() {` while `wt` still names that alias and throws a raw "defining function based on
# alias `wt'" / "parse error near `()'" error at SOURCE time, unconditionally, regardless of
# which branch would actually run. Assigning to zsh's `functions` special array is a plain
# string assignment (`functions[wt]=...`), not `name() { ... }` syntax, so it never triggers
# that alias/function collision; `eval`-ing a `wt() { ... }` string would dodge the same
# parse-time issue but reads far less obviously than a documented special array.
typeset -g _WORKYTREE_WT_BODY='workytree "$@"'

# _workytree_wt_is_ours: true if `wt` is currently a FUNCTION whose body is exactly what this
# file would install. R37: an earlier version of this file tracked a boolean "did I install
# `wt` at some point in this shell" flag -- that answers the wrong question. It stays true
# forever once set, so re-sourcing after something ELSE redefined `wt` (another plugin, or
# the user) silently clobbered that redefinition with no warning, defeating the exact
# guarantee this file exists to provide. Comparing bodies answers "is THIS wt still mine"
# instead, and needs no persisted state at all -- it is recomputed fresh, from what zsh
# currently reports, on every source. Compares against zsh's own NORMALIZED form of the body
# (writing the identical string to a throwaway function name and reading it back), not the
# raw source string this file writes -- verified empirically that zsh reformats a function
# body when storing it (`${functions[name]}` comes back with a leading tab, whether the
# function was defined via `functions[name]=...` or a literal `name() { ... }`), so comparing
# against the literal string above would never match.
_workytree_wt_is_ours() {
  (( $+functions[wt] )) || return 1
  functions[_workytree_wt_probe]="$_WORKYTREE_WT_BODY"
  local -i is_ours=0
  [[ "${functions[wt]}" == "${functions[_workytree_wt_probe]}" ]] && is_ours=1
  unfunction _workytree_wt_probe
  return $(( ! is_ours ))
}

typeset -gi _WORKYTREE_AI_CONFIGURED=0
() {
  local init alias_msg="workytree: 'wt' is already defined; not installing the alias (set 'alias_wt = false' or WORKYTREE_ALIAS=0 to silence)"
  local -i want_alias=1 cfg_err=0
  if [[ -o interactive ]]; then
    init=" $("$WORKYTREE_BIN" __shell-init 2>/dev/null) "
    [[ "$init" == *" ai=1 "* ]] && _WORKYTREE_AI_CONFIGURED=1
    [[ "$init" == *" alias=0 "* ]] && want_alias=0
    if [[ "$init" == *" config=error "* ]]; then
      cfg_err=1
      print -u2 -r -- "workytree: config has errors; run 'workytree list' to see them"
    fi
  fi
  [[ "${WORKYTREE_ALIAS:-1}" == 0 ]] && want_alias=0
  (( want_alias )) || return 0
  if (( $+functions[wt] )) && _workytree_wt_is_ours; then
    functions[wt]="$_WORKYTREE_WT_BODY"
  elif (( $+functions[wt] || $+commands[wt] || $+aliases[wt] )); then
    (( cfg_err )) || print -u2 -r -- "$alias_msg"
  else
    functions[wt]="$_WORKYTREE_WT_BODY"
  fi
}

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

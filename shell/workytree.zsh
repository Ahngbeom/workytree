# workytree shell integration — source this from ~/.zshrc.
# Defines workytree() (and wt() unless disabled) so `create`/`cd` can change the caller's
# directory. bin/workytree is a pure CLI (computes, prints, never cd's); for `create`/`cd`
# the LAST stdout line is the resulting path (see bin/workytree's header comment) — this
# wrapper captures stdout, replays everything except that last line, and `builtin cd`s to it
# when running interactively. :A resolves a symlink (the installer creates
# ~/.local/bin/workytree as a symlink to bin/workytree; `wt` itself is never a symlink, only
# the function this file defines below), so WORKYTREE_ROOT still lands on the real install
# directory rather than the symlink's own parent.
typeset -g WORKYTREE_ROOT="${${(%):-%x}:A:h:h}"
typeset -g WORKYTREE_BIN="$WORKYTREE_ROOT/bin/workytree"

# _workytree_locate_subcommand <args...>: prints the 1-based index of the first token that
# isn't one of bin/workytree's own global options, or 0 if every token is consumed as an
# option (no subcommand present). Mirrors bin/workytree's parse_global_opts token-for-token
# (a bare --project consumes the NEXT token as its value; --project=value/--yes/-y/--no-color
# are each a single token) so the wrapper and the CLI always agree on which token is the
# subcommand. R34: the CLI accepts these options in ANY position -- a wrapper that only ever
# looked at "$1" would silently skip the auto-cd for e.g. `wt --project foo create ...`.
_workytree_locate_subcommand() {
  local -i i=1 skip=0
  local a
  for a in "$@"; do
    if (( skip )); then
      skip=0
    else
      case "$a" in
        --project)              skip=1 ;;
        --project=*|--yes|-y|--no-color) ;;
        *) print -r -- "$i"; return 0 ;;
      esac
    fi
    (( i++ ))
  done
  print -r -- 0
}

workytree() {
  local -i sub_idx
  sub_idx="$(_workytree_locate_subcommand "$@")"
  local sub=""
  (( sub_idx > 0 )) && sub="${@[$sub_idx]}"
  case "$sub" in
    create|cd) ;;
    *) "$WORKYTREE_BIN" "$@"; return $? ;;
  esac
  local -a call_args; call_args=("$@")
  # cd's output is byte-identical to path's today (lib/cmd/path.zsh: `cmd_cd() { cmd_path
  # "$@"; }`), but "path" is the name documented as script-safe, so substitute it in place of
  # whichever token _workytree_locate_subcommand found -- not necessarily "$1", now that
  # global options can precede it (R34). A future divergence between cmd_cd and cmd_path then
  # stays the CLI's decision, not a side effect of which subcommand name the wrapper happened
  # to invoke.
  [[ "$sub" == cd ]] && call_args[$sub_idx]=path
  # AI-session launch channel. bin/workytree never runs the agent itself -- it only writes
  # "what to run" into this file. That keeps the CLI pure, while the TTY an interactive
  # agent needs comes from here instead. The file is created by this function and removed
  # by this function: if the CLI did its own mktemp, who removes it and when would become
  # unclear, and the file would be left behind whenever the CLI process died.
  #
  # An EXIT trap set inside a zsh function is local to that function and fires when the
  # function returns -- the agent runs inside this function, so the trap fires after it.
  # rm -f is idempotent, so the explicit removal below and the trap firing again afterward
  # (already gone) is harmless.
  local runfile=""
  if [[ "$sub" == create ]]; then
    runfile="$(command mktemp "${TMPDIR:-/tmp}/workytree-ai.XXXXXX" 2>/dev/null)" || runfile=""
    [[ -n "$runfile" ]] && trap 'command rm -f -- "$runfile"' EXIT
  fi

  local output exit_code target head
  if [[ -n "$runfile" ]]; then
    output="$(WORKYTREE_AI_RUNFILE="$runfile" "$WORKYTREE_BIN" "${call_args[@]}")"
  else
    output="$("$WORKYTREE_BIN" "${call_args[@]}")"
  fi
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
    # Run after the cd -- the agent must see the new worktree as its cwd. A plain call, not
    # exec, so quitting the agent returns the user to a shell inside that worktree.
    if [[ -n "$runfile" && -s "$runfile" ]]; then
      local -a ai_cmd; ai_cmd=( ${(f)"$(<"$runfile")"} )
      command rm -f -- "$runfile"
      (( ${#ai_cmd} )) && "${ai_cmd[@]}"
    fi
  elif [[ -n "$target" ]]; then
    print -r -- "$target"
  fi
  # create still succeeds even if the agent exits nonzero -- the worktree was created, and
  # that fact was already reported to the user.
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

if _workytree_alias_enabled; then
  if (( $+functions[wt] )); then
    if _workytree_wt_is_ours; then
      # Double-sourced (R36), or a fresh shell that happens to already have an identical
      # `wt` -- either way this is ours, so reassert it silently rather than warn.
      functions[wt]="$_WORKYTREE_WT_BODY"
    else
      print -u2 "workytree: 'wt' is already defined; not installing the alias (set 'alias_wt = false' to silence)"
    fi
  elif (( $+commands[wt] || $+aliases[wt] )); then
    print -u2 "workytree: 'wt' is already defined; not installing the alias (set 'alias_wt = false' to silence)"
  else
    # Nothing defined at all -- including the case where `wt` was ours but got removed
    # entirely (e.g. `unfunction wt`); there's nothing foreign here to protect.
    functions[wt]="$_WORKYTREE_WT_BODY"
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

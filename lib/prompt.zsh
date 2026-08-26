# Interactive prompts. Input comes from WORKYTREE_PROMPT_INPUT (tests) or /dev/tty; prompts are
# written to /dev/tty (or stderr under WORKYTREE_PROMPT_INPUT) so $(...) capture of stdout stays clean.
typeset -gi WT_PROMPT_FD=-1

prompt_available() {
  [[ -n "${WORKYTREE_PROMPT_INPUT:-}" ]] && return 0
  (( WT_YES )) && return 1
  [[ -t 0 ]] || return 1
  { : < /dev/tty; } 2>/dev/null
}

_prompt_open() {
  (( WT_PROMPT_FD >= 0 )) && return 0
  exec {WT_PROMPT_FD}< "${WORKYTREE_PROMPT_INPUT:-/dev/tty}" || die "cannot open prompt input"
}
_prompt_say() {
  if [[ -n "${WORKYTREE_PROMPT_INPUT:-}" ]]; then print -n -r -- "$@" >&2; else print -n -r -- "$@" > /dev/tty; fi
}
_prompt_read() {
  _prompt_open
  if ! read -u $WT_PROMPT_FD -r REPLY; then _prompt_say $'\n'; exit 130; fi
  [[ "$REPLY" == q ]] && exit 130
}

# prompt_confirm <msg> [y|n] -> rc 0 yes / 1 no
prompt_confirm() {
  local msg="$1" def="${2:-y}" hint
  [[ "$def" == y ]] && hint="[Y/n]" || hint="[y/N]"
  while true; do
    _prompt_say "$msg $hint "; _prompt_read
    case "${REPLY:l}" in
      "")   [[ "$def" == y ]] && return 0 || return 1 ;;
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
  done
}

# prompt_input <msg> [default] -> REPLY
prompt_input() {
  local msg="$1" def="${2:-}"
  while true; do
    _prompt_say "$msg${def:+ [$def]}: "; _prompt_read
    [[ -z "$REPLY" && -n "$def" ]] && REPLY="$def"
    [[ -n "$REPLY" ]] && return 0
  done
}

# prompt_choose <msg> <allow_free 0|1> <items...> -> REPLY
prompt_choose() {
  local msg="$1" allow_free="$2"; shift 2
  local -a items; items=("$@")
  if (( $+commands[fzf] )) && [[ -z "${WORKYTREE_PROMPT_INPUT:-}" ]]; then
    local -a fz; fz=(--prompt "$msg> " --height 40% --reverse)
    (( allow_free )) && fz+=(--print-query)
    REPLY="$(printf '%s\n' "${items[@]}" | fzf "${fz[@]}" < /dev/tty 2> /dev/tty | tail -1)"
    [[ -n "$REPLY" ]] || exit 130
    return 0
  fi
  local i
  _prompt_say "$msg"$'\n'
  for (( i = 1; i <= ${#items}; i++ )); do _prompt_say "  $i) ${items[$i]}"$'\n'; done
  while true; do
    if (( allow_free )); then _prompt_say "choose [1-${#items}] or type a value: "; else _prompt_say "choose [1-${#items}]: "; fi
    _prompt_read
    if [[ "$REPLY" == <1-> ]] && (( REPLY >= 1 && REPLY <= ${#items} )); then REPLY="${items[$REPLY]}"; return 0; fi
    (( allow_free )) && [[ -n "$REPLY" ]] && return 0
  done
}

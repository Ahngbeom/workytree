# Interactive prompts. Input comes from WORKYTREE_PROMPT_INPUT (tests) or /dev/tty; prompts are
# written to /dev/tty (or stderr under WORKYTREE_PROMPT_INPUT) so $(...) capture of stdout stays clean.
typeset -gi WT_PROMPT_FD=-1

prompt_available() {
  [[ -n "${WORKYTREE_PROMPT_INPUT:-}" ]] && return 0
  (( WT_YES )) && return 1
  [[ -t 0 ]] || return 1
  { : < /dev/tty; } 2>/dev/null
}

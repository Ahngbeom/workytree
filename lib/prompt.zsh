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
  if _prompt_keys; then _prompt_confirm_keys "$msg" "$def"; return; fi
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
    # No `< /dev/tty`: under zsh MULTIOS it is appended to the piped items, so fzf never sees
    # EOF and a second reader steals keystrokes. fzf opens /dev/tty for keys itself.
    REPLY="$(printf '%s\n' "${items[@]}" | fzf "${fz[@]}" | tail -1)"
    [[ -n "$REPLY" ]] || exit 130
    return 0
  fi
  if _prompt_keys; then _prompt_choose_keys "$msg" "$allow_free" "${items[@]}"; return; fi
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

# Key-driven prompts: arrows/Enter instead of typed answers. Used when the prompt input is a
# terminal; WORKYTREE_PROMPT_KEYS=1 forces it so tests can feed raw key bytes from a file.
_prompt_keys() {
  [[ -n "${WORKYTREE_PROMPT_KEYS:-}" ]] && return 0
  [[ -z "${WORKYTREE_PROMPT_INPUT:-}" ]]
}

typeset -g WT_PROMPT_STTY=''
_prompt_raw_on() {
  _prompt_open
  [[ -t $WT_PROMPT_FD ]] || return 0
  WT_PROMPT_STTY="$(stty -g <&$WT_PROMPT_FD)"
  # -isig: Ctrl-C arrives as a key, so the cancel path restores the terminal before exiting.
  stty -icanon -echo -isig <&$WT_PROMPT_FD
}
_prompt_raw_off() {
  [[ -n "$WT_PROMPT_STTY" ]] || return 0
  stty "$WT_PROMPT_STTY" <&$WT_PROMPT_FD; WT_PROMPT_STTY=''
}
_prompt_cancel() { _prompt_raw_off; _prompt_say $'\n'; exit 130; }

# _prompt_key -> KEY: up|down|left|right|enter|tab|cancel, or the literal character typed.
_prompt_key() {
  local c d e
  read -u $WT_PROMPT_FD -k 1 -r c || _prompt_cancel
  case "$c" in
    $'\n'|$'\r') KEY=enter ;;
    $'\t')       KEY=tab ;;
    $'\x03'|q)   KEY=cancel ;;
    $'\e')
      # A lone Esc has nothing following it; an arrow key is Esc + [ (or O) + letter.
      if read -u $WT_PROMPT_FD -t 0.05 -k 1 -r d && [[ "$d" == [\[O] ]] \
          && read -u $WT_PROMPT_FD -t 0.05 -k 1 -r e; then
        case "$e" in A) KEY=up ;; B) KEY=down ;; C) KEY=right ;; D) KEY=left ;; *) KEY='' ;; esac
      else
        KEY=cancel
      fi ;;
    *) KEY="$c" ;;
  esac
}

_prompt_hl() { print -n -r -- "${WT_C_INFO}$1${WT_C_RESET}"; }

_prompt_confirm_keys() {
  local msg="$1" KEY yes_s no_s
  local -i yes=0
  [[ "${2:-y}" == y ]] && yes=1
  _prompt_say "$msg ${WT_C_DIM}(←/→ to pick, Enter to confirm, y/n)${WT_C_RESET}"$'\n'
  _prompt_raw_on
  while true; do
    if (( yes )); then yes_s="$(_prompt_hl '› Yes')" no_s='  No'
    else yes_s='  Yes' no_s="$(_prompt_hl '› No')"; fi
    _prompt_say $'\r\e[2K'"  $yes_s   $no_s"
    _prompt_key
    case "$KEY" in
      enter)   break ;;
      y|Y)     yes=1; break ;;
      n|N)     yes=0; break ;;
      cancel)  _prompt_cancel ;;
      left|right|up|down|tab|h|l|j|k) yes=$(( !yes )) ;;
    esac
  done
  _prompt_raw_off
  _prompt_say $'\r\e[2K'"  $(_prompt_hl "› $( (( yes )) && print Yes || print No )")"$'\n'
  (( yes ))
}

# _prompt_fit <text> <width>: <text> cut to <width> display columns, so a redraw never wraps.
_prompt_fit() {
  local s="$1"
  local -i w=$2
  (( w > 0 )) || { print -n -r -- "$s"; return; }
  if (( ${(m)#s} > w )); then
    s="${s[1,w-1]}"
    while (( ${(m)#s} > w - 1 )); do s="${s[1,-2]}"; done
    s+='…'
  fi
  print -n -r -- "$s"
}

_prompt_choose_keys() {
  local msg="$1"
  local -i allow_free="$2"; shift 2
  local -a items; items=("$@")
  local free_label='(type a value…)'
  (( allow_free )) && items+=("$free_label")
  local -i n=${#items} cur=1 top=1 cols=0 rows=0 view i drawn=0
  local KEY size line
  _prompt_raw_on
  if [[ -t $WT_PROMPT_FD ]] && size="$(stty size <&$WT_PROMPT_FD 2>/dev/null)"; then
    rows=${size%% *} cols=${size##* }
  fi
  view=$(( n < 10 ? n : 10 ))
  (( rows > 3 && view > rows - 3 )) && view=$(( rows - 3 ))
  _prompt_say "$msg ${WT_C_DIM}(↑/↓ to move, Enter to select, q to cancel)${WT_C_RESET}"$'\n'
  while true; do
    (( cur < top )) && top=$cur
    (( cur >= top + view )) && top=$(( cur - view + 1 ))
    (( drawn )) && _prompt_say $'\e['"${view}A"
    for (( i = top; i < top + view; i++ )); do
      line="$(_prompt_fit "$i) ${items[$i]}" $(( cols > 4 ? cols - 4 : 0 )))"
      if (( i == cur )); then line="$(_prompt_hl "› $line")"; else line="  $line"; fi
      _prompt_say $'\r\e[2K'"$line"$'\n'
    done
    drawn=1
    _prompt_key
    case "$KEY" in
      enter) break ;;
      cancel) _prompt_cancel ;;
      up|k|left)   cur=$(( cur > 1 ? cur - 1 : n )) ;;
      down|j|right|tab) cur=$(( cur < n ? cur + 1 : 1 )) ;;
      <1-9>) (( KEY <= n )) && { cur=$KEY; break; } ;;
    esac
  done
  _prompt_raw_off
  _prompt_say $'\e['"${view}A"$'\r\e[J'
  if (( allow_free && cur == n )); then
    prompt_input "$msg"
    return 0
  fi
  REPLY="${items[$cur]}"
  _prompt_say "  $(_prompt_hl "› $REPLY")"$'\n'
}

#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"
source "$WT_TEST_ROOT/lib/ui.zsh"
source "$WT_TEST_ROOT/lib/prompt.zsh"

# keys <bytes>: feed raw keystrokes (printf %b escapes) to the key-driven prompts.
keys() {
  printf '%b' "$1" > "$TMP_ROOT/keys"
  export WORKYTREE_PROMPT_INPUT="$TMP_ROOT/keys" WORKYTREE_PROMPT_KEYS=1
}
UP='\e[A' DOWN='\e[B' LEFT='\e[D' RIGHT='\e[C' ENTER='\n'

confirm_rc() { ( prompt_confirm "ok?" "$1" ) 2>/dev/null; print $?; }
choose()     { ( prompt_choose "pick" "$@"; print -r -- "$REPLY" ) 2>/dev/null; }

test_confirm_enter_takes_the_default() {
  keys "$ENTER"; assert_eq "$(confirm_rc y)" 0 "default yes"
  keys "$ENTER"; assert_eq "$(confirm_rc n)" 1 "default no"
}

test_confirm_arrows_toggle_the_answer() {
  keys "$RIGHT$ENTER";       assert_eq "$(confirm_rc y)" 1 "right moves to No"
  keys "$LEFT$ENTER";        assert_eq "$(confirm_rc n)" 0 "left moves to Yes"
  keys "$RIGHT$RIGHT$ENTER"; assert_eq "$(confirm_rc y)" 0 "toggle twice is back to Yes"
}

test_confirm_letters_still_answer_immediately() {
  keys "n"; assert_eq "$(confirm_rc y)" 1
  keys "y"; assert_eq "$(confirm_rc n)" 0
}

test_confirm_cancel_exits_130() {
  keys "q";    assert_eq "$(confirm_rc y)" 130 "q"
  keys '\e';   assert_eq "$(confirm_rc y)" 130 "lone Esc"
  keys '\x03'; assert_eq "$(confirm_rc y)" 130 "Ctrl-C"
  keys "";     assert_eq "$(confirm_rc y)" 130 "EOF"
}

test_choose_enter_picks_the_first_item() {
  keys "$ENTER"; assert_eq "$(choose 0 a b c)" "a"
}

test_choose_arrows_move_and_wrap() {
  keys "$DOWN$DOWN$ENTER"; assert_eq "$(choose 0 a b c)" "c"
  keys "$UP$ENTER";        assert_eq "$(choose 0 a b c)" "c" "up from the top wraps to the bottom"
  keys "$DOWN$DOWN$DOWN$ENTER"; assert_eq "$(choose 0 a b c)" "a" "down from the bottom wraps"
}

test_choose_digit_selects_immediately() {
  keys "2"; assert_eq "$(choose 0 a b c)" "b"
}

test_choose_free_value_through_the_extra_row() {
  keys "$UP${ENTER}custom$ENTER"; assert_eq "$(choose 1 a b)" "custom"
  keys "$ENTER";                  assert_eq "$(choose 1 a b)" "a" "listed items stay selectable"
}

test_choose_scrolls_past_the_visible_window() {
  local -a items; items=(i{1..15})
  keys "$UP$ENTER"; assert_eq "$(choose 0 "${items[@]}")" "i15"
}

test_choose_cancel_exits_130() {
  keys "q"; ( prompt_choose "pick" 0 a b ) 2>/dev/null
  assert_eq "$?" 130
}

test_choose_fzf_reads_only_the_items() {
  unset WORKYTREE_PROMPT_INPUT WORKYTREE_PROMPT_KEYS
  commands[fzf]=/usr/bin/true
  fzf() { cat > "$TMP_ROOT/fzf.in"; sed -n 2p "$TMP_ROOT/fzf.in"; }
  assert_eq "$(choose 0 a b c)" "b"
  assert_eq "$(<"$TMP_ROOT/fzf.in")" $'a\nb\nc'
  unfunction fzf; unhash fzf
}

test_line_mode_is_unchanged_without_keys() {
  print -l 2 > "$TMP_ROOT/answers"; export WORKYTREE_PROMPT_INPUT="$TMP_ROOT/answers"
  assert_eq "$(choose 0 a b c)" "b"
}

# tty_input <keys> [default] [setup]: prompt_input on a real pseudo-terminal, fed <keys>; prints REPLY.
tty_input() {
  zmodload zsh/zpty
  local out="$TMP_ROOT/tty.out" script="$TMP_ROOT/tty.zsh" screen s=''
  local -i i
  rm -f "$out"
  # A zpty starts 0 columns wide, and ZLE draws no prompt at width 0.
  print -r -- "stty cols 80; ${3:-}; source ${(q)WT_TEST_ROOT}/lib/ui.zsh; source ${(q)WT_TEST_ROOT}/lib/prompt.zsh
    prompt_input ticket ${(q)2:-}; print -r -- \"\$REPLY\" > ${(q)out}" > "$script"
  zpty wt zsh -f "${(q)script}"
  for (( i = 0; i < 50; i++ )); do zpty -r -t wt screen && s+="$screen"; [[ "$s" == *ticket* ]] && break; sleep 0.1; done
  zpty -w -n wt "$(printf '%b' "$1")"
  # Without draining the pty here, the child never writes $out.
  for (( i = 0; i < 50; i++ )); do [[ -s $out ]] && break; zpty -r -t wt screen; sleep 0.1; done
  zpty -d wt
  [[ -s $out ]] && print -r -- "$(<$out)"
}

test_input_arrows_move_the_cursor_on_a_terminal() {
  assert_eq "$(tty_input "abd$LEFT${LEFT}c\r")" "acbd" "left arrow edits mid-line"
  assert_eq "$(tty_input "ac${LEFT}b$RIGHT${RIGHT}d\r")" "abcd" "right arrow moves back"
  assert_eq "$(tty_input "\r" main)" "main" "Enter on an empty line takes the default"
}

test_input_has_no_shell_completion_on_a_terminal() {
  assert_eq "$(tty_input "\tab\x1b\x04c\r")" "abc" "Tab and Esc Ctrl-D insert and list nothing"
  assert_eq "$(tty_input "abx${LEFT}\x04\r")" "ab" "Ctrl-D mid-line deletes the character under the cursor"
}

test_input_ctrl_d_on_an_empty_line_cancels() {
  tty_input "\x04" > /dev/null
  assert_not_exists "$TMP_ROOT/tty.out"
}

test_input_prompt_text_is_never_expanded() {
  local def='$(touch pwned)%~'
  assert_eq "$(tty_input "\r" "$def" "setopt prompt_subst")" "$def"
  assert_not_exists "$TMP_ROOT/pwned"
}

run_tests

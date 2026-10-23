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

# pty_script <file>: `zsh -f <file>` under pty_start. A zpty starts 0 columns wide, and ZLE draws
# no prompt at width 0. PATH=/usr/bin:/bin keeps fzf out, so the built-in menus run.
pty_script() { pty_start "stty cols 80 rows 24; PATH=/usr/bin:/bin exec ${(q)commands[zsh]} -f ${(q)1}"; }

# tty_input <keys> [default] [setup]: prompt_input on a real pseudo-terminal, fed <keys>; prints REPLY.
tty_input() {
  local out="$TMP_ROOT/tty.out"
  rm -f "$out"
  print -r -- "${3:-}; source ${(q)WT_TEST_ROOT}/lib/ui.zsh; source ${(q)WT_TEST_ROOT}/lib/prompt.zsh
    prompt_input ticket ${(q)2:-}; print -r -- \"\$REPLY\" > ${(q)out}" > "$TMP_ROOT/tty.zsh"
  pty_script "$TMP_ROOT/tty.zsh"
  pty_wait ticket 50
  pty_send "$(printf '%b' "$1")"
  pty_finish 50
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

test_choose_ignores_modified_arrows_and_function_keys() {
  keys '\e[1;2B\e[1;5B\n'; assert_eq "$(choose 0 a b c)" "c" "shift/ctrl+down move like down"
  keys '\e[15~\n';         assert_eq "$(choose 0 a b c d e)" "a" "F5 neither selects nor moves"
  keys '\eb\n';            assert_eq "$(choose 0 a b c)" "a" "Option+Left (Esc b) neither cancels nor moves"
  keys '\eOB\n';           assert_eq "$(choose 0 a b c)" "b" "SS3 down"
}

test_confirm_ignores_function_keys() {
  keys '\e[15~\e[1;2C\n'; assert_eq "$(confirm_rc n)" 0 "F5 does not answer; shift+right toggles"
}

# tty_widgets <choose keys> [confirm keys]: prompt_choose a b c, then prompt_confirm (default
# Yes), on a real terminal; "|" in <choose keys> pauses 0.15 s. Prints "<choice> <confirm rc>
# <modes restored 0|1>", or "- <rc>" when the menu exited. Only icanon/echo/isig are compared:
# macOS adds PENDIN to `stty -g` whenever canonical mode comes back.
tty_widgets() {
  local out="$TMP_ROOT/w.out" part
  rm -f "$out"
  print -r -- "source ${(q)WT_TEST_ROOT}/lib/ui.zsh; source ${(q)WT_TEST_ROOT}/lib/prompt.zsh
    modes() { stty -a | tr ' ' '\\n' | grep -E '^-?(icanon|echo|isig)\$' | sort; }
    before=\$(modes)
    choice=\$( prompt_choose pick 0 a b c; print -r -- \$REPLY ) || { print -r -- \"- \$?\" > ${(q)out}; exit; }
    ( prompt_confirm proceed y ); rc=\$?
    [[ \$before == \$(modes) ]]; print -r -- \"\$choice \$rc \$?\" > ${(q)out}" > "$TMP_ROOT/w.zsh"
  pty_script "$TMP_ROOT/w.zsh"
  pty_wait pick 50
  for part in "${(@s:|:)1}"; do pty_send "$(printf '%b' "$part")"; sleep 0.15; done
  pty_wait proceed 50 && sleep 0.3 && pty_send "${2:-n}"
  pty_finish 50
  [[ -s $out ]] && print -r -- "$(<$out)"
}

test_typeahead_does_not_answer_the_next_prompt() {
  assert_eq "$(tty_widgets '2\r' n)" "b 1 0" "the Enter typed with 2 is dropped; the confirm waits for n"
}

test_split_escape_sequence_is_still_an_arrow() {
  assert_eq "$(tty_widgets '\e|[B\r' y)" "b 0 0" "Esc, a pause, then [B is Down"
}

test_lone_escape_still_cancels_on_a_terminal() {
  assert_eq "$(tty_widgets '\e')" "- 130"
}

test_yes_beats_the_prompt_hook_and_names_itself() {
  local -i WT_YES=1
  WORKYTREE_PROMPT_INPUT=/dev/null prompt_available
  assert_eq "$?" 1 "-y never asks, even with the test hook set"
  assert_eq "$(prompt_blocker)" "--yes"
  WT_YES=0
  assert_eq "$(prompt_blocker)" "no terminal"
}

run_tests

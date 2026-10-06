#!/usr/bin/env zsh
# The fzf renderer, with fzf stubbed as a shell function (bin/workytree's PATH would put a real
# install ahead of any fake executable). The stub records its arguments and answers with a
# canned selection.
source "${0:A:h}/helpers.zsh"
for f in ui config resolve prompt worktree forge status; do source "$WT_TEST_ROOT/lib/$f.zsh"; done
for f in prune remove status; do source "$WT_TEST_ROOT/lib/cmd/$f.zsh"; done

fixture() {
  make_repo "$HOME/src/app"
  typeset -ga WT_PROJECTS=(me)
  typeset -gA WT_PCFG=(me.repo_root "$HOME/src" me.worktree_root "$HOME/wts") WT_CFG=() WT_RCFG=()
  git -C "$HOME/src/app" worktree add -q -b fix/A "$HOME/wts/app/fix/A"
  git -C "$HOME/src/app" branch lonely
  WORKYTREE_HOME="$HOME/with space/workytree"
  WT_PROJECT_OPT='' WT_COLOR=0
  _status_parse_opts --offline
  RECORDS="$(status_collect_repo me app "$HOME/src/app" 30)"
  : > "$HOME/notes"
}

# fzf_selecting <type>: stub fzf that saves its argv (one per line) and stdin, then prints the
# first input line whose record type is <type> (nothing for "none", i.e. esc).
fzf_selecting() {
  FZF_PICK="$1"
  fzf() {
    [[ "$1" == --version ]] && { print -r -- "0.55.0 (stub)"; return; }
    print -rl -- "$@" > "$HOME/fzf.args"
    cat > "$HOME/fzf.in"
    local l
    for l in "${(@f)$(<"$HOME/fzf.in")}"; do
      [[ "$l" == "$FZF_PICK"$'\t'* ]] && { print -r -- "$l"; return 0; }
    done
    return 130
  }
}

test_enter_on_worktree_prints_its_path_last() {
  fixture; fzf_selecting worktree
  assert_eq "$(_status_run_fzf "$RECORDS" "$HOME/notes")" "$HOME/wts/app/fix/A"
}

test_enter_on_branch_row_prints_nothing() {
  fixture; fzf_selecting branch
  assert_eq "$(_status_run_fzf "$RECORDS" "$HOME/notes")" ""
}

test_esc_prints_nothing_and_succeeds() {
  fixture; fzf_selecting none
  local out; out="$(_status_run_fzf "$RECORDS" "$HOME/notes")"
  assert_eq "$?" 0
  assert_eq "$out" ""
}

test_fzf_input_is_record_plus_display_field() {
  fixture; fzf_selecting none
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  local -a f; f=("${(@ps:\t:)$(head -1 "$HOME/fzf.in")}")
  assert_eq "${#f}" 27
  assert_contains "$(<"$HOME/fzf.args")" "--with-nth=27"
}

test_bindings_quote_a_bin_path_with_spaces() {
  fixture; fzf_selecting none
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  local args; args="$(<"$HOME/fzf.args")"
  local qbin="${(q)WORKYTREE_HOME}/bin/workytree"
  assert_contains "$args" "ctrl-d:execute($qbin __status-action remove {})+reload($qbin __status-rows --no-color --offline)"
  assert_contains "$args" "ctrl-r:reload($qbin __status-rows --no-color --offline)"
  assert_contains "$args" "--preview=$qbin __status-preview {}"
  # The reload command must split back into the same words a shell would see.
  local cmd="$qbin __status-rows --no-color --offline"
  local -a words; words=("${(Q@)${(z)cmd}}")
  assert_eq "${words[1]}" "$WORKYTREE_HOME/bin/workytree"
}

test_reload_args_carry_scope_and_stale_filter() {
  fixture
  WT_PROJECT_OPT=me
  _status_parse_opts app --stale 7
  _status_reload_args
  assert_eq "${reply[*]}" "--project me --no-color app --stale 7"
  _status_parse_opts
  WT_PROJECT_OPT='' WT_COLOR=1
  _status_reload_args
  assert_eq "${reply[*]}" ""
}

test_refresh_fetches_unless_offline() {
  fixture; fzf_selecting none
  _status_parse_opts
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  assert_contains "$(<"$HOME/fzf.args")" "ctrl-r:reload(${(q)WORKYTREE_HOME}/bin/workytree __status-rows --no-color --fetch)"
}

test_notes_appear_in_the_header() {
  fixture; fzf_selecting none
  print -r -- "app: github lookup failed (exit 4)" > "$HOME/notes"
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  assert_contains "$(<"$HOME/fzf.args")" "note: app: github lookup failed (exit 4)"
}

# ctrl-d removed the worktree this shell stands in: send the shell back to the main checkout.
test_removed_current_worktree_sends_shell_to_main_checkout() {
  fixture; fzf_selecting none
  local out
  out="$(cd "$HOME/wts/app/fix/A" && git -C "$HOME/src/app" worktree remove "$HOME/wts/app/fix/A" && _status_run_fzf "$RECORDS" "$HOME/notes")"
  assert_eq "$out" "$HOME/src/app"
}

test_old_fzf_falls_back() {
  fzf() { print -r -- "0.30.0 (old)"; }
  local err; err="$(_status_fzf_ok 2>&1)"
  assert_eq "$?" 1
  assert_contains "$err" "fzf 0.30.0 is older than 0.38"
  fzf() { print -r -- "0.38.1 (ok)"; }
  _status_fzf_ok 2>/dev/null
  assert_eq "$?" 0
  unfunction fzf
}

test_action_refuses_non_worktree_rows() {
  fixture
  local branch_line; branch_line="$(print -r -- "$RECORDS" | grep '^branch')"
  local err; err="$(cmd___status-action remove "$branch_line" 2>&1 </dev/null)"
  assert_contains "$err" "only worktrees under worktree_root can be removed from here"
  assert_contains "$err" "branch -d lonely"
}

# fzf searches only the displayed field (--with-nth=27), so ctrl-s's "stale" query and typed
# filters like "gone" need the tags on screen.
test_display_field_carries_the_searchable_tags() {
  fixture; fzf_selecting none
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  local line; line="$(grep $'^branch\t' "$HOME/fzf.in")"
  local -a f; f=("${(@ps:\t:)line}")
  assert_contains "${f[27]}" "safe merged"
}

# Without a terminal (CI, a pipe) the width probe must fall back quietly: a shell error about
# /dev/tty would land in fzf's preview or the user's terminal.
test_preview_window_probe_is_quiet() {
  local err out
  err="$(_status_preview_window 2>&1 >/dev/null)"
  out="$(_status_preview_window 2>/dev/null)"
  assert_eq "$err" ""
  [[ "$out" == (right|down),50% ]]; assert_eq "$?" 0 "layout: $out"
}

run_tests

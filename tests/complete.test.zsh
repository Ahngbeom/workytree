#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

fixture() {
  make_repo "$HOME/src/app"
  write_config <<EOF
kinds = feature,fix
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  wt create app fix T1 main >/dev/null; wt create app fix T2 main >/dev/null
}

test_complete_sources() {
  fixture
  assert_contains "$(wt __complete commands)" "create"
  assert_contains "$(wt __complete commands)" "status"
  assert_eq "$(wt __complete projects)" "me"
  assert_eq "$(wt __complete repos)" "app"
  assert_contains "$(wt __complete kinds app)" "fix"
  assert_contains "$(wt __complete kinds app)" "feature"
  assert_eq "$(wt __complete tickets app fix | tr '\n' ' ')" "T1 T2 "
  assert_contains "$(wt __complete branches app)" "main"
  assert_exit 2 wt __complete bogus
}

test_completion_file_parses() {
  assert_exit 0 zsh -n "$WT_TEST_ROOT/shell/completions/_workytree"
}

# R40 (fix round 2): a brand-new user with nothing registered yet (no repos, no projects,
# no kinds on disk) hits every dynamic completion position with ZERO candidates. Calling
# the real `_values <label>` with no candidates after it is a zsh completion-system usage
# error ("_values:compvalues:11: not enough arguments") that leaks straight into the
# terminal -- reproduced live in fix round 1's verification. `_workytree_values` (the
# helper every dynamic completion position now goes through) must never call the real
# `_values` when there are zero candidates.
#
# Outside a real completion widget context, the genuine `_values` builtin errors ("can only
# be called from completion function") regardless of candidate count, so this stubs it to
# just record whether it was called -- which is also what makes the guard testable at all
# without driving a live Tab press. `workytree` is stubbed too so `_workytree_src`'s
# `$(workytree __complete ...)` call is controllable directly, with no config/fixture
# needed. Sourcing the completion file's own trailing `_workytree "$@"` call errors for the
# same "not a completion context" reason (stderr redirected away) -- harmless, since
# function definitions from the earlier part of the file are already in place by then.
test_completion_values_helper_skips_values_call_when_no_candidates() {
  local out
  out="$(zsh -c '
    workytree() { :; }
    _values() { print CALLED_VALUES; }
    source "'"$WT_TEST_ROOT"'/shell/completions/_workytree" 2>/dev/null
    _workytree_values repo repos
    print DONE
  ' 2>&1)"
  assert_contains "$out" "DONE"
  assert_eq "$(print -r -- "$out" | grep -c CALLED_VALUES)" "0" "must not call _values with zero candidates"
}

test_completion_values_helper_calls_values_when_candidates_present() {
  local out
  out="$(zsh -c '
    workytree() { print -l app1 app2; }
    _values() { print CALLED_VALUES args=$#; }
    source "'"$WT_TEST_ROOT"'/shell/completions/_workytree" 2>/dev/null
    _workytree_values repo repos
    print DONE
  ' 2>&1)"
  assert_contains "$out" "CALLED_VALUES args=3"
  assert_contains "$out" "DONE"
}

run_tests

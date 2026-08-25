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

run_tests

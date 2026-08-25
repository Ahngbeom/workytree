#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

test_version_prints_semver() {
  local out; out="$(wt --version)"
  assert_eq "$?" 0
  assert_contains "$out" "workytree 0."
}

test_help_exits_zero() {
  assert_exit 0 wt help
  assert_exit 0 wt --help
  assert_contains "$(wt help)" "workytree create"
}

test_no_args_is_usage_error() { assert_exit 2 wt; }

test_unknown_command_is_usage_error() {
  assert_exit 2 wt bogus
  assert_contains "$(wt bogus 2>&1)" "workytree: unknown command: bogus"
}

test_global_options_are_accepted_anywhere() {
  # --no-color / -y / --project are consumed before dispatch; help still works after them
  assert_exit 0 wt --no-color help
  assert_exit 0 wt help -y --project x
}

run_tests

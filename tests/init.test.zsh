#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"
answers() { printf '%s\n' "$@" > "$TMP_ROOT/answers"; export WORKYTREE_PROMPT_INPUT="$TMP_ROOT/answers"; }

test_init_noninteractive_with_args() {
  assert_exit 0 wt init me ~/src ~/wts
  assert_eq "$(wt config get default_project)" "me"
  assert_eq "$(wt config get project.me.repo_root)" "$HOME/src"
  assert_eq "$(wt config get alias_wt)" "true"
}

test_init_interactive() {
  answers "fd" "$HOME/fd/products" "$HOME/fd/wts" "n"
  wt init >/dev/null 2>&1
  assert_eq "$?" 0
  assert_eq "$(wt config get project.fd.worktree_root)" "$HOME/fd/wts"
  assert_eq "$(wt config get alias_wt)" "false"
}

test_init_refuses_when_config_exists() {
  wt init me ~/src ~/wts >/dev/null
  local out; out="$(wt init me ~/src ~/wts 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "project add"
}

test_init_without_args_noninteractive_is_usage_error() { assert_exit 2 wt init; }

# The following tests exercise rulings the brief predates: relative-path rejection and the
# leave-no-partial-config guarantee (R31/R27), and the interactive re-ask design.

test_init_noninteractive_relative_worktree_root_exits_1_no_config() {
  local out; out="$(wt init me ~/src rel/wts 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "worktree_root"
  assert_not_exists "$XDG_CONFIG_HOME/workytree/config"
}

test_init_interactive_reasks_after_bad_worktree_root() {
  # name, repo_root, a BAD (relative) worktree_root -> retry re-asks all three (empty line
  # keeps the previously typed value as the default) -> a GOOD worktree_root -> alias no
  answers "fd" "$HOME/fd/products" "rel/wts" "" "" "$HOME/fd/wts" "n"
  wt init >/dev/null 2>&1
  assert_eq "$?" 0
  assert_eq "$(wt config get project.fd.worktree_root)" "$HOME/fd/wts"
}

test_init_interactive_eof_during_reask_exits_130_no_partial_config() {
  # name, repo_root, a BAD worktree_root, then input runs out mid-retry
  answers "fd" "$HOME/fd/products" "rel/wts"
  assert_exit 130 wt init
  assert_not_exists "$XDG_CONFIG_HOME/workytree/config"
}

run_tests

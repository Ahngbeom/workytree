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
  # R33: the alias question is now asked EVERY pass through the loop, ahead of the write
  # attempt -- so each attempt is name, repo_root, worktree_root, alias (4 answers), not 3.
  # Attempt 1: a BAD (relative) worktree_root, alias "n" -> cmd_project add fails, nothing
  # written. Attempt 2: empty lines keep the previously typed name/repo_root, a GOOD
  # worktree_root, and alias "y" this time -> succeeds. Proves the alias choice from the
  # attempt that actually succeeds is what's honored, not a stale earlier answer.
  answers "fd" "$HOME/fd/products" "rel/wts" "n" "" "" "$HOME/fd/wts" "y"
  wt init >/dev/null 2>&1
  assert_eq "$?" 0
  assert_eq "$(wt config get project.fd.worktree_root)" "$HOME/fd/wts"
  assert_eq "$(wt config get alias_wt)" "true"
}

test_init_interactive_eof_during_reask_exits_130_no_partial_config() {
  # name, repo_root, a BAD worktree_root, alias answer, then input runs out mid-retry
  answers "fd" "$HOME/fd/products" "rel/wts" "n"
  assert_exit 130 wt init
  assert_not_exists "$XDG_CONFIG_HOME/workytree/config"
}

# R33 (fix round 1): cancelling ("q" or EOF) at ANY wizard question -- including the LAST one
# (the alias confirm, previously asked only AFTER cmd_project add had already written a real
# project section to disk) -- must exit 130 and leave NO config file behind. Each pair below
# reproduces cancellation at one specific question.

test_init_cancel_at_name_with_q() {
  answers "q"
  assert_exit 130 wt init
  assert_not_exists "$XDG_CONFIG_HOME/workytree/config"
}

test_init_cancel_at_name_with_eof() {
  answers
  assert_exit 130 wt init
  assert_not_exists "$XDG_CONFIG_HOME/workytree/config"
}

test_init_cancel_at_repo_root_with_q() {
  answers "fd" "q"
  assert_exit 130 wt init
  assert_not_exists "$XDG_CONFIG_HOME/workytree/config"
}

test_init_cancel_at_repo_root_with_eof() {
  answers "fd"
  assert_exit 130 wt init
  assert_not_exists "$XDG_CONFIG_HOME/workytree/config"
}

test_init_cancel_at_worktree_root_with_q() {
  answers "fd" "$HOME/fd/products" "q"
  assert_exit 130 wt init
  assert_not_exists "$XDG_CONFIG_HOME/workytree/config"
}

test_init_cancel_at_worktree_root_with_eof() {
  answers "fd" "$HOME/fd/products"
  assert_exit 130 wt init
  assert_not_exists "$XDG_CONFIG_HOME/workytree/config"
}

# The critical case: cancelling at the LAST question. Before the R33 fix, cmd_project add had
# ALREADY run (and written) by this point -- a subshell's command substitution does not
# sandbox filesystem I/O, only its own control flow -- so this is the scenario that left a
# brand-new user with a permanently half-written, unrecoverable config.
test_init_cancel_at_alias_with_q() {
  answers "fd" "$HOME/fd/products" "$HOME/fd/wts" "q"
  assert_exit 130 wt init
  assert_not_exists "$XDG_CONFIG_HOME/workytree/config"
}

test_init_cancel_at_alias_with_eof() {
  answers "fd" "$HOME/fd/products" "$HOME/fd/wts"
  assert_exit 130 wt init
  assert_not_exists "$XDG_CONFIG_HOME/workytree/config"
}

# Untested-guard class (this project has hit it four times before): the default project name
# offered by the wizard is sanitized from the cwd's basename to project add's own charset
# ([A-Za-z0-9_-]+). Without a cwd whose name actually contains a disallowed character, AND an
# empty first answer to actually accept that default, this sanitization is never exercised --
# every other test in this file supplies an explicit non-empty name. This test does both.
test_init_sanitizes_default_project_name_from_cwd() {
  local d="$TMP_ROOT/proj.dir with space"
  mkdir -p "$d"
  answers "" "$HOME/src" "$HOME/worktrees" "n"
  ( cd "$d" && wt init >/dev/null 2>&1 )
  assert_eq "$?" 0
  assert_eq "$(wt config get default_project)" "proj-dir-with-space"
}

run_tests

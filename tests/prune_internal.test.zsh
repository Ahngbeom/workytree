#!/usr/bin/env zsh
# Direct, function-level tests for prune_repo's defense-in-depth guards. Some of these are
# no longer reachable through the `wt` CLI at all now that lib/resolve.zsh's require_config
# (R27/C-1 layer 1) rejects a missing/empty worktree_root for every command -- which is
# exactly the point: prune_repo's own guards are a SECOND, independent layer that must not
# assume its caller ran require_config, so they have to be pinned independently of it too.
#
# Sources the library directly (same style as tests/worktree.test.zsh) and calls
# prune_repo() itself, bypassing cmd_prune/require_config/resolve_repo entirely.
source "${0:A:h}/helpers.zsh"
source "$WT_TEST_ROOT/lib/ui.zsh"
source "$WT_TEST_ROOT/lib/config.zsh"
source "$WT_TEST_ROOT/lib/resolve.zsh"
source "$WT_TEST_ROOT/lib/worktree.zsh"
source "$WT_TEST_ROOT/lib/cmd/prune.zsh"

# set_project <repo_root> <worktree_root>: hand-populate WT_PROJECTS/WT_PCFG for project
# "me", bypassing config_load (and therefore require_config) entirely -- these tests exist
# precisely to reach states a real config, gated by require_config, could no longer produce.
set_project() {
  typeset -ga WT_PROJECTS=(me)
  typeset -gA WT_PCFG=()
  WT_PCFG[me.repo_root]="$1"
  WT_PCFG[me.worktree_root]="$2"
}

test_prune_repo_refuses_empty_worktree_root_independent_of_require_config() {
  make_repo "$HOME/src/app"
  set_project "$HOME/src" ""
  local out; out="$(prune_repo me app "$HOME/src/app" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "refusing to prune app: project 'me' has no safe worktree_root"
}

test_prune_repo_refuses_worktree_root_literally_root_independent_of_require_config() {
  make_repo "$HOME/src/app"
  set_project "$HOME/src" "/"
  local out; out="$(prune_repo me app "$HOME/src/app" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "refusing to prune app: project 'me' has no safe worktree_root"
}

# C-1 layer 2 / I-3, independent of R29: even if the repo-name-safety check in
# lib/resolve.zsh (registered_repos / resolve_repo) were absent or bypassed, prune_repo's
# own anchor must independently refuse a repo name that makes worktree_parent's
# "$worktree_root/$repo" concatenation canonicalize OUTSIDE worktree_root. Calls prune_repo
# directly with repo=".." -- exactly the escape from the reviewer's reproduction -- to prove
# this guard does not depend on the name ever having been validated upstream.
test_prune_repo_anchor_refuses_repo_name_that_escapes_worktree_root() {
  mkdir -p "$HOME/wts/deep"
  mkdir -p "$HOME/wts/sibling/inner/.idea"
  print x > "$HOME/wts/sibling/inner/.idea/a.xml"
  make_repo "$HOME/src/normal"
  set_project "$HOME/src" "$HOME/wts/deep"
  local out; out="$(prune_repo me ".." "$HOME/src/normal" 2>&1)"
  local rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "is not inside the configured worktree_root"
  assert_dir "$HOME/wts/sibling/inner"
  assert_eq "$(cat "$HOME/wts/sibling/inner/.idea/a.xml")" "x"
}

# I-1: `git worktree list --porcelain` succeeding (rc=0) but producing a shape with no
# "worktree " lines at all -- a shape real git should never produce, since a repo always
# registers at least its main worktree -- must still refuse rather than treat an empty
# parsed set as "nothing is live". A real git failure (nonzero exit) is covered at the CLI
# level in tests/prune.test.zsh via a corrupted repo; this pins the rc=0-but-empty case,
# which needs a controlled stub to reach at all.
test_prune_repo_refuses_when_worktree_list_shape_is_unexpected() {
  make_repo "$HOME/src/app"
  set_project "$HOME/src" "$HOME/wts"
  mkdir -p "$HOME/wts/app/fix/ORPHAN/.idea"
  print x > "$HOME/wts/app/fix/ORPHAN/.idea/a.xml"

  # zsh functions shadow PATH lookups, so this intercepts only the one call this test
  # cares about; every other git invocation (including inside `command git`) is real.
  git() {
    if [[ "$*" == *"worktree list --porcelain"* ]]; then
      print "unexpected shape, no worktree lines"
      return 0
    fi
    command git "$@"
  }
  local out; out="$(prune_repo me app "$HOME/src/app" 2>&1)"
  local rc=$?
  unfunction git

  assert_eq "$rc" "1"
  assert_contains "$out" "could not determine live worktrees for app; refusing to touch its directories"
  assert_dir "$HOME/wts/app/fix/ORPHAN"
  assert_eq "$(cat "$HOME/wts/app/fix/ORPHAN/.idea/a.xml")" "x"
}

run_tests

#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

fixture() {
  make_repo "$HOME/src/app"
  make_repo "$HOME/src/lib"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

test_create_full_args_noninteractive() {
  fixture
  local out; out="$(wt create app fix PROJ-1 main 2>&1)"
  assert_eq "$?" 0
  assert_dir "$HOME/wts/app/fix/PROJ-1"
  assert_eq "$(git -C "$HOME/wts/app/fix/PROJ-1" branch --show-current)" "fix/PROJ-1"
  assert_eq "${out##*$'\n'}" "$HOME/wts/app/fix/PROJ-1" "last line is the path"
  assert_contains "$out" "result: created"
}

test_create_auto_base_uses_current_branch() {
  fixture
  git -C "$HOME/src/app" checkout -qb develop
  wt create app feature X >/dev/null
  assert_eq "$(git -C "$HOME/wts/app/feature/X" log --format=%s -1)" "init"
  assert_contains "$(wt create app feature Y 2>&1)" "develop (auto-detected)"
}

test_create_existing_branch_is_checked_out() {
  fixture
  git -C "$HOME/src/app" branch fix/OLD
  assert_contains "$(wt create app fix OLD 2>&1)" "existing branch"
  assert_eq "$(git -C "$HOME/wts/app/fix/OLD" branch --show-current)" "fix/OLD"
}

test_create_existing_path_is_reused() {
  fixture
  wt create app fix R1 >/dev/null
  local out; out="$(wt create app fix R1)"
  assert_contains "$out" "result: reused"
  assert_eq "${out##*$'\n'}" "$HOME/wts/app/fix/R1"
}

test_create_infers_repo_from_cwd() {
  fixture
  cd "$HOME/src/lib"
  wt create chore C1 >/dev/null
  assert_dir "$HOME/wts/lib/chore/C1"
  # ...and from inside a worktree of that repo
  cd "$HOME/wts/lib/chore/C1"
  wt create chore C2 >/dev/null
  assert_dir "$HOME/wts/lib/chore/C2"
}

test_create_missing_args_noninteractive_is_usage_error() {
  fixture
  assert_exit 2 wt create app fix
  assert_exit 2 wt create
  cd "$HOME/src/app"; assert_exit 2 wt create fix
}

test_create_unknown_repo_outside_project() {
  fixture
  assert_exit 1 wt create ghost fix T
}

# R21: a stale plain directory sitting at the target path is not a worktree and must not be
# reported as "reused" -- create_do has to verify the path is actually registered against
# $repo_path via `git worktree list`, not just check -e.
test_create_stale_plain_dir_at_target_is_not_reused() {
  fixture
  mkdir -p "$HOME/wts/app/fix/STALE1"
  local out; out="$(wt create app fix STALE1 main 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "workytree: target path exists but is not a worktree of"
  assert_contains "$out" "STALE1"
}

# R21, inverse-of-above: a plain FILE at the target is the same bug, not just a directory.
test_create_stale_plain_file_at_target_is_not_reused() {
  fixture
  mkdir -p "$HOME/wts/app/fix"
  print "junk" > "$HOME/wts/app/fix/STALE2"
  local out; out="$(wt create app fix STALE2 main 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "workytree: target path exists but is not a worktree of"
}

# R21: pins the CURRENT behavior for the inverse case (a worktree git still has registered,
# but whose directory was deleted from disk) so a later change cannot silently regress it into
# something worse than a clearly-diagnosed, workytree-prefixed failure.
test_create_missing_but_registered_worktree_fails_loudly() {
  fixture
  wt create app fix GONE main >/dev/null
  rm -rf "$HOME/wts/app/fix/GONE"
  local out; out="$(wt create app fix GONE main 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "workytree: failed to create worktree"
}

# R22: a base ref containing a space must never be silently truncated by splitting a display
# label -- it either reaches git intact (and git rejects the invalid ref, loudly) or the create
# fails; either way "main" alone must never be what gets used.
test_create_base_ref_with_space_is_not_silently_truncated() {
  fixture
  local out; out="$(wt create app chore SPC "main extra-junk" 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "main extra-junk"
  assert_not_exists "$HOME/wts/app/chore/SPC"
}

run_tests

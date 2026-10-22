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

# origin_fixture: app tracks origin/main on a bare remote that is one commit ahead of the
# local remote-tracking ref.
origin_fixture() {
  make_repo "$HOME/src/app"
  git clone -q --bare "$HOME/src/app" "$HOME/remote.git"
  git -C "$HOME/src/app" remote add origin "$HOME/remote.git"
  git -C "$HOME/src/app" fetch -q origin
  git -C "$HOME/src/app" branch -q -u origin/main main
  git clone -q "$HOME/remote.git" "$HOME/other"
  print new > "$HOME/other/new.txt"; git -C "$HOME/other" add -A; git -C "$HOME/other" commit -qm ahead
  git -C "$HOME/other" push -q origin main
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

test_create_fetches_origin_before_branching() {
  origin_fixture
  local out; out="$(wt create app fix F -y 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "fetching origin"
  assert_eq "$(git -C "$HOME/wts/app/fix/F" rev-parse HEAD)" "$(git -C "$HOME/other" rev-parse HEAD)" "branched from the fetched origin/main"
}

test_create_survives_unreachable_origin() {
  origin_fixture; mv "$HOME/remote.git" "$HOME/remote-moved.git"
  local out; out="$(wt create app fix F -y 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "could not fetch origin"
  assert_dir "$HOME/wts/app/fix/F"
}

test_create_without_origin_does_not_fetch() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  local out; out="$(wt create app fix F main 2>&1)"
  assert_eq "${out//fetching/}" "$out" "no origin, no fetch"
}

test_create_last_stdout_line_is_still_the_path_after_fetch() {
  origin_fixture
  assert_eq "$(wt create app fix F -y 2>/dev/null | tail -1)" "$HOME/wts/app/fix/F"
}

test_create_rejects_unknown_flags_before_doing_anything() {
  origin_fixture
  local flag out
  for flag in --force --dry-run --ia; do
    out="$(wt create app fix X "$flag" -y 2>&1)"
    assert_eq "$?" 2 "$flag"
    assert_contains "$out" "unknown flag: $flag"
    assert_eq "${out//fetching/}" "$out" "$flag: no fetch"
  done
  out="$(wt create app fix -T2 -y 2>&1)"
  assert_eq "$?" 2 -T2
  assert_contains "$out" "unknown flag: -T2"
  assert_not_exists "$HOME/wts"
}

test_create_dashdash_still_passes_a_literal_dash_ticket() {
  fixture
  assert_exit 0 wt create -- app fix -T2 main
  assert_eq "$(git -C "$HOME/wts/app/fix/-T2" branch --show-current)" "fix/-T2"
}

test_create_rejects_ill_formed_names_before_creating_anything() {
  origin_fixture
  local out; out="$(wt create app fix 'my ticket' -y 2>&1)"
  assert_eq "$?" 2 space
  assert_contains "$out" "invalid ticket: my ticket"
  assert_contains "$out" "hint:"
  assert_eq "${out//fetching/}" "$out" "no fetch"
  assert_exit 2 wt create app fix .. -y
  assert_exit 2 wt create app fix/sub T -y
  assert_exit 2 wt create -- app -x T -y
  assert_not_exists "$HOME/wts"
}

test_create_rejects_a_bad_base_before_creating_anything() {
  origin_fixture
  local out; out="$(wt create app fix T nonexistent-base 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "base not found: nonexistent-base"
  assert_not_exists "$HOME/wts"
  out="$(wt create -- app fix T -x 2>&1)"
  assert_eq "$?" 2 dash-base
  assert_contains "$out" "invalid base: -x"
  assert_not_exists "$HOME/wts"
}

test_create_reports_a_branch_checked_out_elsewhere_before_creating_anything() {
  fixture
  git -C "$HOME/src/app" checkout -q -b fix/HERE
  local out; out="$(wt create app fix HERE 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "fix/HERE is already checked out at $HOME/src/app"
  assert_contains "$out" "hint:"
  assert_not_exists "$HOME/wts"
}

test_create_removes_the_directories_it_made_when_git_fails() {
  fixture
  mkdir -p "$HOME/src/app/.git/refs/heads/fix"; : > "$HOME/src/app/.git/refs/heads/fix/L.lock"
  local out; out="$(wt create app fix L main 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "failed to create worktree"
  assert_not_exists "$HOME/wts"
}

run_tests

#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

fixture() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  wt create app fix T main >/dev/null
  WT="$HOME/wts/app/fix/T"
}

test_remove_clean_worktree() {
  fixture
  assert_exit 0 wt remove app fix T
  assert_not_exists "$WT"
  assert_contains "$(git -C "$HOME/src/app" branch)" "fix/T" "branch kept without -b"
}

test_remove_dirty_requires_force() {
  fixture; print x > "$WT/new.txt"
  local out; out="$(wt remove app fix T 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "--force"
  assert_dir "$WT"
  assert_exit 0 wt remove app fix T --force
  assert_not_exists "$WT"
}

test_remove_idea_only_is_discarded() {
  fixture; mkdir "$WT/.idea"; print x > "$WT/.idea/ws.xml"
  assert_contains "$(wt remove app fix T 2>&1)" "IDE state"
  assert_not_exists "$WT"
}

test_remove_with_branch_flags() {
  fixture
  wt remove app fix T -b >/dev/null
  assert_eq "$(git -C "$HOME/src/app" branch --list fix/T)" ""
  # unmerged branch: -b warns and keeps, -B deletes
  wt create app fix U main >/dev/null
  print y > "$HOME/wts/app/fix/U/f"; git -C "$HOME/wts/app/fix/U" add -A; git -C "$HOME/wts/app/fix/U" commit -qm c
  assert_contains "$(wt remove app fix U -b 2>&1)" "not deleted"
  assert_contains "$(git -C "$HOME/src/app" branch)" "fix/U"
  wt create app fix U >/dev/null
  wt remove app fix U -B >/dev/null
  assert_eq "$(git -C "$HOME/src/app" branch --list fix/U)" ""
}

test_remove_missing_path_and_bad_flag() {
  fixture
  assert_exit 1 wt remove app fix NOPE
  assert_exit 2 wt remove app fix T --bogus
  assert_exit 2 wt remove app
}

test_remove_flags_interleaved_with_positionals() {
  fixture; print x > "$WT/new.txt"
  assert_exit 0 wt remove --force app fix T
  assert_not_exists "$WT"
}

run_tests

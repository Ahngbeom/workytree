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

run_tests

#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

fixture() {
  make_repo "$HOME/src/app"; make_repo "$HOME/src/lib"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

test_prune_removes_cruft_orphans_keeps_real() {
  fixture
  wt create app fix LIVE main >/dev/null
  mkdir -p "$HOME/wts/app/fix/ORPHAN/.idea"; print x > "$HOME/wts/app/fix/ORPHAN/.idea/a.xml"
  mkdir -p "$HOME/wts/app/chore/REAL"; print x > "$HOME/wts/app/chore/REAL/keep.txt"
  local out; out="$(wt prune app 2>&1)"
  assert_eq "$?" 0
  assert_not_exists "$HOME/wts/app/fix/ORPHAN"
  assert_dir "$HOME/wts/app/fix/LIVE"
  assert_dir "$HOME/wts/app/chore/REAL"
  assert_contains "$out" "skipped orphan"
}

test_prune_drops_stale_registration_and_empty_kind_dir() {
  fixture
  wt create app fix GONE main >/dev/null
  rm -rf "$HOME/wts/app/fix/GONE"
  wt prune app >/dev/null
  assert_eq "$(git -C "$HOME/src/app" worktree list | wc -l | tr -d ' ')" "1"
  assert_not_exists "$HOME/wts/app/fix"
}

test_prune_all_repos() {
  fixture
  mkdir -p "$HOME/wts/lib/fix/X"
  local out; out="$(wt prune 2>&1)"
  assert_contains "$out" "pruning worktrees for app"
  assert_contains "$out" "pruning worktrees for lib"
  assert_not_exists "$HOME/wts/lib/fix/X"
}

# R24 fail-closed: an orphan directory whose inspection cannot be completed (here: a
# subdirectory chmod'd unreadable, same fault as lib/worktree.zsh's own
# test_cruft_only_unreadable_subdir_is_not_cruft) must be KEPT, not deleted -- a false
# "cruft" verdict here would silently destroy whatever real work was hiding behind the
# unreadable subdirectory. This is what proves cmd_prune actually calls the fail-closed
# dir_is_cruft_only rather than some looser ad hoc check.
test_prune_keeps_orphan_whose_inspection_fails() {
  fixture
  wt create app fix LIVE main >/dev/null
  mkdir -p "$HOME/wts/app/fix/UNREADABLE/hidden"
  print "real work" > "$HOME/wts/app/fix/UNREADABLE/hidden/work.txt"
  chmod 000 "$HOME/wts/app/fix/UNREADABLE/hidden"
  local out; out="$(wt prune app 2>&1)"
  assert_eq "$?" 0
  assert_dir "$HOME/wts/app/fix/UNREADABLE"
  assert_contains "$out" "skipped orphan"
  chmod 755 "$HOME/wts/app/fix/UNREADABLE/hidden"
}

# A live worktree sitting beside cruft orphans, and orphans in a DIFFERENT <kind> than any
# live worktree, must never be touched -- and the <kind> dir holding the live worktree must
# survive the parent-directory sweep even though it also holds cruft siblings.
test_prune_never_touches_live_worktree_or_its_kind_dir() {
  fixture
  wt create app fix LIVE main >/dev/null
  mkdir -p "$HOME/wts/app/fix/CRUFT/.idea"
  local out; out="$(wt prune app 2>&1)"
  assert_dir "$HOME/wts/app/fix/LIVE"
  assert_dir "$HOME/wts/app/fix"
  local status_lines
  status_lines="$(git -C "$HOME/src/app" worktree list --porcelain | grep -c '^worktree ')"
  assert_eq "$status_lines" "2"
  # A registered live worktree must be recognized as such and never even considered an
  # "orphan" candidate -- not just left undeleted (dir_is_cruft_only alone would also leave
  # it undeleted, since a real worktree always has a .git entry). Pin the registration-skip
  # check itself by asserting no misleading "skipped orphan" warning is ever emitted for it.
  local has_false_orphan_warning=0
  [[ "$out" == *"skipped orphan"*"/fix/LIVE"* ]] && has_false_orphan_warning=1
  assert_eq "$has_false_orphan_warning" "0" "no false 'skipped orphan' warning for a live worktree"
}

run_tests

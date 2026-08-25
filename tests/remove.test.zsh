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

# fixture_submodule: a worktree with a real, initialized submodule, configured so the
# SUPERPROJECT's own `git status` does not surface the submodule's dirtiness (untracked
# content is hidden via submodule.<name>.ignore). This isolates has_dirty_submodule as the
# thing doing the protecting -- without the ignore config, a dirty submodule would also show
# up as " M sub" in the worktree's own top-level status and get caught by the .idea/-prefix
# check instead, which would not prove has_dirty_submodule is exercised at all (F2).
fixture_submodule() {
  make_repo "$HOME/src/app"
  make_repo "$HOME/src/subchild"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  wt create app fix S main >/dev/null
  WT="$HOME/wts/app/fix/S"
  git -C "$WT" -c protocol.file.allow=always submodule add -q "$HOME/src/subchild" sub
  git -C "$WT" config submodule.sub.ignore untracked
  git -C "$WT" add -A
  git -C "$WT" commit -qm "add submodule"
}

test_remove_clean_worktree() {
  fixture
  assert_exit 0 wt remove app fix T
  assert_not_exists "$WT"
  assert_contains "$(git -C "$HOME/src/app" branch)" "fix/T" "branch kept without -b"
}

# R23: assert on workytree's OWN wording, never on text git could also emit. Plain `git
# worktree remove` (no --force) fails on a dirty worktree with its own fatal message that
# also happens to contain the substring "--force" ("...use --force to delete it"), so
# asserting on that string alone passes even with workytree's own guard deleted -- it was
# only ever measuring git's message, not the guard this test exists to protect (F1).
test_remove_dirty_requires_force() {
  fixture; print x > "$WT/new.txt"
  local out; out="$(wt remove app fix T 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "changes outside .idea/"
  assert_dir "$WT"
  assert_exit 0 wt remove app fix T --force
  assert_not_exists "$WT"
}

# F2: a dirty submodule, with the superproject's own status not showing it (see
# fixture_submodule), must be refused without --force and removed with it. This is the only
# test that forces has_dirty_submodule (rather than the .idea/-prefix check) to be the thing
# doing the refusing.
test_remove_dirty_submodule_requires_force() {
  fixture_submodule
  print x > "$WT/sub/newfile.txt"
  # Sanity: confirm the superproject's own status is blind to this dirtiness -- otherwise
  # this test would pass via has_non_idea_changes instead of exercising has_dirty_submodule.
  assert_eq "$(git -C "$WT" status --porcelain)" "" "submodule dirtiness hidden from superproject status (sanity)"
  local out; out="$(wt remove app fix S 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "changes outside .idea/"
  assert_dir "$WT"
  assert_exit 0 wt remove app fix S --force
  assert_not_exists "$WT"
}

test_remove_idea_only_is_discarded() {
  fixture; mkdir "$WT/.idea"; print x > "$WT/.idea/ws.xml"
  assert_contains "$(wt remove app fix T 2>&1)" "IDE state"
  assert_not_exists "$WT"
}

# F4/R25: a regular FILE literally named ".idea" (not the IDE's directory) can hold real
# content and must be protected like any other path outside .idea/ -- it must NOT match the
# discardable-IDE-state rule just because its name happens to be ".idea".
test_remove_idea_file_is_real_work() {
  fixture; print "PRECIOUS REAL WORK" > "$WT/.idea"
  local out; out="$(wt remove app fix T 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "changes outside .idea/"
  assert_dir "$WT"
  assert_eq "$(cat "$WT/.idea")" "PRECIOUS REAL WORK" "file survives the refusal"
  assert_exit 0 wt remove app fix T --force
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

# F9: pin the `-*) usage_error` arm itself, not just "some exit-2 path fired". Deleting that
# arm lets an unknown flag fall into the positional catch-all instead, which then trips the
# arity check ("exactly 3 positionals") and still exits 2 with a DIFFERENT message -- so a
# bare exit-code assertion here would survive that arm's deletion. Assert on the arm's own
# wording instead.
test_remove_unknown_flag_is_reported_by_name() {
  fixture
  local out; out="$(wt remove app fix T --bogus 2>&1)"
  assert_eq "$?" 2
  assert_contains "$out" "unknown flag: --bogus"
}

test_remove_flags_interleaved_with_positionals() {
  fixture; print x > "$WT/new.txt"
  assert_exit 0 wt remove --force app fix T
  assert_not_exists "$WT"
}

# F7: `--` ends option parsing, so positionals are reachable even if a later arg looks like
# a flag. Before this fix, the literal `--` itself was rejected as an unknown flag.
test_remove_dashdash_ends_options() {
  fixture
  assert_exit 0 wt remove -- app fix T
  assert_not_exists "$WT"
}

run_tests

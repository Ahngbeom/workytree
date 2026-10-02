#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

# fixture: worktree fix/T whose branch is also pushed to a bare "origin".
fixture() {
  make_repo "$HOME/src/app"
  git clone -q --bare "$HOME/src/app" "$HOME/remote.git"
  git -C "$HOME/src/app" remote add origin "$HOME/remote.git"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  wt create app fix T main >/dev/null
  WT="$HOME/wts/app/fix/T"
  git -C "$WT" push -q origin fix/T 2>/dev/null
}
answers() { printf '%s\n' "$@" > "$TMP_ROOT/answers"; export WORKYTREE_PROMPT_INPUT="$TMP_ROOT/answers"; }
local_branch()  { git -C "$HOME/src/app" branch --list "$1"; }
remote_branch() { git -C "$HOME/remote.git" branch --list "$1"; }

test_interactive_deletes_local_and_remote() {
  fixture; answers "y" "y" ""
  local out; out="$(wt remove app fix T 2>&1)"
  assert_eq "$?" 0
  assert_not_exists "$WT"
  assert_eq "$(local_branch fix/T)" ""
  assert_eq "$(remote_branch fix/T)" ""
  assert_contains "$out" "delete local branch"
  assert_contains "$out" "delete remote branch"
  assert_contains "$out" "3/3"
}

test_interactive_keeps_branches_when_declined() {
  fixture; answers "n" "n" ""
  wt remove app fix T >/dev/null 2>&1
  assert_not_exists "$WT"
  assert_contains "$(local_branch fix/T)" "fix/T"
  assert_contains "$(remote_branch fix/T)" "fix/T"
}

test_interactive_unmerged_branch_asks_force() {
  fixture
  print y > "$WT/f"; git -C "$WT" add -A; git -C "$WT" commit -qm c
  answers "y" "y" "n" ""        # delete local, force it, keep remote, proceed
  local out; out="$(wt remove app fix T 2>&1)"
  assert_contains "$out" "unmerged"
  assert_eq "$(local_branch fix/T)" ""
  assert_contains "$(remote_branch fix/T)" "fix/T"
}

test_no_remote_question_without_remote_branch() {
  fixture; git -C "$HOME/src/app" push -q origin --delete fix/T 2>/dev/null
  answers "n" ""
  local out; out="$(wt remove app fix T 2>&1)"
  assert_eq "$?" 0
  assert_not_exists "$WT"
  assert_eq "${out//delete remote branch/}" "$out" "remote question must not be asked"
}

test_cancel_at_confirmation_changes_nothing() {
  fixture; answers "y" "y" "n"
  assert_exit 130 wt remove app fix T
  assert_dir "$WT"
  assert_contains "$(local_branch fix/T)" "fix/T"
  assert_contains "$(remote_branch fix/T)" "fix/T"
}

test_dirty_worktree_offers_force_interactively() {
  fixture; print x > "$WT/new.txt"
  answers "n"
  local out; out="$(wt remove app fix T 2>&1)"
  assert_eq "$?" 130
  assert_dir "$WT"
  assert_contains "$out" "hint:"
  assert_contains "$out" "stash"
  answers "y" "n" "n" ""
  wt remove app fix T >/dev/null 2>&1
  assert_eq "$?" 0
  assert_not_exists "$WT"
}

test_destination_prompt_prints_choice_last() {
  fixture; answers "n" "n" "2" ""      # 1) stay here  2) source repo  3) parent dir
  local out; out="$(WORKYTREE_CD_CAPABLE=1 wt remove app fix T 2>/dev/null)"
  assert_eq "$out" "$HOME/src/app"
}

test_destination_prompt_reasks_on_missing_dir() {
  fixture; answers "n" "n" "$HOME/nope" "$HOME" ""
  local out; out="$(WORKYTREE_CD_CAPABLE=1 wt remove app fix T 2>/dev/null)"
  assert_eq "$out" "$HOME"
}

test_destination_not_asked_without_wrapper() {
  fixture; answers "n" "n" ""
  local out; out="$(wt remove app fix T 2>/dev/null)"
  assert_eq "$?" 0
  assert_eq "$out" ""
}

test_inside_removed_worktree_defaults_to_repo() {
  fixture; cd "$WT"
  local out; out="$(wt remove app fix T 2>/dev/null)"
  assert_eq "$?" 0
  assert_eq "$out" "$HOME/src/app"
}

test_to_flag_sets_destination() {
  fixture
  local out; out="$(wt remove app fix T --to "$HOME" 2>/dev/null)"
  assert_eq "$out" "$HOME"
}

test_to_flag_rejects_missing_dir_before_removing() {
  fixture
  local out; out="$(wt remove app fix T --to "$HOME/nope" 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "not a directory"
  assert_dir "$WT"
}

test_remote_flag_non_interactive() {
  fixture
  wt remove app fix T -r >/dev/null 2>&1
  assert_eq "$?" 0
  assert_eq "$(remote_branch fix/T)" ""
  assert_contains "$(local_branch fix/T)" "fix/T"
}

test_remote_flag_without_remote_branch_warns() {
  fixture; git -C "$HOME/src/app" push -q origin --delete fix/T 2>/dev/null
  local out; out="$(wt remove app fix T -r 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "no remote branch"
  assert_not_exists "$WT"
}

# origin is unreachable: the fetch fails, the stale tracking ref still names the branch, and
# the delete push fails too -- both reported with a way forward, and the removal still lands.
test_remote_delete_failure_shows_hint() {
  fixture; mv "$HOME/remote.git" "$HOME/remote-moved.git"
  local out; out="$(wt remove app fix T -r 2>&1)"
  assert_eq "$?" 0
  assert_not_exists "$WT"
  assert_contains "$out" "could not fetch origin"
  assert_contains "$out" "failed to delete remote branch"
  assert_contains "$out" "hint:"
}

# The branch was deleted on the remote by someone else: the fetch prunes the stale tracking
# ref, so the remote question is not asked about a branch that no longer exists.
test_fetch_prunes_remote_branch_deleted_elsewhere() {
  fixture; git -C "$HOME/remote.git" branch -D fix/T >/dev/null
  answers "n" ""
  local out; out="$(wt remove app fix T 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "fetching origin"
  assert_eq "${out//delete remote branch/}" "$out" "remote question must not be asked"
}

test_no_args_picks_worktree_from_list() {
  fixture
  wt create app fix U main >/dev/null 2>&1; wt create app feature V main >/dev/null 2>&1
  answers "2" "n" "n" ""        # app feature/V, app fix/T, app fix/U -> pick fix/T
  local out; out="$(wt remove 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "app  feature/V"
  assert_not_exists "$WT"
  assert_dir "$HOME/wts/app/fix/U"
  assert_dir "$HOME/wts/app/feature/V"
}

test_partial_args_filter_the_list() {
  fixture
  wt create app fix U main >/dev/null 2>&1; wt create app feature V main >/dev/null 2>&1
  answers "2" "n" ""            # app fix/T, app fix/U -> pick fix/U (no remote branch)
  local out; out="$(wt remove app fix 2>&1)"
  assert_eq "$?" 0
  assert_eq "${out//feature\/V/}" "$out" "other kinds must be filtered out"
  assert_not_exists "$HOME/wts/app/fix/U"
  assert_dir "$WT"
}

test_no_args_inside_worktree_offers_it_first() {
  fixture; cd "$WT"
  answers "" "n" "n" ""
  local out; out="$(wt remove 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "remove the worktree you are in"
  assert_not_exists "$WT"
}

test_no_args_inside_worktree_decline_opens_list() {
  fixture; wt create app fix U main >/dev/null 2>&1; cd "$WT"
  answers "n" "2" "n" ""        # not this one -> pick fix/U
  wt remove >/dev/null 2>&1
  assert_eq "$?" 0
  assert_dir "$WT"
  assert_not_exists "$HOME/wts/app/fix/U"
}

test_no_args_without_worktrees_shows_hint() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  answers ""
  local out; out="$(wt remove 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "no worktrees to remove"
  assert_contains "$out" "workytree create"
}

test_no_args_non_interactive_is_usage_error() {
  fixture
  assert_exit 2 wt remove
  assert_dir "$WT"
}

test_missing_worktree_shows_hint() {
  fixture
  local out; out="$(wt remove app fix NOPE 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "workytree list app"
}

test_progress_and_summary() {
  fixture
  local out; out="$(wt remove app fix T -b -r 2>&1)"
  assert_contains "$out" "1/3"
  assert_contains "$out" "3/3"
  assert_contains "$out" "summary"
  assert_contains "$out" "✓"
}

# Same repo name in two projects: the row's project must carry through, or resolve_repo
# would refuse "app" as ambiguous after the user already picked one.
test_picker_tags_and_keeps_project_for_same_named_repos() {
  make_repo "$HOME/src/app"; make_repo "$HOME/other/app"
  write_config <<CFG
[project me]
repo_root = ~/src
worktree_root = ~/wts
[project other]
repo_root = ~/other
worktree_root = ~/owts
CFG
  wt --project me create app fix A main -y >/dev/null 2>&1
  wt --project other create app fix B main -y >/dev/null 2>&1
  answers "2" "n" ""
  local out; out="$(wt remove 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "app  fix/B  [other]"
  assert_not_exists "$HOME/owts/app/fix/B"
  assert_dir "$HOME/wts/app/fix/A"
}

run_tests

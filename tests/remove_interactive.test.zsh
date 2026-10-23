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

# An upstream deleted on the remote stays configured after `fetch --prune` (track: [gone]);
# it must not be offered for deletion, nor pushed to with -r.
test_gone_upstream_is_not_offered() {
  fixture
  git -C "$HOME/src/app" branch -q -u origin/fix/T fix/T
  git -C "$HOME/remote.git" branch -D fix/T >/dev/null
  answers "n" ""
  local out; out="$(wt remove app fix T 2>&1)"
  assert_eq "$?" 0
  assert_eq "${out//delete remote branch/}" "$out" "gone upstream must not be offered"
}

test_gone_upstream_with_remote_flag_skips_push() {
  fixture
  git -C "$HOME/src/app" branch -q -u origin/fix/T fix/T
  git -C "$HOME/remote.git" branch -D fix/T >/dev/null
  local out; out="$(wt remove app fix T -r 2>&1)"
  assert_contains "$out" "no remote branch known"
  assert_eq "${out//failed to delete remote branch/}" "$out" "no doomed push"
}

# commit_in_wt <name>: one commit in the worktree; prints its sha.
commit_in_wt() { print "$1" > "$WT/$1"; git -C "$WT" add -A; git -C "$WT" commit -qm "$1"; git -C "$WT" rev-parse HEAD; }

test_pushed_only_branch_is_not_called_merged() {
  fixture; commit_in_wt C >/dev/null
  git -C "$WT" push -q -u origin fix/T 2>/dev/null
  answers "" "n" ""             # local: default, remote: no, proceed
  local out; out="$(wt remove app fix T 2>&1)"
  assert_contains "$out" "delete local branch 'fix/T'? (pushed, not merged into origin/main)"
  assert_contains "$(local_branch fix/T)" "fix/T" "default is No"
}

test_branch_and_remote_flags_keep_a_branch_not_merged_into_base() {
  fixture; local sha; sha="$(commit_in_wt C)"
  git -C "$WT" push -q -u origin fix/T 2>/dev/null
  local out; out="$(wt remove app fix T -b -r 2>&1)"
  assert_eq "$?" 0
  assert_eq "$(remote_branch fix/T)" "" "remote branch deleted"
  assert_contains "$(local_branch fix/T)" "fix/T" "local branch kept"
  assert_contains "$out" "not merged into origin/main; use -B"
  assert_contains "$(git -C "$HOME/src/app" rev-list --all)" "$sha" "commit still reachable"
}

test_pushed_branch_asks_before_deleting_both_copies() {
  fixture; local sha; sha="$(commit_in_wt C)"
  git -C "$WT" push -q -u origin fix/T 2>/dev/null
  answers "y" "y" "" ""         # local: yes, remote: yes, delete both anyway: default, proceed
  local out; out="$(wt remove app fix T 2>&1)"
  assert_contains "$out" "its remote branch is being deleted too"
  assert_contains "$(local_branch fix/T)" "fix/T" "default keeps the local branch"
  assert_eq "$(remote_branch fix/T)" "" "remote branch deleted"
}

# merged_and_gone_fixture: someone merged fix/T into origin/main and deleted its remote branch;
# the local main checkout never pulled.
merged_and_gone_fixture() {
  fixture; commit_in_wt G >/dev/null
  git -C "$WT" push -q -u origin fix/T 2>/dev/null
  git clone -q "$HOME/remote.git" "$HOME/other"
  git -C "$HOME/other" merge -q --no-ff -m "Merge PR" origin/fix/T
  git -C "$HOME/other" push -q origin main
  git -C "$HOME/other" push -q origin --delete fix/T
  git -C "$HOME/src/app" fetch -q --prune origin
}

test_branch_merged_into_origin_after_its_remote_was_deleted_is_merged() {
  merged_and_gone_fixture
  answers "" ""                 # local: default, proceed
  local out; out="$(wt remove app fix T 2>&1)"
  assert_contains "$out" "delete local branch 'fix/T'? (merged into origin/main)"
  assert_eq "${out//unmerged/}" "$out" "no force question"
  assert_eq "$(local_branch fix/T)" ""
}

test_branch_flag_deletes_a_branch_merged_into_origin_without_force() {
  merged_and_gone_fixture
  local out; out="$(wt remove app fix T -b 2>&1)"
  assert_eq "$?" 0
  assert_eq "$(local_branch fix/T)" "" "deleted although local main is stale"
}

# create accepts a ticket containing "/", nesting the worktree one level deeper.
test_picker_finds_ticket_with_slash() {
  fixture
  wt create app feature team/X main >/dev/null 2>&1
  mkdir -p "$WT/sub"; print "gitdir: elsewhere" > "$WT/sub/.git"   # submodule-like, inside a worktree
  answers "1" "n" ""
  local out; out="$(wt remove app feature 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "app  feature/team/X"
  assert_not_exists "$HOME/wts/app/feature/team/X"
  answers ""
  out="$(wt remove app fix 2>&1)"
  assert_eq "${out//T\/sub/}" "$out" "never descends into a worktree"
}

test_questions_name_the_ticket_branch_when_another_is_checked_out() {
  fixture; git -C "$WT" switch -q -c spike
  answers "y" "n" ""            # local fix/T: yes, remote origin/fix/T: no, proceed
  local out; out="$(wt remove app fix T 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "delete local branch 'fix/T'?"
  assert_contains "$out" "checked out: spike"
  assert_eq "$(local_branch fix/T)" ""
  assert_contains "$(local_branch spike)" spike
}

test_remote_delete_prints_a_restore_command() {
  fixture
  local short out; short="$(git -C "$WT" rev-parse --short HEAD)"
  out="$(wt remove app fix T -r 2>&1)"
  assert_contains "$out" "deleted remote branch origin/fix/T (was $short)"
  assert_contains "$out" "restore it with: git -C $HOME/src/app push origin ${short}:refs/heads/fix/T"
  git -C "$HOME/src/app" push -q origin "${short}:refs/heads/fix/T"
  assert_contains "$(remote_branch fix/T)" fix/T "restored"
}

# teammate_pushes: someone else adds a commit to origin/fix/T; prints its sha.
teammate_pushes() {
  git clone -q -b fix/T "$HOME/remote.git" "$HOME/mate" 2>/dev/null
  git -C "$HOME/mate" commit -q --allow-empty -m teammate
  git -C "$HOME/mate" push -q origin fix/T 2>/dev/null
  git -C "$HOME/mate" rev-parse HEAD
}
# holders <git dir> <sha>: the refs that still reach <sha>.
holders() { git -C "$1" for-each-ref --format='%(refname)' --contains "$2"; }

test_remote_flag_keeps_a_remote_branch_with_commits_only_there() {
  fixture; local sha out; sha="$(teammate_pushes)"
  out="$(wt remove app fix T -r -y 2>&1)"
  assert_eq "$?" 0
  assert_contains "$(holders "$HOME/remote.git" "$sha")" refs/heads/fix/T "teammate commit still on the remote"
  assert_contains "$(holders "$HOME/src/app" "$sha")" refs/remotes/origin/fix/T "teammate commit still tracked"
  assert_contains "$out" "keeping remote branch origin/fix/T: it has commits that are not in fix/T or origin/main"
  assert_contains "$out" "push origin --delete fix/T (or pass -B)"
  assert_contains "$out" "remote branch  kept          origin/fix/T (has commits not in fix/T or origin/main; use -B)"
}

test_branch_and_remote_flags_keep_a_remote_branch_with_a_teammate_commit() {
  fixture; local sha out; sha="$(teammate_pushes)"
  out="$(wt remove app fix T -b -r -y 2>&1)"
  assert_eq "$?" 0
  assert_eq "$(local_branch fix/T)" "" "merged local branch deleted"
  assert_contains "$(holders "$HOME/remote.git" "$sha")" refs/heads/fix/T "teammate commit still on the remote"
  assert_contains "$out" "origin/fix/T (has commits not in fix/T or origin/main; use -B)"
}

test_branch_force_flag_deletes_a_remote_branch_with_a_teammate_commit() {
  fixture; local sha short out; sha="$(teammate_pushes)"
  out="$(wt remove app fix T -B -r -y 2>&1)"
  short="$(git -C "$HOME/src/app" rev-parse --short "$sha")"
  assert_eq "$(remote_branch fix/T)" "" "-B overrides"
  assert_contains "$out" "deleted remote branch origin/fix/T (was $short)"
  assert_contains "$out" "restore it with: git -C $HOME/src/app push origin ${short}:refs/heads/fix/T"
}

# origin's fetch URL is unreachable and its push URL is not, so the tracking ref still names the
# tip from before the teammate's push.
test_remote_delete_spares_a_branch_that_moved_since_the_last_fetch() {
  fixture
  git -C "$HOME/src/app" remote set-url origin "$HOME/nowhere.git"
  git -C "$HOME/src/app" remote set-url --push origin "$HOME/remote.git"
  local sha out; sha="$(teammate_pushes)"
  out="$(wt remove app fix T -r -y 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "could not fetch origin"
  assert_contains "$(holders "$HOME/remote.git" "$sha")" refs/heads/fix/T "teammate commit still on the remote"
  assert_contains "$out" "remote branch  not deleted   origin/fix/T"
  assert_eq "${out//deleted remote branch/}" "$out" "no success line"
}

test_remote_flag_deletes_a_remote_branch_the_kept_local_branch_holds() {
  fixture; commit_in_wt C >/dev/null
  git -C "$WT" push -q -u origin fix/T 2>/dev/null
  local out; out="$(wt remove app fix T -r -y 2>&1)"
  assert_eq "$?" 0
  assert_eq "$(remote_branch fix/T)" "" "remote branch deleted"
  assert_contains "$(local_branch fix/T)" fix/T "local branch kept"
}

test_branch_and_remote_flags_without_a_remote_branch_claim_no_remote_delete() {
  fixture; git -C "$HOME/src/app" push -q origin --delete fix/T 2>/dev/null
  commit_in_wt C >/dev/null
  local out; out="$(wt remove app fix T -b -r -y 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "no remote branch known for 'fix/T'"
  assert_eq "${out//remote branch is being deleted/}" "$out" "no remote delete claimed"
  assert_contains "$(local_branch fix/T)" fix/T "unmerged local branch kept"
}

test_remote_question_about_commits_only_there_defaults_to_no() {
  fixture; local sha out; sha="$(teammate_pushes)"
  answers "y" "y" "" ""         # local: yes, remote: yes, lose the remote's commits: default, proceed
  out="$(wt remove app fix T 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "'origin/fix/T' has commits that are not in fix/T or origin/main — delete it anyway and lose them?"
  assert_eq "$(local_branch fix/T)" "" "local branch deleted"
  assert_contains "$(holders "$HOME/remote.git" "$sha")" refs/heads/fix/T "default keeps the remote branch"
  assert_contains "$out" "origin/fix/T (has commits not in fix/T or origin/main; use -B)"
}

# develop_upstream_fixture: fix/T tracks origin/develop, as after `switch -c fix/T origin/develop`.
develop_upstream_fixture() {
  fixture
  git -C "$HOME/src/app" push -q origin main:develop 2>/dev/null
  git -C "$HOME/src/app" branch -q -u origin/develop fix/T
}

test_remote_flag_ignores_an_upstream_with_another_name() {
  develop_upstream_fixture; git -C "$HOME/src/app" push -q origin --delete fix/T 2>/dev/null
  local out; out="$(wt remove app fix T -r -y 2>&1)"
  assert_eq "$?" 0
  assert_contains "$(remote_branch develop)" develop "origin/develop untouched"
  assert_contains "$out" "no remote branch known for 'fix/T'"
}

test_remote_flag_deletes_the_same_named_branch_not_the_upstream() {
  develop_upstream_fixture
  local out; out="$(wt remove app fix T -r -y 2>&1)"
  assert_eq "$?" 0
  assert_contains "$(remote_branch develop)" develop "origin/develop untouched"
  assert_eq "$(remote_branch fix/T)" "" "origin/fix/T deleted"
}

# remove_with_prs <args...>: remove with lib/ sourced in a subshell and forge_pr_rows answering
# from $HOME/prs. A fake gh on PATH cannot shadow a real one (bin/workytree's PATH).
remove_with_prs() {
  ( setopt extendedglob
    typeset -g WT_PROJECT_OPT='' WT_AI_RUNFILE=''; typeset -gi WT_YES=1 WT_CAN_CD=0
    local f; for f in "$WT_TEST_ROOT"/lib/*.zsh "$WT_TEST_ROOT"/lib/cmd/*.zsh; do source "$f"; done
    forge_pr_rows() { cat "$HOME/prs"; }
    ui_init; config_load; cmd_remove "$@" ) < /dev/null
}

test_remote_branch_whose_pr_was_merged_at_its_tip_is_deleted() {
  fixture; commit_in_wt C >/dev/null
  git -C "$WT" push -q -u origin fix/T 2>/dev/null
  local sha out; sha="$(teammate_pushes)"
  printf 'fix/T\t#7\tmerged\thttps://x/7\t%s\n' "$sha" > "$HOME/prs"
  out="$(remove_with_prs app fix T -b -r 2>&1)"
  assert_eq "$?" 0
  assert_eq "$(remote_branch fix/T)" "" "the forge keeps the PR's commits"
  assert_contains "$(local_branch fix/T)" fix/T "local branch is not merged"
}

test_typed_ahead_keys_do_not_confirm_the_removal() {
  make_repo "$HOME/src/app"
  write_config <<EOF2
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF2
  wt create app fix T main >/dev/null 2>&1
  pty_start "WORKYTREE_PROMPT_INPUT=/dev/tty WORKYTREE_PROMPT_KEYS=1 ${(q)WT_BIN} remove; print -r -- \$? > ${(q)TMP_ROOT}/rc"
  pty_wait "worktree to remove" 50
  pty_send $'1\r2\r'
  pty_wait "delete local branch" 50; sleep 0.5
  assert_dir "$HOME/wts/app/fix/T" "nothing removed while the branch question waits"
  pty_send n
  pty_wait "Proceed?" 50; sleep 0.3
  pty_send n
  pty_finish 50
  assert_eq "$(<$TMP_ROOT/rc)" 130
  assert_dir "$HOME/wts/app/fix/T"
  assert_contains "$(git -C "$HOME/src/app" branch --list fix/T)" fix/T
}

remove_as_branch_moves() {
  ( setopt extendedglob
    typeset -g WT_PROJECT_OPT='' WT_AI_RUNFILE=''; typeset -gi WT_YES=0 WT_CAN_CD=0
    local f; for f in "$WT_TEST_ROOT"/lib/*.zsh "$WT_TEST_ROOT"/lib/cmd/*.zsh; do source "$f"; done
    forge_pr_rows() { return 0; }
    functions -c branch_verdict judge_branch
    branch_verdict() {
      judge_branch "$@"
      local -i rc=$?
      local verdict="$REPLY" moved
      moved="$(git -C "$1" commit-tree -p "refs/heads/$2" -m moved "refs/heads/$2^{tree}")"
      git -C "$1" update-ref "refs/heads/$2" "$moved" && print -r -- "$moved" > "$HOME/moved-to"
      REPLY="$verdict"; return $rc
    }
    ui_init; config_load; cmd_remove "$@" ) < /dev/null
}

test_merged_branch_that_moves_after_the_verdict_is_kept() {
  fixture
  local out; out="$(remove_as_branch_moves app fix T -b 2>&1)"
  assert_eq "$?" 0
  local moved; moved="$(<$HOME/moved-to)"
  assert_not_exists "$WT"
  assert_eq "$(git -C "$HOME/src/app" rev-parse -q --verify refs/heads/fix/T)" "$moved" "branch kept at the new tip"
  assert_contains "$out" "moved since it was checked"
  assert_contains "$(git -C "$HOME/src/app" rev-list --all)" "$moved" "new commit still reachable"
}

test_confirmed_force_delete_spares_a_branch_that_moved_after_the_verdict() {
  fixture; local sha; sha="$(commit_in_wt C)"
  answers "y" "y" "n" ""        # delete local, force it, keep remote, proceed
  local out; out="$(remove_as_branch_moves app fix T 2>&1)"
  assert_eq "$?" 0
  local moved; moved="$(<$HOME/moved-to)"
  assert_contains "$out" "unmerged"
  assert_not_exists "$WT"
  assert_eq "$(git -C "$HOME/src/app" rev-parse -q --verify refs/heads/fix/T)" "$moved" "branch kept at the new tip"
  assert_contains "$out" "moved since it was checked"
  assert_contains "$(git -C "$HOME/src/app" rev-list --all)" "$sha" "the commits the user was shown survive too"
}

test_branch_force_flag_deletes_a_branch_that_moved_after_the_verdict() {
  fixture; commit_in_wt C >/dev/null
  answers "n" ""                # keep remote, proceed
  local out; out="$(remove_as_branch_moves app fix T -B 2>&1)"
  assert_eq "$?" 0
  assert_eq "$(local_branch fix/T)" "" "-B deletes whatever is there"
  assert_eq "${out//moved since it was checked/}" "$out" "no moved warning under -B"
}

run_tests

#!/usr/bin/env zsh
# status_collect_branches: branch records from real git fixtures.
source "${0:A:h}/helpers.zsh"
for f in $WT_TEST_ROOT/lib/*.zsh; do source "$f"; done
forge_pr_rows() { return 1; }

typeset -g ROWS='' A=''
functions[_helpers_setup_env]=$functions[setup_env]
setup_env() { _helpers_setup_env; A="$HOME/src/app"; }

# bf <branch> <n>: field n of the first record whose branch field is <branch>, else MISSING.
bf() {
  local line; local -a f
  for line in "${(@f)ROWS}"; do
    f=("${(@ps:\t:)line}")
    [[ "${f[5]}" == "$1" ]] && { print -r -- "${f[$2]}"; return; }
  done
  print MISSING
}
row_count() { local -a l; l=("${(@f)ROWS}"); [[ -n "$ROWS" ]] && print ${#l} || print 0; }

# app_with_origin: ~/src/app on main, pushed to bare ~/remote.git, user.email t@t.
app_with_origin() {
  make_repo "$A"
  git init -q --bare "$HOME/remote.git"
  git -C "$A" remote add origin "$HOME/remote.git"
  git -C "$A" push -q -u origin main
  git -C "$A" config user.email t@t
}
commit() { git -C "$A" commit -q --allow-empty -m "${1:-c}"; }
teammate_commit() { GIT_AUTHOR_EMAIL=x@y GIT_COMMITTER_EMAIL=x@y git -C "$A" commit -q --allow-empty -m "${1:-t}"; }
collect() { ROWS="$(status_collect_branches me app "$A" 30 "$@" 2>/dev/null)"; }

test_merged_local_and_own_remote_share_one_row() {
  app_with_origin
  git -C "$A" switch -q -c fix/m; commit; git -C "$A" push -q -u origin fix/m
  git -C "$A" switch -q main
  git -C "$A" merge -q --no-ff fix/m -m merge; git -C "$A" push -q origin main
  collect
  assert_eq "$(row_count)" 1 one-row
  assert_eq "$(bf fix/m 1)" branch type
  assert_eq "$(bf fix/m 10)" merged why
  assert_eq "$(bf fix/m 11)" safe class
  assert_eq "$(bf fix/m 9)" me owner
  assert_eq "${#$(bf fix/m 6)}" 40 local-sha
  assert_eq "${#$(bf fix/m 7)}" 40 remote-sha
  assert_eq "$(bf fix/m 8)" 0 not-gone
  assert_eq "$(bf fix/m 13)" 0 base-ahead
  assert_eq "$(bf fix/m 17)" "merged into origin/main" note
  assert_eq "$(bf fix/m 14)" - no-key
  assert_eq "$(bf fix/m 15)" - no-pr
}

# teammate_remote: fix/t committed by x@y, pushed, local copy deleted.
teammate_remote() {
  app_with_origin
  git -C "$A" switch -q -c fix/t; teammate_commit; git -C "$A" push -q -u origin fix/t
  git -C "$A" switch -q main; git -C "$A" branch -q -D fix/t
}

test_teammate_only_remote_is_read_only() {
  teammate_remote
  collect
  assert_eq "$(bf fix/t 10)" read-only why
  assert_eq "$(bf fix/t 11)" none class
  assert_eq "$(bf fix/t 6)" - no-local
  assert_eq "$(bf fix/t 9)" teammate owner
  assert_eq "$(bf fix/t 13)" - nothing-to-delete
  assert_eq "$(bf fix/t 17)" "origin branch by x@y" note
}

test_local_copy_of_teammate_branch_is_pushed() {
  teammate_remote
  git -C "$A" branch -q --no-track fix/t origin/fix/t
  collect
  assert_eq "$(bf fix/t 10)" pushed why
  assert_eq "$(bf fix/t 11)" safe class
  assert_eq "$(bf fix/t 6)" "$(bf fix/t 7)" same-sha
  assert_eq "$(bf fix/t 17)" "same as origin/fix/t" note
}

test_own_remote_does_not_make_the_local_copy_pushed() {
  app_with_origin
  git -C "$A" switch -q -c fix/o; commit; git -C "$A" push -q -u origin fix/o
  git -C "$A" switch -q main
  collect
  assert_eq "$(bf fix/o 10)" unmerged why
  assert_eq "$(bf fix/o 11)" force class
  assert_eq "$(bf fix/o 13)" 1 base-ahead
  assert_eq "$(bf fix/o 17)" "1 commits not in origin/main" note
}

test_squash_merged_branch_is_merged_by_its_pr() {
  app_with_origin
  git -C "$A" switch -q -c fix/s; commit; git -C "$A" push -q -u origin fix/s
  git -C "$A" switch -q main
  git --git-dir="$HOME/remote.git" branch -q -D fix/s
  git -C "$A" fetch -q --prune
  print -r -- $'fix/s\t!4\tmerged\tu\t'"$(git -C "$A" rev-parse fix/s)" > "$HOME/prs"
  collect "$HOME/prs"
  assert_eq "$(bf fix/s 10)" merged why
  assert_eq "$(bf fix/s 8)" 1 gone
  assert_eq "$(bf fix/s 7)" - no-remote
  assert_eq "$(bf fix/s 9)" - no-owner
  assert_eq "$(bf fix/s 15)" '!4' pr-ref
  assert_eq "$(bf fix/s 16)" merged pr-state
  assert_eq "$(bf fix/s 17)" 'PR !4 merged' note
}

test_gone_and_stale_notes_count_commits_not_in_base() {
  app_with_origin
  git -C "$A" switch -q -c fix/g; commit; commit; git -C "$A" push -q -u origin fix/g
  git -C "$A" push -q origin --delete fix/g
  git -C "$A" switch -q main
  git -C "$A" switch -q -c fix/old
  GIT_COMMITTER_DATE="@$(( EPOCHSECONDS - 100 * 86400 )) +0000" commit
  git -C "$A" switch -q main
  collect
  assert_eq "$(bf fix/g 10)" gone gone-why
  assert_eq "$(bf fix/g 17)" "upstream deleted, 2 commits not in origin/main" gone-note
  assert_eq "$(bf fix/old 10)" stale stale-why
  assert_eq "$(bf fix/old 11)" force stale-class
  assert_eq "$(bf fix/old 17)" "3mo old, 1 commits not in origin/main" stale-note
  assert_eq "$(bf fix/old 5)" "$(print -r -- "${ROWS%%$'\n'*}" | cut -f5)" oldest-first
}

# backup_branch: backup/AB-1-pre-squash with a commit of its own, no origin.
backup_branch() {
  make_repo "$A"
  git -C "$A" config user.email t@t
  git -C "$A" switch -q -c backup/AB-1-pre-squash; commit; git -C "$A" switch -q main
}

test_backup_of_a_merged_ticket_is_safe() {
  backup_branch
  print -r -- $'fix/AB-1\t!5\tmerged\tu\tdead' > "$HOME/prs"
  collect "$HOME/prs"
  assert_eq "$(bf backup/AB-1-pre-squash 10)" backup why
  assert_eq "$(bf backup/AB-1-pre-squash 14)" AB-1 key
  assert_eq "$(bf backup/AB-1-pre-squash 11)" safe class
  assert_eq "$(bf backup/AB-1-pre-squash 17)" "backup of AB-1 (PR !5 merged)" note
}

test_unproven_backups_stay_unmerged() {
  backup_branch
  local b=backup/AB-1-pre-squash
  print -r -- $'fix/AB-1\t!5\tmerged\tu\tdead\nfix/AB-1-x\t!6\topen\tu\tbeef' > "$HOME/prs"
  collect "$HOME/prs"
  assert_eq "$(bf $b 10)" unmerged open-why
  assert_eq "$(bf $b 11)" force open-class
  assert_eq "$(bf $b 14)" AB-1 open-key
  assert_contains "$(bf $b 17)" "PR !6 open" open-note
  assert_eq "${$(bf $b 17)%PR !6 open}" "backup of AB-1: " open-note-ends
  print -r -- $'fix/ZZ-9\t!7\tmerged\tu\tdead' > "$HOME/prs"
  collect "$HOME/prs"
  assert_eq "$(bf $b 10)" unmerged none-why
  assert_eq "$(bf $b 17)" "backup of AB-1: no merged PR" none-note
  collect
  assert_eq "$(bf $b 10)" unmerged skipped-why
  assert_eq "$(bf $b 17)" "backup of AB-1: PR lookup skipped" skipped-note
  collect "$HOME/no-such-file"
  assert_eq "$(bf $b 17)" "backup of AB-1: PR lookup skipped" missing-file-note
}

test_base_head_checked_out_and_protected_are_handled() {
  app_with_origin
  git -C "$A" branch -q master
  git -C "$A" switch -q -c develop; commit; git -C "$A" push -q -u origin develop master
  git -C "$A" remote set-head origin develop
  git -C "$A" worktree add -q -b fix/w "$HOME/wts/fix-w"
  git -C "$A" push -q origin fix/w
  collect
  assert_eq "$(bf develop 1)" MISSING base
  assert_eq "$(bf HEAD 1)" MISSING origin-head
  assert_eq "$(bf fix/w 1)" MISSING checked-out
  assert_eq "$(bf main 10)" protected main-why
  assert_eq "$(bf main 11)" none main-class
  assert_eq "$(bf master 10)" protected master-why
  assert_eq "$(bf master 17)" protected master-note
  assert_eq "$(row_count)" 2 rows
}

test_repo_without_origin_lists_local_branches_only() {
  make_repo "$A"
  git -C "$A" config user.email t@t
  git -C "$A" switch -q -c fix/l; commit; git -C "$A" switch -q main
  collect
  assert_eq "$(row_count)" 1 one-row
  assert_eq "$(bf fix/l 7)" - no-remote
  assert_eq "$(bf fix/l 9)" - no-owner
  assert_eq "$(bf fix/l 10)" unmerged why
  assert_eq "$(bf fix/l 17)" "1 commits not in main" note
}

test_special_characters_in_names() {
  teammate_remote
  local b
  for b in 'fix/q"x' 'fix/a$b'"'"'c' 'fix/(x|y)'; do
    git -C "$A" branch -q "$b" origin/fix/t; git -C "$A" push -q origin "$b"
    git -C "$A" branch -q --unset-upstream "$b" 2>/dev/null
  done
  collect
  for b in 'fix/q"x' 'fix/a$b'"'"'c' 'fix/(x|y)'; do
    assert_eq "$(bf "$b" 10)" pushed "why $b"
    assert_eq "$(bf "$b" 6)" "$(git -C "$A" rev-parse "refs/heads/$b")" "local sha $b"
    assert_eq "$(bf "$b" 17)" "same as origin/$b" "note $b"
  done
}

test_unreadable_repo_is_one_error_record() {
  mkdir -p "$A"
  ROWS="$(status_collect_branches me app "$A" 30 2>/dev/null)"
  local -a f; f=("${(@ps:\t:)ROWS}")
  assert_eq "$(row_count)" 1 one-row
  assert_eq "${f[1]}" error type
  assert_eq "${#f}" 17 fields
  assert_contains "${f[17]}" "not a git repository" note
}

test_collection_leaves_refs_untouched() {
  teammate_remote
  git -C "$A" switch -q -c fix/g; commit; git -C "$A" push -q -u origin fix/g
  git -C "$A" push -q origin --delete fix/g
  git -C "$A" switch -q main
  git -C "$A" branch -q backup/AB-1-pre-squash fix/g
  git -C "$A" remote set-head origin main
  print -r -- $'fix/AB-1\t!5\tmerged\tu\tdead' > "$HOME/prs"
  local fmt='%(refname) %(objectname) %(upstream) %(symref)' before remote_before
  before="$(git -C "$A" for-each-ref --format="$fmt")"
  remote_before="$(git --git-dir="$HOME/remote.git" for-each-ref --format="$fmt")"
  collect "$HOME/prs"
  assert_eq "$(bf backup/AB-1-pre-squash 10)" backup sanity
  assert_eq "$(git -C "$A" for-each-ref --format="$fmt")" "$before" local-refs
  assert_eq "$(git --git-dir="$HOME/remote.git" for-each-ref --format="$fmt")" "$remote_before" remote-refs
  assert_not_exists "$A/.git/FETCH_HEAD"
}

test_collection_does_not_call_git_per_branch() {
  make_repo "$A"
  git init -q --bare "$HOME/remote.git"
  git -C "$A" remote add origin "$HOME/remote.git"
  git -C "$A" push -q -u origin main
  git -C "$A" switch -q -c tmp; teammate_commit; git -C "$A" switch -q main
  local -i i
  for (( i = 1; i <= 40; i++ )); do git -C "$A" branch -q r/$i tmp; git -C "$A" branch -q c/$i tmp; done
  git -C "$A" push -q origin 'refs/heads/r/*:refs/heads/r/*' 'refs/heads/c/*:refs/heads/c/*'
  for (( i = 1; i <= 40; i++ )); do git -C "$A" branch -q -D r/$i; done
  git -C "$A" branch -q -D tmp
  ROWS="$(git() { print x >> "$HOME/git.calls"; command git "$@"; }; status_collect_branches me app "$A" 30 2>/dev/null)"
  local -a calls; calls=("${(@f)$(<"$HOME/git.calls")}")
  assert_eq "$(row_count)" 80 rows
  assert_eq "$(bf r/7 10)" read-only remote-only
  assert_eq "$(bf c/7 10)" pushed local-copy
  (( ${#calls} <= 12 )) && assert_eq ok ok || assert_eq "${#calls} git calls" "<= 12" git-calls
}

run_tests

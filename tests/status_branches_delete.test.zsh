#!/usr/bin/env zsh
# alt-d in branch mode: the plan re-judged from fresh refs, its questions, and the deletion of
# what was approved.
source "${0:A:h}/helpers.zsh"
for f in "$WT_TEST_ROOT"/lib/*.zsh "$WT_TEST_ROOT"/lib/cmd/*.zsh; do source "$f"; done
_status_pause() { :; }
functions[_real_wt_fetch_origin]=$functions[wt_fetch_origin]
functions -c remove_branch real_remove_branch
functions -c remove_remote_branch real_remove_remote_branch

typeset -g A=''
functions[_helpers_setup_env]=$functions[setup_env]
setup_env() {
  _helpers_setup_env
  A="$HOME/src/app"
  typeset -ga WT_PROJECTS=(me)
  typeset -gA WT_PCFG=(me.repo_root "$HOME/src" me.worktree_root "$HOME/wts") WT_CFG=() WT_RCFG=()
  WT_PROJECT_OPT='' WT_COLOR=0
  _status_parse_opts
  forge_pr_rows() { [[ -r "$HOME/prs" ]] && cat "$HOME/prs"; return 0; }
  functions[wt_fetch_origin]=$functions[_real_wt_fetch_origin]
  functions[remove_branch]=$functions[real_remove_branch]
  functions[remove_remote_branch]=$functions[real_remove_remote_branch]
}

# app_with_origin [dir]: <dir> (default ~/src/app) on main, pushed to bare ~/remote.git,
# user.email t@t.
app_with_origin() {
  local d="${1:-$A}"
  make_repo "$d"
  git init -q --bare "$HOME/remote.git"
  git -C "$d" remote add origin "$HOME/remote.git"
  git -C "$d" push -q -u origin main
  git -C "$d" config user.email t@t
}
commit() { git -C "$A" commit -q --allow-empty -m "${1:-c}"; }
old_commit() { GIT_COMMITTER_DATE="@$(( EPOCHSECONDS - 100 * 86400 )) +0000" git -C "$A" commit -q --allow-empty -m old; }
teammate_commit() { GIT_AUTHOR_EMAIL=x@y GIT_COMMITTER_EMAIL=x@y git -C "$A" commit -q --allow-empty -m "${1:-t}"; }

# merged_branch <name>: <name> with one commit, merged into main; with origin, both pushed.
merged_branch() {
  git -C "$A" switch -q -c "$1"; commit
  git -C "$A" remote get-url origin >/dev/null 2>&1 && git -C "$A" push -q -u origin "$1"
  git -C "$A" switch -q main
  git -C "$A" merge -q --no-ff "$1" -m "merge $1"
  git -C "$A" remote get-url origin >/dev/null 2>&1 && git -C "$A" push -q origin main
  return 0
}
stale_branch() { git -C "$A" switch -q -c "$1"; old_commit; git -C "$A" switch -q main; }
# teammate_remote <name>: <name> committed by x@y and pushed, local copy deleted.
teammate_remote() {
  git -C "$A" switch -q -c "$1"; teammate_commit; git -C "$A" push -q -u origin "$1"
  git -C "$A" switch -q main; git -C "$A" branch -q -D "$1"
}

# mark [-d dir] <branch...>: the fzf lines (record TAB display) of those branches, as {+f}
# writes them, into ~/marked.
mark() {
  local d="$A"
  [[ "$1" == -d ]] && { d="$2"; shift 2; }
  local rows line b
  local -a f
  rows="$(status_collect_branches me "${d:t}" "$d" 30 2>/dev/null)"
  _branches_format "$rows"
  : > "$HOME/marked"
  local -i k
  for (( k = 1; k <= ${#ST_RECS}; k++ )); do
    f=("${(@ps:\t:)ST_RECS[k]}")
    for b in "$@"; do
      [[ "${f[5]}" == "$b" ]] && print -r -- "${ST_RECS[k]}"$'\t'"${ST_LINES[k]}" >> "$HOME/marked"
    done
  done
}

# delete_marked [--eof | answer...]: _branches_delete on ~/marked in a subshell (prompt fds
# and exit 130 stay there); BR_PLAN to ~/plan, BR_APPROVED to ~/approved, stderr to ~/err,
# rc to ~/rc. --eof gives an empty answers file.
delete_marked() {
  if [[ "${1:-}" == --eof ]]; then : > "$HOME/answers"; else printf '%s\n' "$@" > "$HOME/answers"; fi
  rm -f "$HOME/plan" "$HOME/approved"
  ( export WORKYTREE_PROMPT_INPUT="$HOME/answers"
    _branches_delete "$HOME/marked"
    print -rl -- "${BR_PLAN[@]}" > "$HOME/plan"
    print -rl -- "${BR_APPROVED[@]}" > "$HOME/approved" ) < /dev/null 2> "$HOME/err"
  print -r -- $? > "$HOME/rc"
}

# forge_marked <field=value...>: rewrite those record fields of every line in ~/marked.
forge_marked() {
  local line kv; local -a f out
  for line in "${(@f)$(<"$HOME/marked")}"; do
    f=("${(@ps:\t:)line}")
    for kv in "$@"; do f[${kv%%=*}]="${kv#*=}"; done
    out+=("${(pj:\t:)f}")
  done
  print -rl -- "${out[@]}" > "$HOME/marked"
}

# plan_has <class> <branch> <target>: the BR_PLAN element, else MISSING.
plan_has() {
  local line; local -a f
  for line in "${(@f)$(<"$HOME/plan")}"; do
    f=("${(@ps:\t:)line}")
    [[ "${f[1]}" == "$1" && "${f[3]}" == "$2" && "${f[4]}" == "$3" ]] && { print -r -- "$line"; return; }
  done
  print MISSING
}

# group <safe|force|skip>: the plan lines printed under that heading.
group() {
  local out="$(<"$HOME/err")" from to
  case "$1" in
    safe) from="safe — merged or its ticket is merged" to="needs force — " ;;
    force) from="needs force — commits would exist nowhere else" to=$'\nskipped\n' ;;
    skip) from=$'\nskipped\n' to="__none__" ;;
  esac
  out="${out#*$from}"
  print -r -- "${out%%$to*}"
}

test_plan_groups_safe_force_and_skipped() {
  app_with_origin
  merged_branch fix/m; stale_branch fix/old; teammate_remote fix/t
  mark fix/m fix/old fix/t
  delete_marked n n
  assert_contains "$(group safe)" "fix/m" safe-group
  assert_contains "$(group safe)" "local+origin" safe-target
  assert_contains "$(group safe)" "merged into origin/main" safe-note
  assert_contains "$(group force)" "fix/old" force-group
  assert_contains "$(group force)" "3mo old" force-note
  assert_contains "$(group skip)" "fix/t" skip-group
  assert_contains "$(group skip)" "origin branch by x@y" skip-reason
  assert_eq "${$(group safe)#*fix/old}" "$(group safe)" "stale not in safe"
  assert_eq "${$(group force)#*fix/t}" "$(group force)" "teammate not in force"
  assert_contains "$(plan_has safe fix/m local+origin)" "$A"$'\tfix/m\tlocal+origin\t'"$(git -C "$A" rev-parse fix/m)"$'\t'"$(git -C "$A" rev-parse origin/fix/m)" plan-shas
  assert_eq "${$(plan_has force fix/old local)%%$'\t'*}" force
  assert_eq "${$(plan_has skip fix/t origin)%%$'\t'*}" skip
}

test_no_to_the_safe_question_deletes_nothing() {
  app_with_origin
  merged_branch fix/m; stale_branch fix/old
  mark fix/m fix/old
  delete_marked n n
  assert_contains "$(<"$HOME/err")" "delete the 2 safe refs? [y/N]"
  assert_contains "$(<"$HOME/err")" "force-delete fix/old (local) and lose 1 commits? [y/N]"
  assert_eq "$(<"$HOME/approved")" "" approved-empty
  assert_contains "$(git -C "$A" branch --list fix/m fix/old)" fix/m
  assert_contains "$(git -C "$A" branch --list fix/old)" fix/old
  assert_contains "$(git -C "$HOME/remote.git" branch --list fix/m)" fix/m
}

test_yes_answers_fill_the_approved_list() {
  app_with_origin
  merged_branch fix/m; stale_branch fix/old; stale_branch fix/old2
  mark fix/m fix/old fix/old2
  delete_marked y n y
  local -a approved; approved=("${(@f)$(<"$HOME/approved")}")
  assert_eq "${#approved}" 2 two-approved
  assert_eq "${approved[1]}" "$(plan_has safe fix/m local+origin)" safe-approved
  assert_eq "${approved[2]}" "$(plan_has force fix/old2 local)" second-force-approved
}

backup_fixture() {
  app_with_origin
  git -C "$A" switch -q -c fix/AB-1; commit; git -C "$A" push -q -u origin fix/AB-1
  git -C "$A" branch -q backup/AB-1-pre-squash
  git -C "$A" switch -q main; git -C "$A" branch -q -D fix/AB-1
  printf 'fix/AB-1\t#3\tmerged\thttps://x/3\t%s\n' "$(git -C "$A" rev-parse origin/fix/AB-1)" > "$HOME/prs"
  mark backup/AB-1-pre-squash
}

test_backup_of_merged_ticket_is_in_the_safe_group() {
  backup_fixture
  delete_marked n
  assert_contains "$(group safe)" "backup/AB-1-pre-squash" safe-group
  assert_contains "$(group safe)" "backup of AB-1 (PR #3 merged)" note
  assert_eq "${$(plan_has safe backup/AB-1-pre-squash local)%%$'\t'*}" safe
}

test_pr_lookup_failure_drops_backup_to_force() {
  backup_fixture
  forge_pr_rows() { return 1; }
  delete_marked n
  assert_contains "$(group force)" "backup/AB-1-pre-squash" force-group
  assert_contains "$(group force)" "PR lookup skipped" note
  assert_eq "$(plan_has safe backup/AB-1-pre-squash local)" MISSING not-safe
}

test_offline_still_rejudges_from_current_refs() {
  app_with_origin
  git -C "$A" switch -q -c fix/u; commit; git -C "$A" switch -q main
  mark fix/u
  local line; local -a f
  line="$(<"$HOME/marked")"; f=("${(@ps:\t:)line}")
  f[10]=merged f[11]=safe f[17]="merged into origin/main"
  print -r -- "${(pj:\t:)f}" > "$HOME/marked"
  forge_pr_rows() { print >> "$HOME/pr-calls"; return 0; }
  _status_parse_opts --offline
  delete_marked n
  assert_contains "$(group force)" "fix/u" force-group
  assert_eq "$(plan_has safe fix/u local)" MISSING not-safe
  assert_not_exists "$HOME/pr-calls"
}

test_remote_with_commits_by_others_is_skipped() {
  app_with_origin
  git -C "$A" switch -q -c fix/mix; teammate_commit; commit; git -C "$A" push -q -u origin fix/mix
  git -C "$A" switch -q main
  mark fix/mix
  delete_marked n
  assert_eq "${$(plan_has force fix/mix local)%%$'\t'*}" force local-only
  assert_eq "$(plan_has force fix/mix local+origin)" MISSING no-remote
  assert_contains "$(plan_has skip fix/mix origin)" "has commits by others"
  assert_contains "$(group skip)" "fix/mix" skip-group
  assert_contains "$(group skip)" "has commits by others" skip-reason
}

test_force_question_counts_only_the_sides_still_deleted() {
  app_with_origin
  git -C "$A" switch -q -c fix/mix; teammate_commit; commit; git -C "$A" push -q -u origin fix/mix
  git -C "$A" reset -q --hard main; commit
  git -C "$A" switch -q main
  mark fix/mix
  assert_contains "$(<"$HOME/marked")" $'\t2\t' "the record counts origin's 2"
  delete_marked n
  assert_contains "$(<"$HOME/err")" "force-delete fix/mix (local) and lose 1 commits?"
  assert_contains "$(group force)" "local only, 1 commits not in origin/main" "plan line agrees"
  assert_contains "$(plan_has force fix/mix local)" $'\tlocal only, 1 commits not in origin/main'
}

# Reviewer's setup: default branch trunk, no origin/HEAD, detached main checkout, so
# status_base_ref finds no base and base..sha cannot be listed.
test_no_base_never_targets_origin() {
  mkdir -p "$A"; git -C "$A" init -q -b trunk; commit init
  git init -q --bare "$HOME/remote.git"
  git -C "$A" remote add origin "$HOME/remote.git"
  git -C "$A" push -q -u origin trunk
  git -C "$A" config user.email t@t
  git -C "$A" switch -q -c fix/x; teammate_commit; commit; git -C "$A" push -q -u origin fix/x
  git -C "$A" switch -q trunk; git -C "$A" checkout -q --detach
  status_base_ref "$A" >/dev/null; assert_eq $? 1 "no base"
  mark fix/x
  assert_contains "$(<"$HOME/marked")" $'\tme\t' "origin side owned by me"
  delete_marked y y
  assert_contains "$(plan_has skip fix/x origin)" "no base branch, so commits by others cannot be ruled out"
  assert_eq "$(plan_has force fix/x origin)" MISSING no-origin-target
  assert_eq "$(plan_has force fix/x local+origin)" MISSING no-both-target
  assert_eq "$(grep -c $'\torigin\t\\|\tlocal+origin\t' "$HOME/approved")" 0 "no origin approved"
}

test_plan_line_shows_both_shas_when_tips_differ() {
  app_with_origin
  git -C "$A" switch -q -c fix/d; commit; git -C "$A" push -q -u origin fix/d; commit
  git -C "$A" switch -q main
  mark fix/d
  delete_marked n
  local l r; l="$(git -C "$A" rev-parse fix/d)" r="$(git -C "$A" rev-parse origin/fix/d)"
  assert_contains "$(group force)" "local+origin  ${l[1,7]}/${r[1,7]}  " both-shas
}

test_leftover_origin_refs_without_a_remote_are_not_trusted() {
  app_with_origin
  merged_branch fix/m
  teammate_remote fix/t
  git -C "$A" branch -q --no-track fix/t origin/fix/t
  local -A keep; local r
  for r in main fix/m fix/t; do keep[$r]="$(git -C "$A" rev-parse "origin/$r")"; done
  git -C "$A" remote remove origin
  for r in main fix/m fix/t; do git -C "$A" update-ref "refs/remotes/origin/$r" "${keep[$r]}"; done
  mark fix/m fix/t
  assert_contains "$(<"$HOME/marked")" $'\tpushed\tsafe\t' "fix/t was pushed"
  wt_fetch_origin() { print -r -- "$1" >> "$HOME/fetches"; return 0; }
  delete_marked n n
  assert_not_exists "$HOME/fetches"
  assert_contains "$(plan_has skip fix/m origin)" "no origin remote"
  assert_eq "${$(plan_has safe fix/m local)%%$'\t'*}" safe "local side still planned"
  assert_contains "$(plan_has force fix/t local)" "no origin remote, so not proven"
}

test_eof_or_empty_answers_approve_nothing() {
  app_with_origin
  merged_branch fix/m; stale_branch fix/old
  mark fix/m fix/old
  delete_marked "" ""
  assert_eq "$(<"$HOME/rc")" 0 empty-answers-rc
  assert_eq "$(<"$HOME/approved")" "" empty-answers-approve-nothing
  delete_marked --eof
  assert_eq "$(<"$HOME/rc")" 130 eof-rc
  assert_not_exists "$HOME/approved"
  assert_contains "$(git -C "$A" branch --list fix/m)" fix/m
  assert_contains "$(git -C "$A" branch --list fix/old)" fix/old
}

test_forged_owner_cannot_add_an_origin_target() {
  app_with_origin
  teammate_remote fix/t
  git -C "$A" branch -q --no-track fix/t origin/fix/t
  mark fix/t
  forge_marked 9=me 10=merged 11=safe
  delete_marked y
  assert_eq "$(plan_has safe fix/t origin)" MISSING no-origin
  assert_eq "$(plan_has safe fix/t local+origin)" MISSING no-both
  local -a approved; approved=("${(@f)$(<"$HOME/approved")}")
  assert_eq "${#approved}" 1 one-approved
  local -a f; f=("${(@ps:\t:)approved[1]}")
  assert_eq "${f[4]}" local local-target
  assert_eq "${f[6]}" - no-remote-sha
}

test_remote_all_mine() {
  app_with_origin
  git -C "$A" switch -q -c fix/own; commit; commit
  local own; own="$(git -C "$A" rev-parse HEAD)"
  git -C "$A" switch -q -c fix/mix main; teammate_commit; commit
  local mix; mix="$(git -C "$A" rev-parse HEAD)"
  git -C "$A" switch -q -c fix/tip main; commit; teammate_commit
  local tip; tip="$(git -C "$A" rev-parse HEAD)"
  git -C "$A" switch -q main
  local main_sha; main_sha="$(git -C "$A" rev-parse main)"
  _branches_remote_all_mine "$A" refs/remotes/origin/main "$own" T@T; assert_eq $? 0 own-any-case
  _branches_remote_all_mine "$A" refs/remotes/origin/main "$mix" t@t; assert_eq $? 1 mixed
  _branches_remote_all_mine "$A" - "$mix" t@t; assert_eq $? 0 tip-only-without-base
  _branches_remote_all_mine "$A" - "$tip" t@t; assert_eq $? 1 teammate-tip
  _branches_remote_all_mine "$A" refs/remotes/origin/main "$main_sha" t@t; assert_eq $? 0 merged-checks-the-tip
  _branches_remote_all_mine "$A" refs/remotes/origin/main "$own" ''; assert_eq $? 1 no-email
}

test_fetch_failure_skips_remote_and_downgrades_pushed() {
  app_with_origin
  merged_branch fix/m
  teammate_remote fix/t
  git -C "$A" branch -q --no-track fix/t origin/fix/t
  mark fix/m fix/t
  assert_contains "$(<"$HOME/marked")" $'\tpushed\tsafe\t' "fix/t was pushed"
  git -C "$A" remote set-url origin "$HOME/nowhere"
  delete_marked n n
  assert_contains "$(<"$HOME/err")" "could not fetch origin"
  assert_contains "$(plan_has skip fix/m origin)" "could not fetch origin"
  assert_eq "${$(plan_has safe fix/m local)%%$'\t'*}" safe "local side still planned"
  assert_eq "${$(plan_has force fix/t local)%%$'\t'*}" force "pushed drops to force"
  assert_contains "$(group force)" "fix/t" force-group
  assert_contains "$(group skip)" "could not fetch origin" skip-reason
}

test_fetch_runs_only_for_repos_with_remote_or_pushed_rows() {
  app_with_origin
  stale_branch fix/old
  mark fix/old
  wt_fetch_origin() { print -r -- "$1" >> "$HOME/fetches"; return 0; }
  delete_marked n
  assert_not_exists "$HOME/fetches"
  merged_branch fix/m
  mark fix/m
  delete_marked n
  assert_eq "$(grep -c . "$HOME/fetches")" 1 "one fetch for the own remote"
}

test_branch_checked_out_after_collection_is_skipped() {
  app_with_origin
  merged_branch fix/m
  mark fix/m
  git -C "$A" worktree add -q "$HOME/wts/app/fix/m" fix/m
  delete_marked n
  assert_eq "$(plan_has safe fix/m local+origin)" MISSING not-safe
  assert_contains "$(plan_has skip fix/m local+origin)" "checked out"
  assert_contains "$(group skip)" "fix/m" skip-group
}

test_vanished_branch_is_skipped() {
  make_repo "$A"
  merged_branch fix/m
  mark fix/m
  git -C "$A" branch -q -D fix/m
  delete_marked n
  assert_contains "$(group skip)" "fix/m" skip-group
  assert_contains "$(group skip)" "no longer exists" skip-reason
  assert_contains "$(plan_has skip fix/m -)" "no longer exists"
}

test_protected_branch_is_skipped() {
  make_repo "$A"
  git -C "$A" branch develop
  mark develop
  delete_marked n
  assert_contains "$(plan_has skip develop local)" protected
}

test_quoted_names_survive_the_records_file() {
  A="$HOME/src/my app"
  make_repo "$A"
  merged_branch 'fix/q"x'; merged_branch 'fix/a$b'\''c'
  mark 'fix/q"x' 'fix/a$b'\''c'
  delete_marked n
  assert_contains "$(group safe)" 'fix/q"x' quote
  assert_contains "$(group safe)" 'fix/a$b'\''c' dollar-quote
  assert_contains "$(plan_has safe 'fix/q"x' local)" "$A"$'\t' spaced-path
  assert_eq "${$(plan_has safe 'fix/a$b'\''c' local)%%$'\t'*}" safe
}

test_status_action_routes_delete_branches() {
  make_repo "$A"
  merged_branch fix/m
  mark fix/m
  printf 'n\n' > "$HOME/answers"
  ( export WORKYTREE_PROMPT_INPUT="$HOME/answers"; WT_CONFIG_EXISTS=1
    cmd___status-action delete-branches "$HOME/marked" --offline ) < /dev/null > "$HOME/out" 2> "$HOME/err"
  assert_eq "$?" 0
  assert_contains "$(<"$HOME/err")" "safe — merged or its ticket is merged"
  assert_contains "$(<"$HOME/err")" "delete the 1 safe refs?"
  assert_eq "$(<"$HOME/out")" "" "plan stays off stdout"
  local err; err="$( (cmd___status-action delete-branches) 2>&1 )"
  assert_contains "$err" "delete-branches <file>"
}

# deleted_log: ~/.local/state/workytree/deleted.log, or empty.
deleted_log() { local l="$XDG_STATE_HOME/workytree/deleted.log"; [[ -r "$l" ]] && print -r -- "$(<"$l")"; }
# result <branch>: the summary lines that name <branch>.
result() { local out="${$(<"$HOME/err")#*summary}"; print -r -- "${(M)${(@f)out}:#*  $1  *}"; }

test_safe_rows_are_deleted_after_one_yes() {
  app_with_origin
  merged_branch fix/m
  local sha; sha="$(git -C "$A" rev-parse fix/m)"
  mark fix/m
  delete_marked y
  assert_eq "$(<"$HOME/rc")" 0 rc
  assert_eq "$(git -C "$A" branch --list fix/m)" "" local-gone
  assert_eq "$(git -C "$HOME/remote.git" branch --list fix/m)" "" remote-gone
  assert_contains "$(<"$HOME/err")" "(was ${sha[1,7]})" was-sha
  assert_contains "$(<"$HOME/err")" "restore it with:" restore-hint
  assert_contains "$(result fix/m)" "✓ local   app  fix/m  deleted (was ${sha[1,7]})" local-row
  assert_contains "$(result fix/m)" "✓ origin  app  fix/m  deleted (was ${sha[1,7]})" origin-row
  assert_eq "$(deleted_log | grep -c .)" 2 two-log-lines
  assert_contains "$(deleted_log)" $'\trefs/heads/fix/m\t'"$sha"$'\t' log-local
  assert_contains "$(deleted_log)" $'\trefs/remotes/origin/fix/m\t'"$sha"$'\t' log-origin
  assert_contains "$(<"$HOME/err")" "deletion log: $XDG_STATE_HOME/workytree/deleted.log" log-pointer
}

test_force_rows_are_asked_one_by_one() {
  app_with_origin
  stale_branch fix/old; stale_branch fix/old2
  mark fix/old fix/old2
  delete_marked y n
  assert_eq "$(git -C "$A" branch --list fix/old)" "" first-deleted
  assert_contains "$(git -C "$A" branch --list fix/old2)" fix/old2 second-kept
  assert_contains "$(result fix/old2)" "– local   app  fix/old2  kept (force declined)" declined-row
  assert_eq "$(deleted_log | grep -c .)" 1 one-log-line
}

test_pushed_row_deletes_local_only() {
  app_with_origin
  teammate_remote fix/t
  git -C "$A" branch -q --no-track fix/t origin/fix/t
  local sha; sha="$(git -C "$A" rev-parse fix/t)"
  mark fix/t
  delete_marked y
  assert_eq "$(git -C "$A" branch --list fix/t)" "" local-gone
  assert_eq "$(git -C "$HOME/remote.git" rev-parse fix/t)" "$sha" remote-kept
  assert_eq "$(result fix/t | grep -c origin)" 0 "no origin row"
}

test_branch_that_moved_after_judging_is_kept() {
  app_with_origin
  merged_branch fix/m
  mark fix/m
  git -C "$A" commit-tree -p fix/m -m moved "fix/m^{tree}" > "$HOME/moved"
  remove_branch() { git -C "$1" update-ref "refs/heads/$2" "$(<"$HOME/moved")"; real_remove_branch "$@"; }
  delete_marked y
  assert_eq "$(git -C "$A" rev-parse fix/m)" "$(<"$HOME/moved")" kept-at-new-tip
  assert_contains "$(result fix/m)" "✗ local   app  fix/m  kept (moved since it was checked)" fail-row
  assert_eq "$(deleted_log | grep -c $'\trefs/heads/')" 0 "not in the log"
}

test_remote_that_moved_fails_the_lease() {
  app_with_origin
  merged_branch fix/m
  mark fix/m
  git clone -q -b fix/m "$HOME/remote.git" "$HOME/other"
  git -C "$HOME/other" commit -q --allow-empty -m moved
  remove_remote_branch() { git -C "$HOME/other" push -q origin fix/m; real_remove_remote_branch "$@"; }
  delete_marked y
  assert_eq "$(git -C "$HOME/remote.git" rev-parse fix/m)" "$(git -C "$HOME/other" rev-parse fix/m)" remote-kept
  assert_eq "$(git -C "$A" branch --list fix/m)" "" local-deleted
  assert_contains "$(result fix/m)" "✗ origin  app  fix/m  not deleted" fail-row
  assert_eq "$(deleted_log | grep -c $'\trefs/remotes/')" 0 "origin not in the log"
}

test_repo_without_origin_deletes_locally_without_fetch() {
  make_repo "$A"
  merged_branch fix/m
  mark fix/m
  wt_fetch_origin() { print -r -- "$1" >> "$HOME/fetches"; return 0; }
  delete_marked y
  assert_not_exists "$HOME/fetches"
  assert_eq "$(git -C "$A" branch --list fix/m)" "" local-deleted
  assert_contains "$(result fix/m)" "✓ local   app  fix/m  deleted" ok-row
}

test_nothing_approved_prints_no_results() {
  app_with_origin
  merged_branch fix/m
  mark fix/m
  delete_marked n
  assert_eq "${$(<"$HOME/err")#*summary}" "$(<"$HOME/err")" no-summary
  assert_contains "$(<"$HOME/err")" "nothing deleted"
  assert_eq "${$(<"$HOME/err")#*deletion log:}" "$(<"$HOME/err")" no-log-pointer
}

run_tests

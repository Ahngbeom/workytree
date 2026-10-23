#!/usr/bin/env zsh
# alt-d in branch mode: the plan re-judged from fresh refs, and its questions. Every test
# answers n, so nothing is deleted here.
source "${0:A:h}/helpers.zsh"
for f in "$WT_TEST_ROOT"/lib/*.zsh "$WT_TEST_ROOT"/lib/cmd/*.zsh; do source "$f"; done
_status_pause() { :; }
functions[_real_wt_fetch_origin]=$functions[wt_fetch_origin]

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

# delete_marked [answer...]: _branches_delete on ~/marked in a subshell (prompt fds and
# exit 130 stay there); BR_PLAN to ~/plan, BR_APPROVED to ~/approved, stderr to ~/err.
delete_marked() {
  printf '%s\n' "$@" > "$HOME/answers"
  ( export WORKYTREE_PROMPT_INPUT="$HOME/answers"
    _branches_delete "$HOME/marked"
    print -rl -- "${BR_PLAN[@]}" > "$HOME/plan"
    print -rl -- "${BR_APPROVED[@]}" > "$HOME/approved" ) < /dev/null 2> "$HOME/err"
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
  assert_contains "$(git -C "$A" branch --list fix/m)" fix/m "8a deletes nothing"
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

run_tests

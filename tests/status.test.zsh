#!/usr/bin/env zsh
# `wt status` end to end, offline. Rows are read from `__status-rows --no-color`, whose first
# 26 TAB-separated fields are the raw record (lib/status.zsh lists them).
source "${0:A:h}/helpers.zsh"

OLD=202401010000                      # touch -t stamp, far past any stale_days
OLD_GIT="2024-01-01T00:00:00"

fixture() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

# with_origin: a bare origin for app, main pushed and tracked.
with_origin() {
  git init -q --bare "$HOME/remote.git"
  git -C "$HOME/src/app" remote add origin "$HOME/remote.git"
  git -C "$HOME/src/app" push -q -u origin main
}

# age_worktree <path>: make the worktree look untouched since $OLD.
age_worktree() {
  local gd; gd="$(git -C "$1" rev-parse --absolute-git-dir)"
  touch -t $OLD "$gd/index" "$gd/HEAD" "$gd/logs/HEAD" 2>/dev/null
}

commit_in() { git -C "$1" commit -q --allow-empty -m "${2:-work}"; }

# field <branch-or-path> <n> [rows]: field n of the first record whose branch (8) or path (5)
# is <branch-or-path>; MISSING when there is none.
field() {
  local key="$1" n="$2" rows="${3:-$ROWS}" line
  local -a f
  for line in "${(@f)rows}"; do
    f=("${(@ps:\t:)line}")
    [[ "${f[8]}" == "$key" || "${f[5]}" == "$key" ]] && { print -r -- "${f[n]}"; return; }
  done
  print -r -- MISSING
}

load_rows() { ROWS="$(wt __status-rows --offline --no-color "$@")"; }

test_merged_clean_worktree_is_safe() {
  fixture
  wt create app fix DONE main >/dev/null 2>&1
  commit_in "$HOME/wts/app/fix/DONE"
  git -C "$HOME/src/app" merge -q --ff-only fix/DONE
  load_rows
  assert_eq "$(field fix/DONE 1)" worktree
  assert_eq "$(field fix/DONE 9)" safe
  assert_eq "$(field fix/DONE 14)" 1 merged
}

test_fresh_worktree_without_commits_counts_as_safe() {
  fixture
  wt create app fix NEW main >/dev/null 2>&1
  load_rows
  assert_eq "$(field fix/NEW 9)" safe
}

test_old_pushed_unmerged_worktree_is_stale() {
  fixture; with_origin
  wt create app fix OLD main >/dev/null 2>&1
  GIT_COMMITTER_DATE="$OLD_GIT" commit_in "$HOME/wts/app/fix/OLD"
  git -C "$HOME/wts/app/fix/OLD" push -q -u origin fix/OLD
  age_worktree "$HOME/wts/app/fix/OLD"
  load_rows
  assert_eq "$(field fix/OLD 9)" stale
  # Looking must not count as activity: `git status` would otherwise rewrite the index.
  load_rows
  assert_eq "$(field fix/OLD 9)" stale second-run
}

test_unpushed_local_commits_are_dirty_even_when_old() {
  fixture
  wt create app fix LOCAL main >/dev/null 2>&1
  GIT_COMMITTER_DATE="$OLD_GIT" commit_in "$HOME/wts/app/fix/LOCAL"
  age_worktree "$HOME/wts/app/fix/LOCAL"
  load_rows
  assert_eq "$(field fix/LOCAL 9)" dirty
}

test_untracked_file_is_dirty_but_idea_only_is_not() {
  fixture
  wt create app fix UNTR main >/dev/null 2>&1
  wt create app fix IDEA main >/dev/null 2>&1
  print x > "$HOME/wts/app/fix/UNTR/new.txt"
  mkdir -p "$HOME/wts/app/fix/IDEA/.idea"; print x > "$HOME/wts/app/fix/IDEA/.idea/ws.xml"
  load_rows
  assert_eq "$(field fix/UNTR 9)" dirty
  assert_eq "$(field fix/UNTR 16)" real
  assert_eq "$(field fix/IDEA 9)" safe
  assert_eq "$(field fix/IDEA 16)" idea-only
}

test_gone_upstream_is_safe() {
  fixture; with_origin
  wt create app fix GONE main >/dev/null 2>&1
  commit_in "$HOME/wts/app/fix/GONE"
  git -C "$HOME/wts/app/fix/GONE" push -q -u origin fix/GONE
  git -C "$HOME/src/app" push -q origin --delete fix/GONE
  git -C "$HOME/src/app" fetch -q --prune origin
  load_rows
  assert_eq "$(field fix/GONE 15)" 1 gone
  assert_eq "$(field fix/GONE 9)" safe
}

test_ahead_of_upstream_is_dirty() {
  fixture; with_origin
  wt create app fix AHEAD main >/dev/null 2>&1
  git -C "$HOME/wts/app/fix/AHEAD" push -q -u origin fix/AHEAD
  commit_in "$HOME/wts/app/fix/AHEAD"
  load_rows
  assert_eq "$(field fix/AHEAD 17)" 1 ahead
  assert_eq "$(field fix/AHEAD 9)" dirty
}

test_locked_worktree_is_never_safe() {
  fixture
  wt create app fix LOCK main >/dev/null 2>&1
  git -C "$HOME/src/app" worktree lock "$HOME/wts/app/fix/LOCK"
  load_rows
  assert_eq "$(field fix/LOCK 21)" 1 locked
  assert_eq "$(field fix/LOCK 9)" -
}

test_branch_without_worktree_is_listed_but_base_is_not() {
  fixture
  git -C "$HOME/src/app" branch lonely
  load_rows
  assert_eq "$(field lonely 1)" branch
  local line n=0
  for line in "${(@f)ROWS}"; do [[ "$line" == *$'\tmain\t'* ]] && (( ++n )); done
  assert_eq "$n" 1 "main appears once (as the main checkout)"
  assert_eq "$(field main 1)" main
  assert_eq "$(field main 9)" -
}

test_orphan_dir_is_listed_and_left_alone() {
  fixture
  wt create app fix LIVE main >/dev/null 2>&1
  mkdir -p "$HOME/wts/app/fix/ORPH"; print x > "$HOME/wts/app/fix/ORPH/keep.txt"
  load_rows
  assert_eq "$(field "$HOME/wts/app/fix/ORPH" 1)" orphan
  assert_eq "$(field "$HOME/wts/app/fix/ORPH" 7)" ORPH
  assert_dir "$HOME/wts/app/fix/ORPH"
}

test_detached_worktree_is_shown() {
  fixture
  wt create app fix DET main >/dev/null 2>&1
  git -C "$HOME/wts/app/fix/DET" checkout -q --detach
  load_rows
  assert_eq "$(field "$HOME/wts/app/fix/DET" 8)" -
  assert_contains "$(wt status --offline --plain)" "(detached) DET"
}

test_scope_filters() {
  fixture
  make_repo "$HOME/other/tool"
  wt project add them "$HOME/other" "$HOME/wts2" >/dev/null
  wt create app fix A main >/dev/null 2>&1
  load_rows
  assert_eq "$(field "$HOME/other/tool" 1)" main both-projects
  load_rows --project me
  assert_eq "$(field "$HOME/other/tool" 1)" MISSING project-filter
  load_rows tool
  assert_eq "$(field fix/A 1)" MISSING repo-filter
  assert_eq "$(field "$HOME/other/tool" 1)" main repo-filter
}

test_stale_filter_and_override() {
  fixture
  wt create app fix NEW main >/dev/null 2>&1
  git -C "$HOME/src/app" branch keep-me
  wt create app fix ACTIVE main >/dev/null 2>&1
  commit_in "$HOME/wts/app/fix/ACTIVE"
  git -C "$HOME/wts/app/fix/ACTIVE" config branch.fix/ACTIVE.remote .
  git -C "$HOME/wts/app/fix/ACTIVE" config branch.fix/ACTIVE.merge refs/heads/fix/ACTIVE
  load_rows --stale
  assert_eq "$(field main 1)" MISSING main-hidden
  assert_eq "$(field fix/NEW 9)" safe safe-kept
  assert_eq "$(field fix/ACTIVE 1)" MISSING active-hidden
  sleep 1
  load_rows --stale 0
  assert_eq "$(field fix/ACTIVE 9)" stale zero-days
}

test_fetch_and_offline_conflict() {
  fixture
  assert_exit 2 wt status --fetch --offline
}

test_unreadable_repo_becomes_one_error_row() {
  fixture
  make_repo "$HOME/src/broken"
  print -r -- garbage > "$HOME/src/broken/.git/HEAD"
  wt create app fix A main >/dev/null 2>&1
  load_rows
  assert_eq "$(field "$HOME/src/broken" 1)" MISSING no-worktree-row
  local line errs=0
  for line in "${(@f)ROWS}"; do [[ "$line" == error$'\t'*$'\tbroken\t'* ]] && (( ++errs )); done
  assert_eq "$errs" 1 one-error-row
  assert_eq "$(field fix/A 1)" worktree others-still-listed
  wt status --offline --plain >/dev/null 2>&1
  assert_eq "$?" 0
}

test_plain_table_when_stdout_is_not_a_terminal() {
  fixture
  wt create app fix A main >/dev/null 2>&1
  local out; out="$(wt status --offline 2>/dev/null)"
  assert_contains "$out" "REPO"
  assert_contains "$out" "fix/A"
}

test_json_is_valid_and_escapes_branch_names() {
  fixture
  git -C "$HOME/src/app" branch 'fix/q"x'
  local out; out="$(wt status --offline --json)"
  assert_contains "$out" '"branch":"fix/q\"x"'
  if (( $+commands[python3] )); then
    print -r -- "$out" | python3 -c 'import json,sys; json.load(sys.stdin)'
    assert_eq "$?" 0 valid-json
  fi
}

test_stale_days_config_is_used() {
  fixture; with_origin
  wt config set stale_days 100000 >/dev/null
  wt create app fix OLD main >/dev/null 2>&1
  GIT_COMMITTER_DATE="$OLD_GIT" commit_in "$HOME/wts/app/fix/OLD"
  git -C "$HOME/wts/app/fix/OLD" push -q -u origin fix/OLD
  age_worktree "$HOME/wts/app/fix/OLD"
  load_rows
  assert_eq "$(field fix/OLD 9)" - not-stale-under-huge-threshold
}

run_tests

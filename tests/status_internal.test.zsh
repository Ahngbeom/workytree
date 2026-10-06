#!/usr/bin/env zsh
# lib/status.zsh and lib/cmd/status.zsh internals, sourced directly.
source "${0:A:h}/helpers.zsh"
for f in ui config resolve worktree forge status; do source "$WT_TEST_ROOT/lib/$f.zsh"; done
source "$WT_TEST_ROOT/lib/cmd/prune.zsh"
source "$WT_TEST_ROOT/lib/cmd/status.zsh"

test_fmt_age_boundaries() {
  status_fmt_age 0; assert_eq "$REPLY" "<1h"
  status_fmt_age 3599; assert_eq "$REPLY" "<1h"
  status_fmt_age 3600; assert_eq "$REPLY" "1h"
  status_fmt_age 86399; assert_eq "$REPLY" "23h"
  status_fmt_age 86400; assert_eq "$REPLY" "1d"
  status_fmt_age $(( 14 * 86400 - 1 )); assert_eq "$REPLY" "13d"
  status_fmt_age $(( 14 * 86400 )); assert_eq "$REPLY" "2w"
  status_fmt_age $(( 56 * 86400 )); assert_eq "$REPLY" "1mo"
  status_fmt_age $(( 729 * 86400 )); assert_eq "$REPLY" "24mo"
  status_fmt_age $(( 730 * 86400 )); assert_eq "$REPLY" "2y"
  status_fmt_age -; assert_eq "$REPLY" "-"
}

# status_flag <merged> <gone> <pr_state> <dirty> <ahead> <has_upstream> <base_ahead> <locked> <age_s> <stale_s>
test_flag_table() {
  status_flag 1 0 - clean 0 1 0 0 10 100; assert_eq "$REPLY" safe      merged-clean
  status_flag 1 0 - idea-only 0 1 0 0 10 100; assert_eq "$REPLY" safe  idea-only-is-not-work
  status_flag 0 1 - clean - 1 3 0 10 100; assert_eq "$REPLY" safe      gone
  status_flag 0 0 merged clean 0 1 3 0 10 100; assert_eq "$REPLY" safe squash-merged-pr
  status_flag 0 0 closed clean 0 1 3 0 10 100; assert_eq "$REPLY" safe closed-pr
  status_flag 1 0 - real 0 1 0 0 10 100; assert_eq "$REPLY" dirty      uncommitted
  status_flag 1 0 - unknown 0 1 0 0 10 100; assert_eq "$REPLY" dirty   unknown-is-never-safe
  status_flag 1 0 - clean 2 1 0 0 10 100; assert_eq "$REPLY" dirty     unpushed
  status_flag 0 0 - clean - 0 2 0 10 100; assert_eq "$REPLY" dirty     local-only-commits
  status_flag 0 0 merged clean - 0 2 0 10 100; assert_eq "$REPLY" safe local-only-but-pr-merged
  status_flag 1 0 - clean 0 1 0 1 10 100; assert_eq "$REPLY" -         locked-not-safe
  status_flag 1 0 - clean 0 1 0 1 500 100; assert_eq "$REPLY" stale    locked-but-old
  status_flag 0 0 - clean 0 1 2 0 500 100; assert_eq "$REPLY" stale    old
  status_flag 0 0 - real 0 1 2 0 500 100; assert_eq "$REPLY" dirty     dirty-beats-stale
  status_flag 0 0 open clean 0 1 2 0 10 100; assert_eq "$REPLY" -      active
  status_flag 0 0 - clean 0 1 2 0 - 100; assert_eq "$REPLY" -          unknown-age
}

test_track_parsing() {
  _status_track "ahead 3, behind 12"; assert_eq "${reply[*]}" "3 12"
  _status_track "behind 2";           assert_eq "${reply[*]}" "0 2"
  _status_track "";                   assert_eq "${reply[*]}" "0 0"
}

test_base_ref_prefers_origin_head_then_origin_main_then_local() {
  make_repo "$HOME/app"
  assert_eq "$(status_base_ref "$HOME/app")" refs/heads/main local
  git init -q --bare "$HOME/remote.git"
  git -C "$HOME/app" remote add origin "$HOME/remote.git"
  git -C "$HOME/app" push -q origin main main:trunk
  git -C "$HOME/app" fetch -q origin
  assert_eq "$(status_base_ref "$HOME/app")" refs/remotes/origin/main origin-main
  git -C "$HOME/app" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  assert_eq "$(status_base_ref "$HOME/app")" refs/remotes/origin/trunk origin-head
}

# git < 2.41 rejects %(ahead-behind:...); base counts must still come out, one rev-list each.
test_base_counts_without_ahead_behind_support() {
  make_repo "$HOME/src/app"
  typeset -ga WT_PROJECTS=(me)
  typeset -gA WT_PCFG=(me.repo_root "$HOME/src" me.worktree_root "$HOME/wts") WT_CFG=() WT_RCFG=()
  git -C "$HOME/src/app" checkout -q -b topic
  git -C "$HOME/src/app" commit -q --allow-empty -m one
  git -C "$HOME/src/app" commit -q --allow-empty -m two
  git -C "$HOME/src/app" checkout -q main
  git() { [[ "$*" == *ahead-behind* ]] && { print -u2 "fatal: unknown field name: ahead-behind"; return 128; }; command git "$@"; }
  local line; line="$(status_collect_repo me app "$HOME/src/app" 30 | grep $'^branch\t')"
  unfunction git
  local -a f; f=("${(@ps:\t:)line}")
  assert_eq "${f[8]}" topic
  assert_eq "${f[19]} ${f[20]}" "2 0" base-ahead-behind
  assert_eq "${f[9]}" dirty local-only-commits
}

test_json_string_escaping() {
  _status_jstr 'a"b\c';     assert_eq "$REPLY" '"a\"b\\c"'
  _status_jstr $'x\ty\nz';  assert_eq "$REPLY" '"x\u0009y\u000az"'
  _status_jstr -;           assert_eq "$REPLY" null
}

# in_subshell <cmd...>: usage_error exits; keep that exit out of the test process.
in_subshell() { ( "$@" ) }

test_parse_opts() {
  _status_parse_opts app --stale 7 --json
  assert_eq "$ST_REPO $ST_STALE_FILTER $ST_STALE_DAYS $ST_JSON" "app 1 7 1"
  _status_parse_opts --stale
  assert_eq "$ST_STALE_FILTER $ST_STALE_DAYS" "1 -1"
  assert_exit 2 in_subshell _status_parse_opts --fetch --offline
  assert_exit 2 in_subshell _status_parse_opts a b
  assert_exit 2 in_subshell _status_parse_opts --bogus
}

test_stale_days_from_config_and_override() {
  typeset -gA WT_CFG=(stale_days 10) WT_PCFG=(me.stale_days 5)
  ST_STALE_DAYS=-1
  assert_eq "$(status_stale_days me)" 5
  assert_eq "$(status_stale_days other)" 10
  WT_CFG[stale_days]=soon
  assert_eq "$(status_stale_days other 2>/dev/null)" 30
  ST_STALE_DAYS=0
  assert_eq "$(status_stale_days me)" 0
  ST_STALE_DAYS=-1
}

# More repos than WT_STATUS_MAX_JOBS run in batches; output stays in config order.
test_collect_keeps_config_order_across_batches() {
  local n
  for n in a b c d e; do make_repo "$HOME/src/$n"; done
  typeset -ga WT_PROJECTS=(me)
  typeset -gA WT_PCFG=(me.repo_root "$HOME/src" me.worktree_root "$HOME/wts") WT_CFG=() WT_RCFG=()
  WT_STATUS_MAX_JOBS=2 ST_OFFLINE=1 ST_FETCH=0 ST_REPO='' ST_PROGRESS=0 ST_STALE_DAYS=-1
  local out; out="$(_status_collect "$HOME/notes" | cut -f3 | tr '\n' ' ')"
  assert_eq "$out" "a b c d e "
  WT_STATUS_MAX_JOBS=8 ST_OFFLINE=0
}

test_sort_groups_types_then_oldest_first_with_main_checkouts_last() {
  local t=$'\t' d='-'
  local rows="branch${t}p${t}r${t}rp${t}-${t}-${t}-${t}b1${t}-${t}-${t}-${t}-${t}200
worktree${t}p${t}r${t}rp${t}/w2${t}-${t}-${t}w2${t}-${t}-${t}50${t}-${t}-
orphan${t}p${t}r${t}rp${t}/o${t}-${t}-${t}-${t}-${t}-${t}10${t}-${t}-
worktree${t}p${t}r${t}rp${t}/w1${t}-${t}-${t}w1${t}-${t}-${t}40${t}-${t}-
branch${t}p${t}r${t}rp${t}-${t}-${t}-${t}b2${t}-${t}-${t}-${t}-${t}100
main${t}p${t}r${t}rp${t}/m${t}-${t}-${t}m${t}-${t}-${t}1${t}-${t}-"
  assert_eq "$(_status_sort <<< "$rows" | cut -f1,8 | tr '\t\n' ': ')" "worktree:w1 worktree:w2 branch:b2 branch:b1 orphan:- main:m "
}

run_tests

#!/usr/bin/env zsh
# `wt status --branches` end to end, offline: table, JSON and the __status-rows feed.
source "${0:A:h}/helpers.zsh"

fixture() {
  make_repo "$HOME/src/app"
  write_config <<EOF2
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF2
}

with_origin() {
  git init -q --bare "$HOME/remote.git"
  git -C "$HOME/src/app" remote add origin "$HOME/remote.git"
  git -C "$HOME/src/app" push -q -u origin main
  git -C "$HOME/src/app" config user.email t@t
}

# merged_and_fresh: fix/m merged into main; fix/new has an unmerged commit.
merged_and_fresh() {
  local a="$HOME/src/app"
  with_origin
  git -C "$a" switch -q -c fix/m; git -C "$a" commit -q --allow-empty -m m
  git -C "$a" switch -q main; git -C "$a" merge -q --no-ff fix/m -m merge
  git -C "$a" push -q origin main
  git -C "$a" switch -q -c fix/new; git -C "$a" commit -q --allow-empty -m n
  git -C "$a" switch -q main
}

test_branches_rows_have_record_plus_display() {
  fixture; merged_and_fresh
  local out line; local -a f
  out="$(wt __status-rows --branches --offline --no-color)"
  [[ -n "$out" ]] || { (( ++_fail )); print -u2 "  FAIL no rows"; return; }
  for line in "${(@f)out}"; do
    f=("${(@ps:\t:)line}")
    assert_eq "${#f}" 18 fields
    assert_contains "${f[18]}" "${f[10]}" why-in-display
    [[ "${f[18]}" == *(safe|force|keep) ]] && (( ++_pass )) || { (( ++_fail )); print -u2 "  FAIL no class word: ${f[18]}"; }
  done
}

test_branches_plain_table_has_why_column() {
  fixture; merged_and_fresh
  local out; out="$(wt status --branches --plain --offline)"
  assert_contains "$(print -r -- "$out" | head -1)" WHY header
  assert_contains "$(print -r -- "$out" | grep 'fix/m')" merged merged-row
}

test_branches_json_escapes_names() {
  fixture; with_origin
  local a="$HOME/src/app" out
  git -C "$a" branch 'fix/q"x'; git -C "$a" branch "fix/a\$b'c"
  out="$(wt status --branches --json --offline)"
  print -r -- "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
  assert_eq $? 0 json-valid
  print -r -- "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
b={r["branch"]:r for r in d["rows"]}
assert "fix/q\"x" in b and "fix/a$b'"'"'c" in b
assert b["fix/q\"x"]["local"]["sha"]
assert "notes" in d' 2>/dev/null
  assert_eq $? 0 json-rows
}

test_branches_stale_filter_keeps_cleanup_candidates() {
  fixture; merged_and_fresh
  local out; out="$(wt status --branches --stale --plain --offline)"
  assert_contains "$out" fix/m
  [[ "$out" != *fix/new* ]] && (( ++_pass )) || { (( ++_fail )); print -u2 "  FAIL fix/new listed"; }
}

test_branches_option_is_completed() {
  local out
  out="$(zsh -c '
    workytree() { :; }
    _values() { print VALUES "$@"; }
    _arguments() { state=args; return 1; }
    source "'"$WT_TEST_ROOT"'/shell/completions/_workytree" >/dev/null 2>&1
    words=(status); CURRENT=3
    _workytree
  ' 2>&1)"
  assert_contains "$out" "--branches"
}

test_worktree_view_is_unchanged_without_branches() {
  fixture
  wt create app fix W1 main >/dev/null 2>&1
  local line; local -a f
  line="$(wt __status-rows --offline --no-color | head -1)"
  f=("${(@ps:\t:)line}")
  assert_eq "${#f}" 27
}

run_tests

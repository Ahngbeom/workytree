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

# --- Fix round 1 ---------------------------------------------------------------------

# C-1 layer 1 (R27): require_config must reject a [project] missing worktree_root, for
# EVERY command that calls it (prune included) -- not just prune's own downstream checks.
# Exit 3 is the "config problem" code, matching require_config's other checks.
test_require_config_rejects_project_missing_worktree_root() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
EOF
  local out; out="$(wt prune 2>&1)"
  local rc=$?
  assert_eq "$rc" "3"
  assert_contains "$out" "project 'me' is missing worktree_root"
}

test_require_config_rejects_project_missing_repo_root() {
  write_config <<EOF
[project me]
worktree_root = ~/wts
EOF
  local out; out="$(wt prune 2>&1)"
  local rc=$?
  assert_eq "$rc" "3"
  assert_contains "$out" "project 'me' is missing repo_root"
}

test_require_config_rejects_project_with_empty_worktree_root_value() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root =
EOF
  local out; out="$(wt prune 2>&1)"
  local rc=$?
  assert_eq "$rc" "3"
  assert_contains "$out" "project 'me' is missing worktree_root"
}

# C-1 layer 2: even a config that passes layer 1's mere non-emptiness check can still
# resolve to a dangerous root. "//" is non-empty text (passes require_config), but
# expand_path collapses it to "/" -- prune_repo's own anchor guard must independently
# refuse, unconditionally (before any filesystem walk of the real root -- the guard fires
# before prune_repo even checks whether anything exists at the computed path).
test_prune_anchor_refuses_worktree_root_that_resolves_to_filesystem_root() {
  make_repo "$HOME/src/widget"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = //
EOF
  local out; out="$(wt prune widget 2>&1)"
  local rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "refusing to prune widget: project 'me' has no safe worktree_root"
}

test_prune_refuses_when_worktree_root_equals_repo_path() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/src
EOF
  local out; out="$(wt prune app 2>&1)"
  local rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "refusing to prune app: worktree directory equals the repo path itself"
}

# I-1: `git worktree list --porcelain` failing must refuse the whole sweep for that repo
# rather than silently proceed as if nothing were registered -- corrupting the repo's own
# HEAD makes every git command against it fail exactly like a real corrupted repo would.
test_prune_refuses_when_git_worktree_list_fails() {
  fixture
  wt create app fix LIVE main >/dev/null
  mv "$HOME/src/app/.git/HEAD" "$HOME/src/app/.git/HEAD.bak"
  print "garbage, not a ref" > "$HOME/src/app/.git/HEAD"
  local out; out="$(wt prune app 2>&1)"
  local rc=$?
  mv "$HOME/src/app/.git/HEAD.bak" "$HOME/src/app/.git/HEAD"
  assert_eq "$rc" "1"
  assert_contains "$out" "could not list worktrees for app"
  assert_contains "$out" "refusing to touch its directories"
  assert_dir "$HOME/wts/app/fix/LIVE"
}

# C-2 repro (i): a ticket directory literally NAMED ".idea" holding real work. The old
# absolute-path match (`*/.idea/*`) saw ".idea" in the candidate's OWN name and treated
# everything inside it as idea-cruft; matching must be relative to the candidate root.
test_prune_keeps_ticket_dir_literally_named_idea() {
  fixture
  wt create app fix LIVE main >/dev/null
  mkdir -p "$HOME/wts/app/fix/.idea"
  print "realwork" > "$HOME/wts/app/fix/.idea/realwork.txt"
  local out; out="$(wt prune app 2>&1)"
  assert_eq "$?" 0
  assert_dir "$HOME/wts/app/fix/.idea"
  assert_eq "$(cat "$HOME/wts/app/fix/.idea/realwork.txt")" "realwork"
  assert_contains "$out" "skipped orphan"
}

# C-2 repro (ii): worktree_root itself sits under a path containing ".idea" as an ancestor
# component. Same root bug, different position -- the ".idea" component doesn't even have
# to be near the candidate to fool an absolute-path match.
test_prune_keeps_orphan_when_worktree_root_is_under_idea() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/.idea/wts
EOF
  mkdir -p "$HOME/.idea/wts/app/fix/ORPHAN"
  print "thesis content" > "$HOME/.idea/wts/app/fix/ORPHAN/thesis.txt"
  local out; out="$(wt prune app 2>&1)"
  assert_eq "$?" 0
  assert_dir "$HOME/.idea/wts/app/fix/ORPHAN"
  assert_eq "$(cat "$HOME/.idea/wts/app/fix/ORPHAN/thesis.txt")" "thesis content"
  assert_contains "$out" "skipped orphan"
}

# R29: a repo registered under an unsafe name (".."), reachable via a hand-edited config
# today and via `repo add --name` once Task 8 lands, must never be swept at all -- proven
# here by making the escape-target directory ("$HOME/wts/sibling/inner") cruft-only, so if
# R29 were absent the escaping sweep (worktree_parent's "$worktree_root/.." canonicalizing
# to worktree_root's PARENT) would delete it exactly like the reviewer's reproduction did.
test_prune_ignores_unsafe_registered_repo_name_and_protects_escape_target() {
  make_repo "$HOME/src/normal"
  mkdir -p "$HOME/wts/deep"
  mkdir -p "$HOME/wts/sibling/inner/.idea"
  print x > "$HOME/wts/sibling/inner/.idea/a.xml"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts/deep
[repo ..]
path = ~/wts/deep
project = me
EOF
  local out; out="$(wt prune 2>&1)"
  assert_contains "$out" "ignoring unsafe repo name in config: .."
  local ran_dotdot_sweep=0
  [[ "$out" == *"pruning worktrees for .."* ]] && ran_dotdot_sweep=1
  assert_eq "$ran_dotdot_sweep" "0" "an unsafe repo name must never be swept"
  assert_dir "$HOME/wts/sibling/inner"
  assert_eq "$(cat "$HOME/wts/sibling/inner/.idea/a.xml")" "x"
}

test_prune_named_arg_rejects_unsafe_repo_name() {
  make_repo "$HOME/src/normal"
  mkdir -p "$HOME/wts/deep"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts/deep
[repo ..]
path = ~/wts/deep
project = me
EOF
  local out; out="$(wt prune .. 2>&1)"
  local rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "unsafe repo name: .."
}

# I-2: bare `workytree prune` (all repos) must exit nonzero if ANY repo's sweep was
# refused, so a script can tell a refused sweep apart from a genuinely clean one. The
# other (healthy) repo must still get pruned in the same run.
test_prune_multi_repo_exits_1_when_any_repo_refused() {
  make_repo "$HOME/src/ok/okrepo"
  make_repo "$HOME/bad/badrepo"
  write_config <<EOF
[project p1]
repo_root = ~/src/ok
worktree_root = ~/wts/ok
[project p2]
repo_root = ~/bad
worktree_root = ~/bad
EOF
  local out; out="$(wt prune 2>&1)"
  local rc=$?
  assert_eq "$rc" "1"
  assert_contains "$out" "pruning worktrees for okrepo"
  assert_contains "$out" "pruning worktrees for badrepo"
  assert_contains "$out" "refusing to prune badrepo: worktree directory equals the repo path itself"
}

# M-2: a directory NAME containing an embedded newline must be treated as one atomic
# candidate. A newline-delimited read would split it into fragments that don't correspond
# to any real path, leaving the real orphan un-inspected and undeleted.
test_prune_handles_orphan_name_with_embedded_newline() {
  fixture
  wt create app fix LIVE main >/dev/null
  local weird=$'CRUFT\nNAME'
  mkdir -p "$HOME/wts/app/fix/$weird/.idea"
  print x > "$HOME/wts/app/fix/$weird/.idea/a.xml"
  wt prune app >/dev/null
  assert_not_exists "$HOME/wts/app/fix/$weird"
}

# M-3: a failed `rm -rf` on a cruft-only orphan must be reported, not left silent. chmod'ing
# the PARENT read+execute-only (no write) lets `find` still read into the child (needed for
# dir_is_cruft_only's own verdict) but blocks unlinking the child itself from its parent.
test_prune_reports_rm_failure_for_cruft_orphan() {
  fixture
  wt create app fix LIVE main >/dev/null
  mkdir -p "$HOME/wts/app/fix/STUCK/.idea"
  chmod 500 "$HOME/wts/app/fix"
  local out; out="$(wt prune app 2>&1)"
  chmod 755 "$HOME/wts/app/fix"
  assert_contains "$out" "failed to remove orphan (left in place)"
  assert_dir "$HOME/wts/app/fix/STUCK"
}

# M-4: an earlier version only set `found` in the depth-2 loop, so a repo whose only orphan
# was an empty <kind> dir (nothing at depth 2 to iterate at all) still printed "no orphan
# dirs found" on the same line as "removed orphan kind dir: ..." -- self-contradictory.
test_prune_kind_dir_removal_suppresses_no_orphan_found_message() {
  fixture
  mkdir -p "$HOME/wts/app/emptykind"
  local out; out="$(wt prune app 2>&1)"
  assert_contains "$out" "removed orphan kind dir: $HOME/wts/app/emptykind"
  local saw_none=0
  [[ "$out" == *"no orphan dirs found"* ]] && saw_none=1
  assert_eq "$saw_none" "0" "'no orphan dirs found' must not appear when the kind-dir sweep removed something"
}

run_tests

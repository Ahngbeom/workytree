#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

test_project_add_without_config_sets_default() {
  assert_exit 0 wt project add me ~/src ~/wts
  assert_eq "$(wt config get default_project)" "me"
  assert_eq "$(wt config get project.me.worktree_root)" "$HOME/wts"
  assert_contains "$(wt project list)" "* me"
}

test_project_add_validates() {
  wt project add me ~/src ~/wts >/dev/null
  assert_exit 1 wt project add me ~/x ~/y            # duplicate, both keys already present
  assert_exit 2 wt project add "bad name" ~/x ~/y    # invalid name syntax
  assert_exit 2 wt project add only-two ~/x          # wrong arg count
}

test_project_default_and_remove() {
  wt project add a ~/a ~/aw >/dev/null; wt project add b ~/b ~/bw >/dev/null
  wt project default b >/dev/null
  assert_eq "$(wt config get default_project)" "b"
  assert_exit 1 wt project default ghost
  wt project remove b >/dev/null
  assert_exit 1 wt config get project.b.repo_root
  assert_eq "$(wt config get default_project)" "a" "default falls back to remaining project"
}

test_repo_add_list_remove() {
  make_repo "$HOME/elsewhere/api"; make_repo "$HOME/src/inside"
  wt project add me ~/src ~/wts >/dev/null
  wt repo add ~/elsewhere/api >/dev/null
  assert_eq "$(wt config get repo.api.project)" "me"
  wt repo add ~/elsewhere/api --name api2 --project me >/dev/null
  assert_contains "$(wt repo list)" "api2"
  assert_exit 1 wt repo add ~/elsewhere/api            # duplicate name
  assert_exit 1 wt repo add ~/nonexistent
  assert_exit 1 wt repo add ~/elsewhere/api --name z --project ghost
  wt repo remove api2 >/dev/null
  assert_exit 1 wt config get repo.api2.path
  assert_eq "$(wt path api)" "$HOME/elsewhere/api"
}

# R30: `project add` must refuse to WRITE an unsafe worktree_root -- "/" outright, and any
# STRICT ancestor of $HOME -- rather than writing it and letting a later `prune` discover the
# problem via require_config. worktree_root == $HOME itself must stay legal (the non-strict
# boundary case). The message is workytree's own wording, not text any other tool could also
# emit -- required so this test can only pass because OUR guard ran, per R23.
test_project_add_rejects_unsafe_worktree_root() {
  local out
  # "/" is non-empty TEXT but expand_path's trailing-slash strip collapses it to "" -- this
  # must be the "unusable" (empty) message, not "unsafe" (mirrors require_config's own N-2
  # split in tests/prune.test.zsh: a present-but-collapses-to-nothing value is a different
  # problem than a present-and-resolvable-but-dangerous one).
  out="$(wt project add r0 ~/src / 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "resolves to an empty/unusable path"
  assert_exit 1 wt config get project.r0.repo_root

  # "//" resolves (via expand_path) to the non-empty "/" -- this is the "unsafe" case.
  out="$(wt project add r1 ~/src // 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "unsafe worktree_root"
  assert_exit 1 wt config get project.r1.repo_root   # nothing was written

  # "$HOME/.." is syntactically ABSOLUTE (passes R32) but canonicalizes to a STRICT ancestor
  # of $HOME -- the exact scenario R30/N-5 pins, using an absolute value so this exercises
  # R30's own check rather than R32's (a bare ".." is now caught earlier by R32 -- see
  # test_project_add_rejects_relative_root below).
  out="$(wt project add r2 ~/src '$HOME/..' 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "unsafe worktree_root"
  assert_contains "$out" "strict ancestor of the home directory"
  assert_exit 1 wt config get project.r2.repo_root

  # worktree_root == $HOME is legal (not a STRICT ancestor).
  assert_exit 0 wt project add r3 ~/src ~
  assert_eq "$(wt config get project.r3.worktree_root)" "$HOME"
}

# R32: a repo_root/worktree_root that resolves to something other than an ABSOLUTE path means
# three different directories to three different downstream consumers of the same stored
# string -- mkdir -p resolves it against the invoking shell's cwd, `git worktree add` resolves
# it against the repo directory, and require_config's own ":A" resolves it against whatever
# cwd happens to be running when a later command reaches it. Reproduces the coordinator's
# exact finding: `wt project add me src wts` (bare relative, no leading "~"/"$VAR"/"/") must
# now be refused outright, at BOTH layers -- add-time (exit 1) and the shared invariant that
# also protects a hand-edited config (exit 3, via `wt repos`/require_config).
test_project_add_rejects_relative_root() {
  local out
  out="$(wt project add me src wts 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "repo_root is not an absolute path after expansion"
  assert_exit 1 wt config get project.me.repo_root   # nothing was written

  out="$(wt project add me2 ~/src ./wts 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "worktree_root is not an absolute path after expansion"
  assert_exit 1 wt config get project.me2.repo_root

  # Absolute values keep working, and -- this half matters as much as the rejection -- the
  # config file preserves the user's ORIGINAL spelling (does not get rewritten to a
  # machine-specific canonical path). Single-quoted here so THIS test's own shell doesn't
  # prematurely expand "~"/"$HOME" before workytree ever sees the argument -- exactly as a
  # hand-edited config file's text is never shell-evaluated at all.
  assert_exit 0 wt project add ok1 '~/src' '~/wts'
  assert_exit 0 wt project add ok2 '$HOME/src2' '$HOME/wts2'
  assert_exit 0 wt project add ok3 /abs/src /abs/wts
  local cfg; cfg="$(wt config path)"
  local raw; raw="$(cat "$cfg")"
  assert_contains "$raw" "repo_root = ~/src"
  assert_contains "$raw" "worktree_root = ~/wts"
  assert_contains "$raw" 'repo_root = $HOME/src2'
  assert_contains "$raw" 'worktree_root = $HOME/wts2'
  assert_contains "$raw" "repo_root = /abs/src"
  assert_contains "$raw" "worktree_root = /abs/wts"

  # The shared invariant (require_config) refuses the exact same relative value in a
  # hand-written config, independently of `project add` -- exit 3, not exit 1, per R31.
  write_config <<EOF
[project rel]
repo_root = ~/src
worktree_root = wts
EOF
  out="$(wt repos 2>&1)"
  assert_eq "$?" 3
  assert_contains "$out" "worktree_root that is not an absolute path after expansion"
}

# R32: an unset $VAR reference must produce ITS OWN clear diagnostic, not a confusing
# "unusable"/"not absolute" one about a string the user never meant. "$NOPE/wts" with $NOPE
# unset would otherwise expand to "/wts" -- an accidentally ABSOLUTE-looking path that would
# silently pass a plain "is it absolute" check.
test_project_add_rejects_unset_variable_reference() {
  unset NOPE 2>/dev/null
  local out; out="$(wt project add me ~/src '$NOPE/wts' 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "worktree_root references an unset variable \$NOPE"
  assert_exit 1 wt config get project.me.repo_root

  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = \$NOPE/wts
EOF
  out="$(wt repos 2>&1)"
  assert_eq "$?" 3
  assert_contains "$out" "worktree_root that references an unset variable \$NOPE"
}

# repo_root/worktree_root overlap is not refused (a deliberate nested layout is plausible) but
# must never be silent -- scan_project_repos's "-mindepth 2" scan finds nothing at all when
# they're equal, with no clue why, unless `project add` says so up front.
test_project_add_warns_on_root_overlap() {
  local out
  out="$(wt project add same ~/x ~/x 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "repo_root and worktree_root are the SAME directory"

  out="$(wt project add nested ~/y ~/y/wts 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "worktree_root (\"$HOME/y/wts\") is nested inside repo_root"
}

# A default_project naming a project that no longer exists (hand-edited config, or the
# project it named was removed some other way) must be treated as UNSET, not left dangling --
# otherwise `project list`'s "*" marker never comes back without the user running `project
# default` by hand.
test_project_add_repairs_dangling_default_project() {
  write_config <<EOF
default_project = ghost
EOF
  assert_exit 0 wt project add me ~/src ~/wts
  assert_eq "$(wt config get default_project)" "me"
  assert_contains "$(wt project list)" "* me"
}

# R27: a project section must never end up on disk with only one of repo_root/worktree_root.
# Simulate an interrupted `add` (config_set writes one key at a time) by hand-writing a
# half-project, then confirm `project add` treats it as recoverable rather than permanently
# blocked behind "already exists" -- and that a config with BOTH keys still refuses as a true
# duplicate.
test_project_add_completes_half_written_project() {
  write_config <<EOF
[project me]
repo_root = ~/oldsrc
EOF
  assert_exit 1 wt config get project.me.worktree_root   # confirm the fixture is half-written
  assert_exit 0 wt project add me ~/newsrc ~/wts
  assert_eq "$(wt config get project.me.repo_root)" "$HOME/newsrc"
  assert_eq "$(wt config get project.me.worktree_root)" "$HOME/wts"
  # now it's complete -- re-adding must be a true duplicate error.
  assert_exit 1 wt project add me ~/newsrc ~/wts
}

# Deciding dangling [repo] -> project references: `project remove` refuses while a
# registered repo still names it, rather than silently leaving (or cascading through) a
# broken reference that later commands would have to guess at.
test_project_remove_refuses_while_repos_reference_it() {
  make_repo "$HOME/elsewhere/api"
  wt project add me ~/src ~/wts >/dev/null
  wt repo add ~/elsewhere/api --project me >/dev/null
  local out; out="$(wt project remove me 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "repos still reference it"
  assert_exit 0 wt config get project.me.repo_root   # project untouched
  wt repo remove api >/dev/null
  assert_exit 0 wt project remove me
}

# R29: repo names come straight from `repo add --name` once this command exists -- a name of
# "." or ".." or containing "/" must be rejected here, at the entry point, not merely
# filtered later by is_safe_repo_name at read time. The bare character-class regex used
# elsewhere in this codebase (e.g. "[A-Za-z0-9_.-]##") would WRONGLY ACCEPT "..", since both
# characters are in that class -- this must go through is_safe_repo_name itself.
test_repo_add_rejects_unsafe_names() {
  make_repo "$HOME/elsewhere/api"
  wt project add me ~/src ~/wts >/dev/null
  assert_exit 2 wt repo add ~/elsewhere/api --name ..
  assert_exit 2 wt repo add ~/elsewhere/api --name .
  assert_exit 2 wt repo add ~/elsewhere/api --name a/b
  assert_contains "$(wt repo list 2>&1)" "no repos registered"   # none of the above wrote anything

  # legitimate dotted names must keep working (R29's own examples).
  make_repo "$HOME/elsewhere/dotfiles"
  assert_exit 0 wt repo add ~/elsewhere/dotfiles --name .dotfiles
  assert_eq "$(wt config get repo..dotfiles.project)" "me"
}

# `repo add` on a symlinked path derives the registered name from the CANONICALIZED target's
# basename ("~/proj-link" -> "[repo proj]"), not the symlink name typed on the command line.
# That behavior is intentional (the physical repo, not the symlink, is what's registered) but
# must be called out in the success message whenever the derived name differs from what the
# user typed and they didn't pin it explicitly with --name.
test_repo_add_notes_symlink_derived_name() {
  make_repo "$HOME/elsewhere/realproj"
  ln -s "$HOME/elsewhere/realproj" "$HOME/elsewhere/proj-link"
  wt project add me ~/src ~/wts >/dev/null
  local out; out="$(wt repo add ~/elsewhere/proj-link 2>&1)"
  assert_eq "$?" 0
  assert_eq "$(wt config get repo.realproj.path)" "$HOME/elsewhere/realproj"
  assert_contains "$out" "derived from the resolved target \"realproj\""
  assert_contains "$out" "not the symlink \"proj-link\" you typed"

  # An explicit --name suppresses the note -- the user chose the name deliberately.
  ln -s "$HOME/elsewhere/realproj" "$HOME/elsewhere/proj-link2"
  out="$(wt repo add ~/elsewhere/proj-link2 --name pinned 2>&1)"
  assert_eq "$?" 0
  assert_eq "${out//derived from the resolved target/}" "$out" "explicit --name must not trigger the symlink note"
}

run_tests

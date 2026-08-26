#!/usr/bin/env zsh
# Direct tests for lib/worktree.zsh's shared helpers -- specifically dir_is_cruft_only,
# which has no callers yet (Task 6's `remove` doesn't use it; Task 7's `prune` will, and
# DELETES a directory outright on its "cruft only" verdict). Pinning its fail-closed
# behavior now, before prune exists to exercise it, matches R24: a failed or ambiguous
# inspection must read as "not cruft", never as "cruft".
source "${0:A:h}/helpers.zsh"
source "$WT_TEST_ROOT/lib/worktree.zsh"

test_cruft_only_unreadable_subdir_is_not_cruft() {
  mkdir -p "$TMP_ROOT/d/hidden"
  print "real work" > "$TMP_ROOT/d/hidden/work.txt"
  chmod 000 "$TMP_ROOT/d/hidden"
  assert_exit 1 dir_is_cruft_only "$TMP_ROOT/d"
  # Restore before teardown_env's rm -rf runs, same reasoning as the chmod-000 remove test.
  chmod 755 "$TMP_ROOT/d/hidden"
}

test_cruft_only_symlink_only_dir_is_not_cruft() {
  mkdir -p "$TMP_ROOT/d2"
  print target > "$TMP_ROOT/real_target.txt"
  ln -s "$TMP_ROOT/real_target.txt" "$TMP_ROOT/d2/link.txt"
  # A symlink is real content pointing somewhere -- `find -type f` alone would miss it
  # entirely (it isn't a regular file), which is exactly the bug this pins against.
  assert_exit 1 dir_is_cruft_only "$TMP_ROOT/d2"
}

test_cruft_only_newline_in_filename_is_not_cruft() {
  mkdir -p "$TMP_ROOT/d3"
  print x > "$TMP_ROOT/d3/real"$'\n'"work.txt"
  # A newline-delimited scan could split this one file into two lines, each of which might
  # look like harmless cruft even though the real (single) filename doesn't match .idea/ or
  # .DS_Store. NUL-delimited scanning must keep it as one atomic, non-cruft entry.
  assert_exit 1 dir_is_cruft_only "$TMP_ROOT/d3"
}

test_cruft_only_idea_and_ds_store_alone_is_cruft() {
  mkdir -p "$TMP_ROOT/d4/.idea"
  print ws > "$TMP_ROOT/d4/.idea/workspace.xml"
  print x > "$TMP_ROOT/d4/.DS_Store"
  # Sanity check: the fail-closed fixes above must not have turned dir_is_cruft_only into
  # something that never reports cruft at all.
  assert_exit 0 dir_is_cruft_only "$TMP_ROOT/d4"
}

test_cruft_only_empty_dir_is_cruft() {
  mkdir -p "$TMP_ROOT/d5"
  assert_exit 0 dir_is_cruft_only "$TMP_ROOT/d5"
}

# R28/C-2: `find "$1" ...` prefixes every result with the argument you gave it, so matching
# an entry's path is only safe RELATIVE to $1. Reproduced against the real binary: a
# worktree_root nested under "~/.idea/wts" made an orphan holding only a real file look like
# cruft, because ".idea" appeared as an ANCESTOR of the candidate, not inside it. Pin the
# fix directly: a candidate two levels under a ".idea" directory, holding one real file, must
# never be classified as cruft.
test_cruft_only_ancestor_idea_component_does_not_fool_relative_match() {
  mkdir -p "$TMP_ROOT/.idea/sub"
  print "real content" > "$TMP_ROOT/.idea/sub/real.txt"
  assert_exit 1 dir_is_cruft_only "$TMP_ROOT/.idea/sub"
}

# R25, re-pinned against the fixed (relative) matching: a FILE literally named ".idea" (not
# a directory -- distinct from a ".idea/" directory's own contents) holding real content is
# real work, never cruft, regardless of depth.
test_cruft_only_idea_named_file_is_real_work() {
  mkdir -p "$TMP_ROOT/d6/sub"
  print "not actually IDE state" > "$TMP_ROOT/d6/sub/.idea"
  assert_exit 1 dir_is_cruft_only "$TMP_ROOT/d6"
}

run_tests

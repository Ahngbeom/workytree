#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

test_install_from_checkout_links_and_registers() {
  print '# existing' > "$HOME/.zshrc"
  WORKYTREE_INSTALL_DIR="$WT_TEST_ROOT" sh "$WT_TEST_ROOT/install.sh" >/dev/null 2>&1
  assert_eq "$?" 0
  assert_eq "$(readlink "$HOME/.local/bin/workytree")" "$WT_TEST_ROOT/bin/workytree"
  assert_eq "$(grep -c 'shell/workytree.zsh' "$HOME/.zshrc")" "1"
  assert_contains "$(cat "$HOME/.zshrc")" "# existing"
  assert_eq "$(ls "$HOME"/.zshrc.bak-* | wc -l | tr -d ' ')" "1"
  # idempotent
  WORKYTREE_INSTALL_DIR="$WT_TEST_ROOT" sh "$WT_TEST_ROOT/install.sh" >/dev/null 2>&1
  assert_eq "$(grep -c 'shell/workytree.zsh' "$HOME/.zshrc")" "1"
  assert_eq "$(ls "$HOME"/.zshrc.bak-* | wc -l | tr -d ' ')" "1"
  assert_eq "$(readlink "$HOME/.local/bin/workytree")" "$WT_TEST_ROOT/bin/workytree"
  assert_eq "$("$HOME/.local/bin/workytree" --version | cut -d' ' -f1)" "workytree"
}

# R51: pins the DISABLED_RE branch (install.sh) -- a commented-out source line is a
# deliberate user choice and must never be reactivated, and since nothing is written in this
# branch, no backup file may appear either. Deleting this branch (mutation-tested below, see
# the task report) makes the line fall through to the "unrelated mention" else-branch instead,
# which WOULD append a second, live line next to the disabled one and DOES write a backup --
# exactly what this test would then catch failing.
test_install_leaves_disabled_source_line_alone_no_backup() {
  local disabled_line='# [ -s "'"$HOME"'/old-workytree/shell/workytree.zsh" ] && source "'"$HOME"'/old-workytree/shell/workytree.zsh"'
  {
    print -r -- "# workytree shell integration"
    print -r -- "$disabled_line"
  } > "$HOME/.zshrc"
  local before; before="$(cat "$HOME/.zshrc")"
  WORKYTREE_INSTALL_DIR="$WT_TEST_ROOT" sh "$WT_TEST_ROOT/install.sh" >/dev/null 2>&1
  assert_eq "$?" 0
  assert_eq "$(cat "$HOME/.zshrc")" "$before" "a commented-out source line must be left byte-identical"
  assert_eq "$(grep -c 'shell/workytree.zsh' "$HOME/.zshrc")" "1" "still just the one disabled line -- no live line added"
  # (N) glob qualifier: null-glob just this pattern, so a genuinely empty match doesn't abort
  # the test with zsh's default "no matches found" -- unlike the non-zero-backup-count checks
  # elsewhere in this file, this is the one place a MATCH of zero is the expected, passing case.
  local -a baks; baks=("$HOME"/.zshrc.bak-*(N))
  assert_eq "${#baks}" "0" "nothing was written, so no backup may be created"
}

# R51: pins the ACTIVE_RE branch -- a stale source line pointing at a DIFFERENT install
# directory (e.g. a prior install this repo was moved from) must be REPLACED, not left
# stale and not left alongside a second, duplicate live line, and the replacement must be
# backed up first. Deleting this branch (mutation-tested below) makes the stale line fall
# through to the "unrelated mention" else-branch instead, which appends a NEW live line next
# to the old one -- two source lines mentioning workytree, the old path still present -- and
# is exactly what this test would then catch failing.
test_install_replaces_stale_active_source_line() {
  local old_dir="$HOME/old-workytree-checkout"
  local stale_line='[ -s "'"$old_dir"'/shell/workytree.zsh" ] && source "'"$old_dir"'/shell/workytree.zsh"'
  {
    print -r -- "# workytree shell integration"
    print -r -- "$stale_line"
  } > "$HOME/.zshrc"
  WORKYTREE_INSTALL_DIR="$WT_TEST_ROOT" sh "$WT_TEST_ROOT/install.sh" >/dev/null 2>&1
  assert_eq "$?" 0
  local after; after="$(cat "$HOME/.zshrc")"
  assert_eq "$(grep -c 'shell/workytree.zsh' "$HOME/.zshrc")" "1" "the stale line must be replaced, not left alongside a new one"
  assert_contains "$after" "$WT_TEST_ROOT/shell/workytree.zsh"
  assert_eq "${after//$old_dir/}" "$after" "the old path must be gone entirely, not merely superseded"
  assert_eq "$(ls "$HOME"/.zshrc.bak-* | wc -l | tr -d ' ')" "1" "exactly one backup created for the replacement"
}

# R51: pins that content merely MENTIONING the path -- prose, an alias quoting it, anything
# that isn't structurally one of install.sh's own source statements -- is never touched, only
# reported. The mention survives byte-identical; a new live line is appended below it (this
# is a plain "no line of ours exists yet" case, same as test_install_from_checkout_links_and_
# registers above, just with a decoy line already present).
test_install_leaves_unrelated_mention_of_path_byte_identical() {
  local prose='# unrelated: this repo also has a file at shell/workytree.zsh, see docs'
  print -r -- "$prose" > "$HOME/.zshrc"
  local out; out="$(WORKYTREE_INSTALL_DIR="$WT_TEST_ROOT" sh "$WT_TEST_ROOT/install.sh" 2>&1)"
  assert_eq "$?" 0
  assert_contains "$out" "leaving that line untouched"
  assert_eq "$(sed -n '1p' "$HOME/.zshrc")" "$prose" "the unrelated line must survive byte-identical"
  assert_eq "$(grep -c 'shell/workytree.zsh' "$HOME/.zshrc")" "2" "one mention in the unrelated prose, one in the newly appended live line"
  assert_eq "$(ls "$HOME"/.zshrc.bak-* | wc -l | tr -d ' ')" "1"
}

run_tests

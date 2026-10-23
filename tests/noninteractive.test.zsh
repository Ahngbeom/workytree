#!/usr/bin/env zsh
# README "비대화 실행": one test per row of the question table, each covering both -y and
# "no terminal". Rows that need a real terminal run on a pty (helpers.zsh: pty_run).
source "${0:A:h}/helpers.zsh"

fixture() {
  make_repo "$HOME/src/app"
  write_config <<'EOF'
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

# remove_from_inside <mode>: removes fix/K from inside it with WORKYTREE_SHELL=<mode>; sets
# OUT (stdout) and ERR (stderr).
remove_from_inside() {
  wt create app fix K main -y >/dev/null 2>&1
  OUT="$(cd "$HOME/wts/app/fix/K" && WORKYTREE_SHELL=$1 "$WT_BIN" remove app fix K -y 2>"$HOME/err" </dev/null)"
  ERR="$(<"$HOME/err")"
}

test_remove_from_inside_without_an_owning_shell_warns() {
  fixture
  local mode OUT ERR
  for mode in captured script ''; do
    remove_from_inside "$mode"
    assert_eq "${OUT##*$'\n'}" "$HOME/src/app" "last line, mode=[$mode]"
    assert_contains "$ERR" "your shell's current directory was removed" "mode=[$mode]"
    assert_contains "$ERR" "hint: cd $HOME/src/app"
    assert_eq "${ERR#*moving to}" "$ERR" "no move line, mode=[$mode]"
  done
  for mode in terminal redirected; do
    remove_from_inside "$mode"
    assert_eq "${OUT##*$'\n'}" "$HOME/src/app"
    assert_eq "${ERR#*directory was removed}" "$ERR" "no warning, mode=$mode"
    assert_contains "$ERR" "→ moving to"
  done
}

run_tests

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

# fake_fzf: an fzf on PATH that reports being opened. A real fzf in a system directory wins
# (bin/workytree puts those first); then a regression shows up as the pty timing out instead.
fake_fzf() {
  mkdir -p "$HOME/bin"
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "0.55.0 (fake)"; exit 0; }\necho FZF-OPENED\nexit 130\n' > "$HOME/bin/fzf"
  chmod +x "$HOME/bin/fzf"
  export PATH="$HOME/bin:$PATH"
}

test_create_uses_the_inferred_repo_without_asking() {
  fixture
  (cd "$HOME/src/app" && "$WT_BIN" create fix IN main -y </dev/null >/dev/null 2>&1)
  assert_dir "$HOME/wts/app/fix/IN"
  (cd "$HOME/src/app" && "$WT_BIN" create fix IN2 main </dev/null >/dev/null 2>&1)
  assert_dir "$HOME/wts/app/fix/IN2"
}

test_create_missing_arguments_name_the_reason() {
  fixture
  local out
  out="$(pty_run "$WT_BIN create app -y; print RC=\$?")"
  assert_contains "$out" "kind is required"
  assert_contains "$out" "(not asking: --yes)"
  assert_contains "$out" "RC=2"
  out="$(wt create app 2>&1)"
  assert_contains "$out" "(not asking: no terminal)"
}

test_create_takes_the_base_default_and_confirms_with_yes() {
  fixture
  local rc
  WORKYTREE_PROMPT_INPUT=/dev/null "$WT_BIN" create app fix P -y >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 0 "-y wins over the prompt test hook"
  assert_dir "$HOME/wts/app/fix/P"
  wt create app fix P2 >/dev/null 2>&1
  assert_dir "$HOME/wts/app/fix/P2"
}

test_remove_missing_arguments_name_the_reason() {
  fixture
  local out
  out="$(pty_run "$WT_BIN remove app -y; print RC=\$?")"
  assert_contains "$out" "(repo, kind and ticket are required; not asking: --yes)"
  assert_eq "${out#*without a terminal}" "$out" "no terminal blamed for -y"
  assert_contains "$out" "RC=2"
  assert_contains "$(wt remove app 2>&1)" "not asking: no terminal"
}

test_remove_refuses_a_dirty_worktree_without_force() {
  fixture
  wt create app fix D main -y >/dev/null 2>&1
  print x > "$HOME/wts/app/fix/D/new.txt"
  assert_exit 1 wt remove app fix D -y
  assert_dir "$HOME/wts/app/fix/D"
  assert_exit 0 wt remove app fix D --force -y
  assert_not_exists "$HOME/wts/app/fix/D"
}

test_remove_keeps_branches_without_flags() {
  fixture
  wt create app fix B main -y >/dev/null 2>&1
  wt remove app fix B -y >/dev/null 2>&1
  assert_exit 0 git -C "$HOME/src/app" show-ref --verify --quiet refs/heads/fix/B
}

test_init_missing_arguments_name_the_reason() {
  local out
  out="$(pty_run "$WT_BIN init -y; print RC=\$?")"
  assert_contains "$out" "(not asking: --yes)"
  assert_contains "$out" "RC=2"
  assert_contains "$(wt init 2>&1)" "(not asking: no terminal)"
}

test_status_prints_the_table_with_yes_or_without_a_terminal() {
  fixture; fake_fzf
  local out
  out="$(pty_run "$WT_BIN status -y --offline; print RC=\$?")"
  assert_contains "$out" "REPO"
  assert_contains "$out" "RC=0"
  assert_eq "${out#*FZF-OPENED}" "$out" "no fzf under -y"
  assert_contains "$(wt status --offline)" "REPO"
}

test_config_edit_refuses_with_yes_or_without_a_terminal() {
  fixture
  local out rc
  out="$(pty_run "EDITOR=false $WT_BIN config edit -y; print RC=\$?")"
  assert_contains "$out" "(not opening one: --yes)"
  assert_contains "$out" "RC=2"
  out="$(EDITOR=false wt config edit 2>&1)"; rc=$?
  assert_eq "$rc" 2
  assert_contains "$out" "(not opening one: no terminal)"
  assert_contains "$out" "workytree config path"
  assert_contains "$(pty_run "EDITOR=true $WT_BIN config edit; print RC=\$?")" "RC=0" "a terminal still gets the editor"
}

test_ai_session_runs_with_yes_and_is_skipped_without_a_terminal() {
  fixture
  mkdir -p "$HOME/bin"; printf '#!/bin/sh\n' > "$HOME/bin/fakeagent"; chmod +x "$HOME/bin/fakeagent"
  export PATH="$HOME/bin:$PATH"
  wt config set ai_agent fakeagent >/dev/null
  wt config set ai_session ask >/dev/null
  local rf="$TMP_ROOT/runfile" out; : > "$rf"
  WORKYTREE_AI_RUNFILE="$rf" wt create app fix A1 main -y >/dev/null 2>&1
  assert_eq "$(<"$rf")" "fakeagent" "-y runs it"
  : > "$rf"
  out="$(WORKYTREE_AI_RUNFILE="$rf" wt create app fix A2 main 2>&1)"
  assert_dir "$HOME/wts/app/fix/A2"
  assert_eq "$(<"$rf")" "" "no terminal, no -y: not run"
  assert_contains "$out" "ai session skipped: ai_session = ask needs a terminal to ask (pass --ai or -y to run it)"
}

# origin_with_probe_push: origin is a local bare repo for fetches, but pushes go to a
# wtprobe:: URL, which git hands to $HOME/bin/git-remote-wtprobe. The helper logs the
# GIT_TERMINAL_PROMPT it was given and fails, like a remote that wants credentials.
origin_with_probe_push() {
  git init -q --bare "$HOME/origin.git"
  git -C "$HOME/src/app" remote add origin "$HOME/origin.git"
  git -C "$HOME/src/app" push -q origin main
  git -C "$HOME/src/app" config remote.origin.pushurl wtprobe::x
  mkdir -p "$HOME/bin"
  printf '#!/bin/sh\necho "prompt=[$GIT_TERMINAL_PROMPT]" >> "%s/probe.log"\nexit 1\n' "$HOME" > "$HOME/bin/git-remote-wtprobe"
  chmod +x "$HOME/bin/git-remote-wtprobe"
  export PATH="$HOME/bin:$PATH"
}

# with_pushed_branch <ticket>: a worktree fix/<ticket> whose branch is on origin.
with_pushed_branch() {
  wt create app fix "$1" main -y >/dev/null 2>&1
  git -C "$HOME/src/app" push -q "$HOME/origin.git" "fix/$1"
  git -C "$HOME/src/app" fetch -q origin
  git -C "$HOME/src/app" branch -q -u "origin/fix/$1" "fix/$1"
}

test_remote_git_never_prompts_for_credentials() {
  fixture; origin_with_probe_push
  with_pushed_branch R1
  local out rc
  out="$(wt remove app fix R1 -r -y 2>&1)"; rc=$?
  assert_eq "$rc" 0 "a failed remote delete is a ✗ row, not a failed remove"
  assert_contains "$out" "failed to delete remote branch: origin/fix/R1"
  with_pushed_branch R2
  pty_run "$WT_BIN remove app fix R2 -r -y" >/dev/null
  assert_eq "$(<"$HOME/probe.log")" $'prompt=[0]\nprompt=[0]' "no terminal, then a terminal"
}

run_tests

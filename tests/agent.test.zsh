#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

# Resolution/detection are pure functions over already-loaded config state, so they are
# reached the same way tests/config.test.zsh reaches library internals: source the modules
# and call them in-process. No CLI round-trip needed until Task 4.
source "$WT_TEST_ROOT/lib/ui.zsh"
source "$WT_TEST_ROOT/lib/config.zsh"
source "$WT_TEST_ROOT/lib/prompt.zsh"
source "$WT_TEST_ROOT/lib/agent.zsh"

# fake_agent <name...>: put executables on PATH so detection sees them. They are never run
# by bin/workytree -- it only ever WRITES the command into the runfile.
fake_agent() {
  mkdir -p "$HOME/fakebin"
  local n
  for n in "$@"; do
    cat > "$HOME/fakebin/$n" <<EOF
#!/bin/sh
echo "AGENT-RAN name=$n pwd=\$PWD args=\$*"
EOF
    chmod +x "$HOME/fakebin/$n"
  done
  export PATH="$HOME/fakebin:$PATH"
}

test_setting_prefers_project_over_global() {
  write_config <<'EOF'
ai_agent = claude

[project work]
repo_root = ~/a
worktree_root = ~/b
ai_agent = codex
EOF
  config_load
  assert_eq "$(ai_setting work ai_agent)" "codex"
  assert_eq "$(ai_setting other ai_agent)" "claude"
  assert_exit 1 ai_setting work nope
}

test_session_mode_defaults_off_and_rejects_garbage() {
  write_config <<'EOF'
[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  assert_eq "$(ai_session_mode w)" "off"

  write_config <<'EOF'
ai_session = always

[project w]
repo_root = ~/a
worktree_root = ~/b
ai_session = ask
EOF
  config_load
  assert_eq "$(ai_session_mode w)" "ask"
  assert_eq "$(ai_session_mode other)" "always"

  write_config <<'EOF'
ai_session = maybe

[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  assert_eq "$(ai_session_mode w 2>/dev/null)" "off" "invalid value falls back to off"
  assert_contains "$(ai_session_mode w 2>&1 >/dev/null)" "invalid ai_session"
}

test_builtin_claude_profile_available_without_config() {
  write_config <<'EOF'
[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  assert_eq "$(ai_profile_get claude ask)" "permission_mode,model,teammate_mode"
  assert_eq "$(ai_profile_get claude teammate_mode)" "auto,tmux,iterm2,in-process"
  assert_eq "$(ai_agent_command claude)" "claude"
  assert_eq "$(ai_agent_command aider)" "aider" "no profile -> command is the name itself"
  assert_exit 1 ai_profile_get aider ask
}

test_user_agent_section_replaces_builtin_wholesale() {
  write_config <<'EOF'
[agent claude]
ask = model
model = opus
EOF
  config_load
  assert_eq "$(ai_profile_get claude ask)" "model"
  assert_exit 1 ai_profile_get claude teammate_mode "user section replaces, never merges"
  assert_eq "$(ai_agent_command claude)" "claude" "command absent -> section name"
}

# NOTE on WT_AI_PROBE_ORDER injection below: tests/helpers.zsh:setup_env isolates HOME and
# XDG_CONFIG_HOME but does not scrub PATH, and bin/workytree:5 force-prepends system
# directories ahead of anything a test could put there anyway -- so a real `claude`/`codex`
# on the developer's PATH would silently win detection and make these assertions
# machine-dependent. Each test below shadows WT_AI_PROBE_ORDER with `local -a` rather than
# assigning the plain `typeset -ga` global: zsh's dynamic scoping makes that local visible to
# ai_resolve_agent for every call made from within the test function (including inside a
# `$(...)` command substitution, which forks but inherits the local-variable stack), and it
# pops back to the shipped default the moment the test function returns -- so an override in
# one test can never leak into a later one, even though tests run in a fixed alphabetical
# order against a PATH that also isn't reset between them (see fake_agent above).
test_resolve_agent_prefers_explicit_then_probe_order() {
  write_config <<'EOF'
[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  local -a WT_AI_PROBE_ORDER=(wt-absent-a wt-absent-b)
  assert_exit 1 ai_resolve_agent w "nothing on PATH -> no agent"

  fake_agent codex aider
  WT_AI_PROBE_ORDER=(codex aider)
  assert_eq "$(ai_resolve_agent w)" "codex" "probe order puts codex before aider"

  write_config <<'EOF'
ai_agent = aider

[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  assert_eq "$(ai_resolve_agent w)" "aider" "explicit ai_agent wins over probe order"
}

# Replacement for the CLI-level "auto-detection found nothing -> stay silent" check
# originally planned for Task 4: WT_AI_PROBE_ORDER is only controllable in-process (see the
# note above), so that CLI-level check was dropped there and this in-process test carries
# the spec's error-table row instead -- rc 1, nothing on stdout, nothing on stderr.
test_resolve_agent_silent_when_nothing_found() {
  write_config <<'EOF'
[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  local -a WT_AI_PROBE_ORDER=(wt-absent-a wt-absent-b)
  assert_eq "$(ai_resolve_agent w 2>/dev/null)" "" "no stdout when nothing found"
  assert_eq "$(ai_resolve_agent w 2>&1 >/dev/null)" "" "no stderr when nothing found"
  assert_exit 1 ai_resolve_agent w "rc 1 when nothing found"
}

# Every other test in this file overrides WT_AI_PROBE_ORDER (locally) so detection is
# deterministic regardless of ambient PATH -- which means none of them would notice a
# regression in the SHIPPED default order. This test intentionally does not touch
# WT_AI_PROBE_ORDER, so it sees whatever lib/agent.zsh assigned at source time and pins it
# against the order documented in lib/agent.zsh's own comment (claude first, then codex,
# gemini, cursor-agent, aider).
test_default_probe_order_matches_documented_list() {
  assert_eq "${(j:,:)WT_AI_PROBE_ORDER}" "claude,codex,gemini,cursor-agent,aider"
}

# answers <line...>: builds a WORKYTREE_PROMPT_INPUT answer file and puts its path in
# REPLY_ANSWERS.
typeset -g REPLY_ANSWERS=""
answers() { REPLY_ANSWERS="$TMP_ROOT/answers"; print -l -- "$@" > "$REPLY_ANSWERS"; }

test_build_argv_maps_underscores_to_flags_and_omits_skips() {
  write_config <<'EOF'
[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  # ask = permission_mode,model,teammate_mode
  #   permission_mode: 1=(skip) 2=plan 3=acceptEdits 4=auto 5=bypassPermissions 6=dontAsk 7=manual
  #   model:           1=(skip) 2=opus 3=sonnet 4=fable
  #   teammate_mode:   1=(skip) 2=auto 3=tmux 4=iterm2 5=in-process
  answers 2 1 3
  local out
  out="$(WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" ai_build_argv claude always 2>/dev/null)"
  assert_eq "$out" $'claude\n--permission-mode\nplan\n--teammate-mode\ntmux'
}

test_build_argv_accepts_free_text_outside_the_list() {
  write_config <<'EOF'
[agent claude]
ask = model
model = opus,sonnet
EOF
  config_load
  answers "claude-fable-5"
  local out
  out="$(WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" ai_build_argv claude always 2>/dev/null)"
  assert_eq "$out" $'claude\n--model\nclaude-fable-5'
}

test_build_argv_skips_ask_entries_with_no_value_list() {
  write_config <<'EOF'
[agent claude]
ask = model,nonexistent_option
model = opus
EOF
  config_load
  answers 2
  local out
  out="$(WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" ai_build_argv claude always 2>/dev/null)"
  assert_eq "$out" $'claude\n--model\nopus' "an ask entry with no key is skipped, not an error"
}

# NOTE: this only proves the no-tty branch of prompt_available (stdin isn't a tty under the
# test runner, so prompt_available returns 1 regardless of WT_YES). It does NOT prove WT_YES
# skips the interview: dropping `WT_YES=1` from the invocation below produces identical
# output, because prompt_available's `[[ -t 0 ]]` check also returns 1 here on its own. No
# test in this suite can discriminate the WT_YES gate specifically, since that requires a
# real tty to reach the point where WT_YES vs. no-tty would differ.
test_build_argv_without_prompts_returns_bare_command() {
  write_config <<'EOF'
[agent claude]
command = claude --bare
ask = model
model = opus
EOF
  config_load
  local out
  out="$(WT_YES=1 ai_build_argv claude always 2>/dev/null)"
  assert_eq "$out" $'claude\n--bare' "prompts unavailable -> bare, tokenized command"
}

test_build_argv_ask_mode_declined_returns_nonzero() {
  write_config <<'EOF'
[agent claude]
ask = model
model = opus
EOF
  config_load
  answers n
  local out rc
  out="$(WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" ai_build_argv claude ask 2>/dev/null)"; rc=$?
  assert_eq "$rc" 1 "declining the confirm is a refusal, not a crash"
  assert_eq "$out" ""
}

test_build_argv_cancel_kills_only_the_subshell() {
  write_config <<'EOF'
[agent claude]
ask = model
model = opus
EOF
  config_load
  answers q
  local out rc
  out="$(WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" ai_build_argv claude always 2>/dev/null)"; rc=$?
  assert_eq "$rc" 130 "q propagates prompt.zsh's exit 130 out of the substitution"
  assert_eq "$out" "" "and the caller is still alive to see it"
}

# From here on, these are CLI round-trip tests. The fixture uses the same shape as
# tests/create.test.zsh.
cli_fixture() {
  make_repo "$HOME/src/app"
  write_config <<'EOF'
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

test_default_off_writes_nothing_to_the_runfile() {
  cli_fixture; fake_agent claude
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main -y >/dev/null 2>&1
  assert_dir "$HOME/wts/app/fix/PROJ-1"
  assert_eq "$(<"$rf")" "" "ai_session defaults to off"
}

test_ai_flag_writes_runfile_and_create_still_prints_path_last() {
  cli_fixture; fake_agent claude
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  local out
  out="$(WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main --ai -y 2>/dev/null)"
  assert_eq "${out##*$'\n'}" "$HOME/wts/app/fix/PROJ-1" "stdout contract is untouched"
  assert_eq "$(<"$rf")" "claude"
}

test_ai_session_always_needs_no_flag() {
  cli_fixture; fake_agent claude
  wt config set ai_session always >/dev/null
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main -y >/dev/null 2>&1
  assert_eq "$(<"$rf")" "claude"
}

test_project_ai_session_overrides_global() {
  cli_fixture
  fake_agent claude
  write_config <<'EOF'
ai_session = always

[project me]
repo_root = ~/src
worktree_root = ~/wts
ai_session = off
EOF
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main -y >/dev/null 2>&1
  assert_eq "$(<"$rf")" "" "project 'off' beats global 'always'"
}

test_interview_answers_reach_the_runfile() {
  cli_fixture; fake_agent claude
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  # Create? confirm -> permission-mode(2=plan) -> model(1=skip) -> teammate-mode(3=tmux)
  answers y 2 1 3
  WORKYTREE_AI_RUNFILE="$rf" WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" \
    wt create app fix PROJ-1 main --ai >/dev/null 2>&1
  assert_eq "$(<"$rf")" $'claude\n--permission-mode\nplan\n--teammate-mode\ntmux'
}

test_cancelled_interview_keeps_the_worktree_and_exits_zero() {
  cli_fixture; fake_agent claude
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  answers y q
  local rc
  WORKYTREE_AI_RUNFILE="$rf" WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" \
    wt create app fix PROJ-1 main --ai >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 0 "cancelling the interview never fails create"
  assert_dir "$HOME/wts/app/fix/PROJ-1"
  assert_eq "$(<"$rf")" ""
}

test_missing_runfile_warns_but_create_succeeds() {
  cli_fixture; fake_agent claude
  local out rc
  out="$(wt create app fix PROJ-1 main --ai -y 2>&1)"; rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "shell integration"
  assert_dir "$HOME/wts/app/fix/PROJ-1"
}

test_unwritable_runfile_warns_but_create_succeeds() {
  cli_fixture; fake_agent claude
  # A runfile path under a nonexistent parent directory: ai_maybe_offer's write
  # (`print -r -- "$out" > "$WORKYTREE_AI_RUNFILE"`, lib/agent.zsh) fails at the shell level
  # rather than the runfile-unset gate, so this exercises the write-failure branch
  # specifically, not the "no shell integration" one above.
  local rf="$TMP_ROOT/no-such-dir/runfile"
  local out rc
  out="$(WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main --ai -y 2>&1)"; rc=$?
  assert_eq "$rc" 0 "an unwritable runfile must never fail create"
  assert_contains "$out" "could not write"
  assert_dir "$HOME/wts/app/fix/PROJ-1"
}

test_explicit_agent_missing_from_path_warns() {
  cli_fixture
  wt config set ai_agent nosuchagent >/dev/null
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  local out rc
  out="$(WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main --ai -y 2>&1)"; rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "nosuchagent"
  assert_eq "$(<"$rf")" ""
}

# test_no_agent_anywhere_is_silent (brief's Step 1) is intentionally omitted here: it wants a
# PATH with zero installed agents, but setup_env never scrubs PATH and bin/workytree:5
# force-prepends system directories ahead of anything a test could put there -- so on any
# machine with a real `claude`/`codex`/etc. already installed, detection would find it and
# the assertion would fail for a reason that has nothing to do with this code. The same
# error-table row (nothing found -> silent, rc 1) is already covered at the unit level by
# test_resolve_agent_silent_when_nothing_found above, which controls WT_AI_PROBE_ORDER
# in-process -- the only level at which "nothing on PATH" is actually reproducible.
test_dashdash_lets_ai_be_a_literal_positional() {
  cli_fixture
  local out rc
  out="$(wt create -- --ai fix PROJ-1 main -y 2>&1)"; rc=$?
  assert_eq "$rc" 1 "'--ai' after -- is a repo name, and there is no such repo"
  assert_contains "$out" "--ai"
}

# Finding 1: bin/workytree runs under `set -u`, and an `[agent x]` section with an empty (or
# whitespace-only) `command =` makes ${(z)cmd} split to ZERO words -- `${cmd_words[1]}` alone
# is then a fatal "parameter not set" that killed the whole process AFTER the worktree path
# had already been printed. The shell wrapper's `(( exit_code == 0 ))` guard then skips the
# cd, so the worktree exists but `create` reports failure and the user is left outside it.
# Verified directly (independent of this test) that `set -u; local -a a=(); print "${a[1]}"`
# aborts with rc 1 and no output, while `print "${a[1]:-}"` prints an empty string and
# continues.
test_empty_command_value_does_not_crash_create() {
  cli_fixture
  write_config <<'EOF'
ai_agent = claude

[project me]
repo_root = ~/src
worktree_root = ~/wts

[agent claude]
command =
EOF
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  local out rc
  out="$(WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main --ai -y 2>&1)"; rc=$?
  assert_eq "$rc" 0 "an empty \`command =\` must not crash create under set -u"
  assert_dir "$HOME/wts/app/fix/PROJ-1"
  assert_eq "$(<"$rf")" "" "no runfile written when the resolved command is empty"
}

# Finding 2: `print -l` (no `-r`) interprets backslash escapes in the argv it serializes into
# the runfile. A profile's free-typed option value (chosen at the interview, never passed
# through ${(z)}) can contain a literal backslash-n -- `print -l` turns THAT `\n` into an
# actual newline, and the wrapper's ${(f)} read-back on the other end then sees it as an EXTRA
# argv element: a value typed at a prompt injects an argument into the command about to run in
# the user's shell. This drives that through the interview path (not `command`, since (z)'s
# own backslash handling is a separate matter -- see the quoting test below and finding 6) by
# writing the WORKYTREE_PROMPT_INPUT file directly with printf (not the `answers` helper,
# which itself uses an un-`-r` `print -l` and would collapse the literal backslash-n below
# into a real newline before this test even reaches the code under test).
test_backslash_n_in_interview_answer_is_not_interpreted_as_newline() {
  cli_fixture; fake_agent claude
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  local af="$TMP_ROOT/answers"
  # Create? confirm -> permission-mode(1=skip) -> model(free text, literal backslash-n) ->
  # teammate-mode(1=skip).
  printf 'y\n1\nopus\\n--injected\n1\n' > "$af"
  WORKYTREE_AI_RUNFILE="$rf" WORKYTREE_PROMPT_INPUT="$af" \
    wt create app fix PROJ-1 main --ai >/dev/null 2>&1
  local -a lines
  lines=( "${(f)"$(<"$rf")"}" )
  assert_eq "${#lines}" "3" "the backslash-n text must not become an extra argv element"
  assert_eq "${lines[1]}" "claude"
  assert_eq "${lines[2]}" "--model"
  assert_eq "${lines[3]}" 'opus\n--injected' "literal backslash-n preserved, not split into a newline"
}

# Finding 6: docs/superpowers/specs/2026-08-26-auto-enter-ai-session-design.md used to claim
# ${(z)} "handles quotes correctly". Verified directly it does not: `${(z)}` alone on
# `claude --sys "be brief"` leaves the third word as the literal SEVEN characters
# `"be brief"`, quote marks included. `${(Q)}`, applied after `${(z)}` in ai_build_argv, is
# what strips them, so the documented way to write a multi-word `command` value (wrap it in
# double quotes) delivers ONE argument with no quote characters in it.
test_quoted_command_value_delivers_one_unquoted_argument() {
  cli_fixture; fake_agent claude
  write_config <<'EOF'
[project me]
repo_root = ~/src
worktree_root = ~/wts

[agent claude]
command = claude --sys "be brief"
EOF
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main --ai -y >/dev/null 2>&1
  local -a lines
  lines=( "${(f)"$(<"$rf")"}" )
  assert_eq "${#lines}" "3"
  assert_eq "${lines[1]}" "claude"
  assert_eq "${lines[2]}" "--sys"
  assert_eq "${lines[3]}" "be brief" "quoted multi-word value arrives as ONE argument without quote characters"
}

# Finding 3: the shell wrapper mktemps a runfile and exports its path as WORKYTREE_AI_RUNFILE
# into the CLI's environment on EVERY `create` -- it cannot know in advance whether the CLI
# will use it. Left exported, every process the CLI spawns inherits it too, including `git
# worktree add`'s post-checkout hook. Measured (independent of this test, with the pre-fix
# CLI): a repo's post-checkout hook writing to that path got its own command executed in the
# user's interactive shell after the cd, on a plain `create` that never even touched --ai. No
# --ai here either -- this is deliberately the default-config, feature-untouched path,
# matching README's claim that nothing about `wt create` changes until AI sessions are turned
# on.
test_ai_runfile_env_var_not_leaked_to_git_hooks() {
  cli_fixture
  local leak="$TMP_ROOT/leak-check"
  mkdir -p "$HOME/src/app/.git/hooks"
  cat > "$HOME/src/app/.git/hooks/post-checkout" <<HOOK
#!/bin/sh
printf 'value=[%s]\n' "\$WORKYTREE_AI_RUNFILE" > "$leak"
HOOK
  chmod +x "$HOME/src/app/.git/hooks/post-checkout"
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  WORKYTREE_AI_RUNFILE="$rf" wt create app fix HOOKLEAK main -y >/dev/null 2>&1
  assert_eq "$(<"$leak")" "value=[]" "the runfile path must not reach a git hook's environment"
}

run_tests

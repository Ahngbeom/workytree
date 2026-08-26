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

# answers <line...>: WORKYTREE_PROMPT_INPUT용 응답 파일을 만들고 경로를 REPLY_ANSWERS에 둔다.
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

run_tests

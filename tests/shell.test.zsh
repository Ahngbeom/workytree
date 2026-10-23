#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"
SHELL_FILE="$WT_TEST_ROOT/shell/workytree.zsh"

# zsh_i <code>: run in an interactive zsh with an isolated ZDOTDIR that sources the integration.
# -d (NO_GLOBAL_RCS) skips /etc/zsh/zshrc -- Debian/Ubuntu's zsh package ships one that runs
# `compinit` unconditionally for interactive shells, and on a runner with no controlling TTY
# that aborts with "not interactive and can't open terminal" / "compinit: initialization
# aborted" on both stdout+stderr (2>&1 below), polluting every captured assertion. $ZDOTDIR/.zshrc
# (the only rc file this test suite relies on) still loads with -d -- only the SYSTEM-wide rc is
# skipped.
# TMPDIR is isolated per interactive shell rather than exported from a test body. Test
# functions all share one process and setup_env never resets TMPDIR, so an exported value
# outlives the $TMP_ROOT it names -- teardown_env then deletes that directory, and every
# later test in the file is left pointing mktemp at a path that no longer exists. Setting it
# here, inside the shell under test, keeps each run's temp files in its own sandbox and lets
# no test hand a stale TMPDIR to the next one.
zsh_i() {
  export ZDOTDIR="$HOME"
  {
    print -r -- "export TMPDIR='$TMP_ROOT'"
    print -r -- "source '$SHELL_FILE'"
  } > "$ZDOTDIR/.zshrc"
  zsh -d -i -c "$1" 2>&1
}

fixture() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

test_functions_defined_and_alias_default_on() {
  fixture
  assert_contains "$(zsh_i 'whence -w workytree wt')" "workytree: function"
  assert_contains "$(zsh_i 'whence -w workytree wt')" "wt: function"
}

test_alias_off_by_config_or_env() {
  fixture; wt config set alias_wt false >/dev/null
  assert_contains "$(zsh_i 'whence -w wt')" "wt: none"
  wt config set alias_wt true >/dev/null
  assert_contains "$(WORKYTREE_ALIAS=0 zsh_i 'whence -w wt')" "wt: none"
}

test_alias_skipped_when_wt_taken() {
  fixture
  print -r -- "wt() { echo mine; }; source '$SHELL_FILE'" > "$HOME/.zshrc"
  local out; out="$(ZDOTDIR="$HOME" zsh -d -i -c 'wt' 2>&1)"
  assert_contains "$out" "already defined"
  assert_contains "$out" "mine"
}

# R35: a pre-existing `wt` ALIAS must not throw a raw zsh parser error while sourcing (zsh
# parses an entire if/else block, including the branch that will not run, at PARSE time --
# a literal `wt() { ... }` anywhere in the file collides with an existing alias named `wt`
# regardless of which branch actually executes). Also proves the alias itself still works
# afterward (not clobbered).
test_alias_skipped_when_wt_is_alias() {
  fixture
  print -r -- "alias wt='echo mine-alias'; source '$SHELL_FILE'" > "$HOME/.zshrc"
  local out; out="$(ZDOTDIR="$HOME" zsh -d -i -c 'wt' 2>&1)"
  assert_contains "$out" "already defined"
  assert_contains "$out" "mine-alias"
  local -i has_parser_error=0
  [[ "$out" == *"parse error"* || "$out" == *"defining function based on alias"* ]] && has_parser_error=1
  assert_eq "$has_parser_error" 0 "no zsh parser error when 'wt' is a pre-existing alias"
}

# R35, third kind: a pre-existing `wt` COMMAND on $PATH must also survive untouched.
test_alias_skipped_when_wt_is_command_on_path() {
  fixture
  mkdir -p "$HOME/bin"
  cat > "$HOME/bin/wt" <<'SCRIPT'
#!/bin/sh
echo mine-command
SCRIPT
  chmod +x "$HOME/bin/wt"
  print -r -- "export PATH=\"$HOME/bin:\$PATH\"; source '$SHELL_FILE'" > "$HOME/.zshrc"
  local out; out="$(ZDOTDIR="$HOME" zsh -d -i -c 'wt' 2>&1)"
  assert_contains "$out" "already defined"
  assert_contains "$out" "mine-command"
}

# R36: sourcing the file twice in the same shell (a plugin manager, or .zshrc plus an
# explicit re-source) must not treat OUR OWN earlier `wt` install as "already defined" --
# that's a false alarm, not a genuine clash. The second source must be silent and `wt` must
# still work.
test_double_source_is_idempotent_no_warning() {
  fixture
  local out; out="$(zsh_i "source '$SHELL_FILE'; whence -w wt")"
  assert_contains "$out" "wt: function"
  local -i has_warning=0
  [[ "$out" == *"already defined"* ]] && has_warning=1
  assert_eq "$has_warning" 0 "no false 'already defined' warning re-sourcing our own wt"
}

# R37 (fix round 2 regression): install `wt`, have something else redefine it (the
# near-universal `alias reload='source ~/.zshrc'` shape), then re-source. A boolean "did I
# ever install wt" flag would treat this as its own earlier install forever and silently
# clobber the redefinition with no warning -- the file must instead check whether the
# CURRENTLY-defined `wt` still matches what it would install, and since it does not here,
# must warn and leave the user's redefinition in place.
test_resource_after_external_redefinition_warns_and_preserves() {
  fixture
  local out
  out="$(zsh -c "
    source '$SHELL_FILE'
    wt() { echo user-overrode-this; }
    source '$SHELL_FILE'
    wt
  " 2>&1)"
  assert_contains "$out" "already defined"
  assert_contains "$out" "user-overrode-this"
}

test_create_cds_into_worktree() {
  fixture
  # >/dev/null 2>&1 (not just >/dev/null): `git worktree add` writes its "Preparing
  # worktree..." progress line to STDERR, and zsh_i merges the whole session's stderr into
  # its capture (2>&1) -- an unsuppressed stderr here would leak into the `pwd` capture below.
  assert_eq "$(zsh_i 'wt create app fix T main -y >/dev/null 2>&1; pwd')" "$HOME/wts/app/fix/T"
  assert_eq "$(zsh_i 'wt cd app fix T >/dev/null; pwd')" "$HOME/wts/app/fix/T"
  assert_eq "$(zsh_i 'wt cd app >/dev/null; pwd')" "$HOME/src/app"
}

test_remove_from_inside_worktree_cds_to_repo() {
  fixture
  wt create app fix RM main -y >/dev/null 2>&1
  assert_eq "$(zsh_i 'cd ~/wts/app/fix/RM; wt remove app fix RM </dev/null >/dev/null 2>&1; pwd')" "$HOME/src/app"
  assert_not_exists "$HOME/wts/app/fix/RM"
}

test_remove_to_flag_cds_there() {
  fixture
  wt create app fix RM main -y >/dev/null 2>&1
  assert_eq "$(zsh_i 'wt remove app fix RM --to ~ </dev/null >/dev/null 2>&1; pwd')" "$HOME"
}

test_remove_progress_reaches_terminal_through_wrapper() {
  fixture
  wt create app fix RM main -y >/dev/null 2>&1
  assert_contains "$(zsh_i 'wt remove app fix RM </dev/null')" "1/1 removing worktree"
}

test_failure_keeps_cwd_and_exit_code() {
  fixture
  local out; out="$(zsh_i "cd $HOME; wt create ghost fix T -y; echo rc=\$?; pwd")"
  assert_contains "$out" "rc=1"
  assert_contains "$out" $'\n'"$HOME"
}

test_noninteractive_wrapper_prints_path() {
  fixture
  local out; out="$(ZDOTDIR=$HOME zsh -c "source '$SHELL_FILE'; workytree create app fix N main -y" | tail -1)"
  assert_eq "$out" "$HOME/wts/app/fix/N"
}

# R34: bin/workytree accepts --project/--yes/-y/--no-color in ANY position, so the wrapper
# must locate the subcommand the same way the CLI does, not just look at "$1" -- otherwise a
# global option placed before `create`/`cd` silently disables auto-cd. Covers --project
# before, --yes after, and both the "--project value" and "--project=value" spellings, for
# both create and cd.
test_global_options_before_subcommand_still_autocd() {
  fixture
  assert_eq "$(zsh_i 'wt --project me create app fix R34A main -y >/dev/null 2>&1; pwd')" "$HOME/wts/app/fix/R34A"
  assert_eq "$(zsh_i 'wt --project=me create app fix R34B main -y >/dev/null 2>&1; pwd')" "$HOME/wts/app/fix/R34B"
  assert_eq "$(zsh_i 'wt --project me cd app >/dev/null; pwd')" "$HOME/src/app"
  assert_eq "$(zsh_i 'wt --project=me cd app >/dev/null; pwd')" "$HOME/src/app"
  # options on both sides of the subcommand
  assert_eq "$(zsh_i 'wt --project me create app fix R34C main --yes >/dev/null 2>&1; pwd')" "$HOME/wts/app/fix/R34C"
}

# R23/Finding 4: nothing previously asserted that informational lines preceding the final
# path (workytree's own info/success output, e.g. `success()`'s "result: created") actually
# reach the caller -- only the LAST line (the cd target) was checked. Assert on workytree's
# own wording, not a coincidental message.
test_create_relays_info_lines() {
  fixture
  local out; out="$(zsh_i 'wt create app fix RELAY main -y')"
  assert_contains "$out" "result: created"
}

# `cd` reaches the CLI as `cd`: cmd_cd checks that the target exists, cmd_path does not.
test_cd_reaches_the_cli_as_cd() {
  fixture
  local stub="$TMP_ROOT/stub-workytree" log="$TMP_ROOT/stub.log"
  cat > "$stub" <<'SCRIPT'
#!/usr/bin/env zsh
print -r -- "$1 $WORKYTREE_SHELL" > "$WT_STUB_LOG"
print -r -- "/stub/target/path"
SCRIPT
  chmod +x "$stub"
  zsh -c "
    export WT_STUB_LOG='$log'
    source '$SHELL_FILE'
    WORKYTREE_BIN='$stub'
    workytree cd app fix T >/dev/null
  "
  assert_eq "$(cat "$log")" "cd script"
}

# fake_claude: a fake agent placed on PATH. When run, it prints its own cwd and args -- this
# is how we confirm the wrapper cd's *first* and only then runs it.
fake_claude() {
  mkdir -p "$HOME/fakebin"
  cat > "$HOME/fakebin/claude" <<'EOF'
#!/bin/sh
echo "AGENT-RAN pwd=$PWD args=$*"
EOF
  chmod +x "$HOME/fakebin/claude"
  export PATH="$HOME/fakebin:$PATH"
}

test_create_ai_runs_the_agent_inside_the_new_worktree() {
  fixture; fake_claude
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main --ai -y')"
  assert_contains "$out" "AGENT-RAN"
  assert_contains "$out" "pwd=$HOME/wts/app/fix/PROJ-1"
}

test_create_without_ai_runs_nothing() {
  fixture; fake_claude
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main -y')"
  assert_eq "${out#*AGENT-RAN}" "$out" "no --ai, no agent"
  assert_eq "${out##*$'\n'}" "$HOME/wts/app/fix/PROJ-1" "the last line is the path"
}

test_agent_exit_code_does_not_fail_create() {
  fixture
  mkdir -p "$HOME/fakebin"
  print -r -- '#!/bin/sh' > "$HOME/fakebin/claude"
  print -r -- 'exit 3'   >> "$HOME/fakebin/claude"
  chmod +x "$HOME/fakebin/claude"
  export PATH="$HOME/fakebin:$PATH"
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main --ai -y; echo "rc=$?"')"
  assert_contains "$out" "rc=0" "the worktree was created; the agent's own exit is not create's"
}

# TMPDIR is exported to the test's own TMP_ROOT (not left as the shared ${TMPDIR:-/tmp})
# so the wrapper's mktemp lands there too -- otherwise a concurrent test run's own
# workytree-ai.* files in the shared system tmp dir could make this count nonzero for
# reasons unrelated to this test.
test_runfile_is_removed_after_the_run() {
  fixture; fake_claude
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main --ai -y; ls "${TMPDIR:-/tmp}" | grep -c "^workytree-ai\." || true')"
  assert_contains "$out" "AGENT-RAN"
  assert_eq "${out##*$'\n'}" "0" "no runfile left behind"
}

# Fix round 1, Finding 1: the pre-fix trap was `trap 'command rm -f -- "$runfile"' EXIT`
# (single quotes) -- $runfile is expanded only when the trap FIRES, which is after this
# function has already returned and its `local runfile` has gone out of scope. So the trap
# ran `rm -f --` with an empty argument and deleted nothing. The only thing that ever
# actually cleaned up was the explicit `rm -f` right before the agent runs, which is only
# reached when --ai fires interactively -- test_runfile_is_removed_after_the_run above
# exercises exactly that path, so it never caught this. An ordinary `create` with no `--ai`
# still mktemps a runfile (the wrapper can't know in advance whether the CLI will use it)
# but never writes or removes it via that explicit rm, so cleanup depends entirely on the
# trap. TMPDIR isolation comes from zsh_i, see its comment.
test_runfile_is_removed_without_ai() {
  fixture
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main -y; ls "${TMPDIR:-/tmp}" | grep -c "^workytree-ai\." || true')"
  assert_eq "${out##*$'\n'}" "0" "no runfile left behind on a plain create without --ai"
}

# fake_claude_argv: like fake_claude, but echoes each argv element it received on its own
# line, prefixed so the assertions below can pick just those lines out of the rest of the
# session's output. Needed to check argv elements individually (order, and whether an
# embedded space survived as ONE element) -- fake_claude's single `args=$*` line collapses
# that distinction.
fake_claude_argv() {
  mkdir -p "$HOME/fakebin"
  cat > "$HOME/fakebin/claude" <<'EOF'
#!/bin/sh
echo "AGENT-RAN"
for a in "$@"; do
  printf 'ARG:%s\n' "$a"
done
EOF
  chmod +x "$HOME/fakebin/claude"
  export PATH="$HOME/fakebin:$PATH"
}

# Fix round 1, Finding 2: every other test in this file produces a single-word runfile
# ("claude"), so the ${(f)}-into-array reconstruction in shell/workytree.zsh -- the entire
# basis for the "no eval" safety claim -- is never actually exercised past one element. This
# test drives a real multi-element argv through config (an [agent claude] `command` override,
# since the interview needs a real tty that the test runner doesn't have) -> ai_build_argv ->
# the runfile -> the wrapper's ${(f)} split, and checks the fake agent received all of it
# intact, in order, unsplit on internal whitespace.
#
# Fix round 2, Finding 2/6: this used to read `hello\ there` (backslash-escaped space), with a
# comment here claiming `${(z)cmd}` was what turned the escaped space into one literal-space
# word. Measured directly: `${(z)}` alone leaves that token as the literal TWELVE characters
# `hello\ there`, backslash included -- it was the old, unqualified `print -l` at
# serialization that silently ate the backslash as an "unrecognized" escape, giving the right
# answer for the wrong reason, while a genuine escape like `\n` in the same position was
# turned into a real newline and split into an extra argv element (see agent.zsh's argv test
# for that fix, `print -rl`). A double-quoted value exercises the mechanism this test is
# actually meant to cover: `${(z)}` alone leaves quote characters IN the word (verified:
# `${(z)}` on `"hello there"` keeps the literal string `"hello there"`, quotes and all);
# `${(Q)}`, applied after `${(z)}` in ai_build_argv, is what strips them and collapses it into
# one clean argument.
test_multi_element_argv_survives_the_round_trip() {
  make_repo "$HOME/src/app"
  write_config <<'EOF'
[project me]
repo_root = ~/src
worktree_root = ~/wts

[agent claude]
command = claude --bare "hello there" --flag
EOF
  fake_claude_argv
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main --ai -y')"
  assert_contains "$out" "AGENT-RAN"
  local -a lines args
  lines=( "${(f)out}" )
  local l
  for l in "${lines[@]}"; do
    [[ "$l" == ARG:* ]] && args+=( "${l#ARG:}" )
  done
  assert_eq "${#args}" "3" "all three non-executable argv elements arrived"
  assert_eq "${args[1]}" "--bare"
  assert_eq "${args[2]}" "hello there" "the quoted, space-containing element arrived as ONE argument with no quote characters"
  assert_eq "${args[3]}" "--flag"
}



# A hook cannot be simulated after the fact -- it has to observe the file WHILE the CLI runs.
# post-checkout fires inside `git worktree add`, exactly the window a real attack would use.
# hook_probe_runfile: install a post-checkout hook that reports whether a runfile exists at
# the moment `git worktree add` runs it, and return that verdict. This is the only window in
# which "the channel was never armed" is observable at all -- checking $TMPDIR after the
# command returns cannot tell "never created" apart from "created, then cleaned up", and a
# real hostile hook would be looking in exactly this window.
hook_probe_runfile() {
  mkdir -p "$HOME/src/app/.git/hooks"
  cat > "$HOME/src/app/.git/hooks/post-checkout" <<'HOOK'
#!/bin/sh
for f in "$TMPDIR"/workytree-ai.*; do
  [ -e "$f" ] || continue
  echo "HOOK-FOUND-RUNFILE" >&2
done
exit 0
HOOK
  chmod +x "$HOME/src/app/.git/hooks/post-checkout"
}

test_hook_cannot_find_a_runfile_when_sessions_are_not_configured() {
  fixture; hook_probe_runfile
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main -y')"
  assert_eq "${out#*HOOK-FOUND-RUNFILE}" "$out" "an unconfigured user's create never arms the channel"
}

# The wrapper's --ai scan must agree with cmd_create: `--` ends create's flags, so a later
# --ai is a positional. A stand-in CLI reports whether it was handed a runfile.
test_ai_flag_scan_matches_the_cli_parsing() {
  fixture
  stand_in '[ -n "$WORKYTREE_AI_RUNFILE" ] && s=ARMED || s=NOT-ARMED; echo "$* -> $s"'
  local out
  out="$(pty_run "WORKYTREE_BIN=$HOME/stand-in
    wt create app fix PROJ-1; wt create --ai app fix; wt create app fix PROJ-1 --ai
    wt create -- --ai fix; wt create --ai -- x")"
  assert_contains "$out" "create app fix PROJ-1 -> NOT-ARMED"
  assert_contains "$out" "create --ai app fix -> ARMED"
  assert_contains "$out" "create app fix PROJ-1 --ai -> ARMED"
  assert_contains "$out" "create -- --ai fix -> NOT-ARMED" "-- makes a following --ai a positional"
  assert_contains "$out" "create --ai -- x -> ARMED" "--ai before -- is still the flag"
}

test_ai_flag_arms_the_channel_even_when_config_says_nothing() {
  fixture; fake_claude
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main --ai -y')"
  assert_contains "$out" "AGENT-RAN" "--ai arms the channel on its own"
}


test_configured_session_arms_the_channel_without_the_flag() {
  fixture; fake_claude
  wt config set ai_session always >/dev/null
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main -y')"
  assert_contains "$out" "AGENT-RAN" "ai_session = always arms it with no flag"
}

# status uses the same "last stdout line is a directory -> cd" contract as create/cd/remove.
# The real CLI only prints a path after an fzf selection, so a stand-in binary plays that part
# and reports the mode: zsh_i's top level has a pipe on stdout, so redirected.
test_status_output_last_line_is_a_cd_target() {
  fixture
  mkdir -p "$HOME/fakebin" "$HOME/target"
  cat > "$HOME/fakebin/wt-status" <<EOF
#!/bin/sh
echo "mode=[\${WORKYTREE_SHELL:-}]"
echo "$HOME/target"
EOF
  chmod +x "$HOME/fakebin/wt-status"
  local out
  out="$(zsh_i "WORKYTREE_BIN='$HOME/fakebin/wt-status'; wt status; print -r -- \"pwd=\$PWD\"")"
  assert_contains "$out" "mode=[redirected]"
  assert_contains "$out" "pwd=$HOME/target"
}

test_status_table_output_is_printed_without_cd() {
  fixture
  local out
  out="$(zsh_i "cd '$HOME'; wt status --offline --plain; print -r -- \"pwd=\$PWD\"")"
  assert_contains "$out" "REPO"
  assert_contains "$out" "pwd=$HOME"
}

# The cd follows `-o interactive`, not the wrapper mode: a subshell or a group whose output is
# piped or redirected is still a shell the user typed into, and `( wt cd x && make ) > log`
# must run make in x.
test_cd_follows_inside_subshells_and_piped_groups() {
  fixture
  wt create app fix A main -y >/dev/null 2>&1
  local w="$HOME/wts/app/fix/A"
  assert_eq "$(zsh_i 'cd ~; ( wt cd app fix A >/dev/null && pwd ); pwd')" "$w"$'\n'"$HOME" "( )"
  assert_eq "$(zsh_i 'cd ~; ( wt cd app fix A && pwd ) > o; tail -1 o; pwd')" "$w"$'\n'"$HOME" "( ) > file"
  assert_eq "$(zsh_i 'cd ~; { wt cd app fix A >/dev/null && pwd } | cat; pwd')" "$w"$'\n'"$HOME" "{ } | cat"
  assert_eq "$(zsh_i 'cd ~; ( wt cd app fix A && pwd ) | tail -1; pwd')" "$w"$'\n'"$HOME" "( ) | pipe"
}

test_create_on_a_terminal_cds_and_announces_once() {
  fixture
  local out; local -a cd_lines
  out="$(pty_run 'wt create app fix A main -y 2>/dev/null; print -r -- "PWD=$PWD"')"
  cd_lines=( ${(M)${(f)out}:#*cd:*} )
  assert_contains "$out" "PWD=$HOME/wts/app/fix/A"
  assert_eq "${#cd_lines}" 1 "one cd: line"
}

# counting_install: a copy of the integration whose bin/workytree appends its first argument to
# $HOME/cli.calls before running the real CLI. $HOME/.zshenv sources it, as a user who moved
# the source line out of .zshrc would.
counting_install() {
  mkdir -p "$HOME/inst/shell" "$HOME/inst/bin"
  cp "$SHELL_FILE" "$HOME/inst/shell/workytree.zsh"
  print -r -- "#!/bin/sh
echo \"\$1\" >> '$HOME/cli.calls'
exec '$WT_BIN' \"\$@\"" > "$HOME/inst/bin/workytree"
  chmod +x "$HOME/inst/bin/workytree"
  print -r -- "source '$HOME/inst/shell/workytree.zsh'" > "$HOME/.zshenv"
}

test_sourcing_runs_the_cli_once_in_interactive_shells_and_never_otherwise() {
  fixture; counting_install
  assert_eq "$(ZDOTDIR="$HOME" zsh -d -c 'whence -w wt' 2>&1)" "wt: function" "non-interactive still gets wt"
  assert_not_exists "$HOME/cli.calls"
  ZDOTDIR="$HOME" zsh -d -i -c true >/dev/null 2>&1
  assert_eq "$(<"$HOME/cli.calls")" "__shell-init"
  assert_eq "$(WORKYTREE_ALIAS=0 ZDOTDIR="$HOME" zsh -d -c 'whence -w wt' 2>&1)" "wt: none"
}

test_broken_config_at_startup_prints_one_line_and_no_alias_advice() {
  write_config <<'EOF'
kinds = a
kinds = b
EOF
  print -r -- "alias wt='echo mine'; source '$SHELL_FILE'" > "$HOME/.zshrc"
  assert_eq "$(ZDOTDIR="$HOME" zsh -d -i -c wt 2>&1)" \
    "workytree: config has errors; run 'workytree list' to see them"$'\n'"mine"
}

# K1: inside $(...) or a pipe the caller gets the bare path, never the "cd:" announcement.
test_capture_and_pipes_get_the_bare_path() {
  fixture
  wt create app fix A main -y >/dev/null 2>&1
  assert_eq "$(zsh_i 'x=$(wt cd app fix A); print -r -- "[$x]"')" "[$HOME/wts/app/fix/A]"
  assert_eq "$(zsh_i 'wt create app fix B main -y 2>/dev/null | tail -1')" "$HOME/wts/app/fix/B"
}

test_terminal_cd_line_honours_no_color_and_dumb_terminals() {
  fixture
  wt create app fix A main -y >/dev/null 2>&1
  local w="$HOME/wts/app/fix/A" out
  assert_contains "$(pty_run 'wt cd app fix A')" $'\e[38;5;70mcd:\e[0m '"$w"
  out="$(pty_run 'NO_COLOR=1 wt cd app fix A; wt --no-color cd app fix A; TERM=dumb wt cd app fix A')"
  assert_eq "$out" "cd: $w"$'\n'"cd: $w"$'\n'"cd: $w"
}

test_wrapper_survives_caller_options_and_odd_ticket_names() {
  fixture
  local code
  code="$(cat <<'EOF'
export NO_COLOR=1
setopt ksh_arrays sh_word_split posix_traps prompt_subst
wt create app fix '50%d' main -y 2>/dev/null
wt create app fix 'U$(id>PWNED)' main -y 2>/dev/null
print -r -- "PWD=$PWD"
wt cd app >/dev/null; print -r -- "PWD=$PWD"
EOF
)"
  local out; out="$(pty_run "$code")"
  assert_contains "$out" "cd: $HOME/wts/app/fix/50%d"
  assert_contains "$out" "cd: $HOME/wts/app/fix/U\$(id>PWNED)"
  assert_contains "$out" "PWD=$HOME/wts/app/fix/U\$(id>PWNED)"
  assert_contains "$out" "PWD=$HOME/src/app"
  assert_not_exists "$HOME/wts/app/fix/U\$(id>PWNED)/PWNED"
}

test_failure_replays_every_line_and_keeps_the_exit_code() {
  fixture
  mkdir -p "$HOME/src/app/.git/refs/heads/fix"; : > "$HOME/src/app/.git/refs/heads/fix/EX.lock"
  assert_contains "$(zsh_i 'cd ~; wt create app fix EX main -y 2>/dev/null; print rc=$?; pwd')" \
    "base ref: main"$'\n'"rc=1"$'\n'"$HOME"
}

# Claude Code's shell snapshot keeps workytree() and wt() but drops `_`-prefixed helpers and
# plain globals such as WORKYTREE_BIN.
test_wrapper_works_from_a_shell_snapshot() {
  fixture
  zsh -f -c "source '$SHELL_FILE'; typeset -f workytree wt" > "$HOME/snap.zsh"
  mkdir -p "$HOME/pbin"; ln -s "$WT_BIN" "$HOME/pbin/workytree"
  local out
  out="$(PATH="$HOME/pbin:$PATH" zsh -f -c "source '$HOME/snap.zsh'; wt --version; print rc=\$?; wt path app" 2>&1)"
  assert_contains "$out" "workytree 0."
  assert_contains "$out" "rc=0"
  assert_contains "$out" "$HOME/src/app"
  out="$(zsh -f -c "source '$HOME/snap.zsh'; path=(/usr/bin /bin); wt --version; print rc=\$?" 2>&1)"
  assert_contains "$out" "workytree: not found on PATH"
  assert_contains "$out" "rc=127"
}

# stand_in <body>: a fake bin/workytree for the wrapper to call; WORKYTREE_BIN points at it.
stand_in() {
  print -r -- "#!/bin/sh
$1" > "$HOME/stand-in"
  chmod +x "$HOME/stand-in"
}

# The mode is what the CLI decides ownership from (WT_CAN_CD, the K3 warning, fzf); the bare
# path in a capture alone cannot tell captured from redirected.
test_wrapper_sends_one_mode_per_context() {
  fixture
  stand_in 'echo "mode=$WORKYTREE_SHELL" >&2; echo "$HOME"'
  local code out
  local -a modes
  code="$(cat <<EOF
WORKYTREE_BIN=$HOME/stand-in
wt cd x
x=\$(wt cd x)
wt cd x | cat
wt cd x > /dev/null
( wt cd x ) > /dev/null
zsh -f -c "source '$SHELL_FILE'; WORKYTREE_BIN=$HOME/stand-in; wt cd x"
EOF
)"
  out="$(pty_run "$code")"
  modes=( ${(M)${(f)out}:#mode=*} )
  assert_eq "$modes" "mode=terminal mode=captured mode=captured mode=redirected mode=captured mode=script"
}

test_ctrl_c_removes_the_runfile_and_keeps_the_users_exit_trap() {
  fixture
  stand_in 'echo STARTED >&2; sleep 30'
  pty_start
  pty_send "setopt posix_traps; trap 'print USER-EXIT-TRAP' EXIT; WORKYTREE_BIN=$HOME/stand-in"$'\n'
  pty_send $'wt create app fix X --ai -y\n'
  pty_wait STARTED
  pty_send $'\x03'
  sleep 0.5
  pty_send $'print -r -- "RUNFILES=$(ls "$TMPDIR" | grep -c "^workytree-ai\\.")"; exit\n'
  pty_finish
  assert_contains "$WT_PTY_OUT" "RUNFILES=0"
  assert_contains "$WT_PTY_OUT" "USER-EXIT-TRAP"
}

test_ctrl_c_after_the_cwd_was_deleted_lands_in_an_existing_directory() {
  fixture
  mkdir -p "$HOME/wts/app/fix/GONE"
  stand_in 'rm -rf "$PWD"; echo REMOVED >&2; sleep 30'
  pty_start
  pty_send "WORKYTREE_BIN=$HOME/stand-in; cd ~/wts/app/fix/GONE"$'\n'
  pty_send $'wt remove app fix GONE -y\n'
  pty_wait REMOVED
  pty_send $'\x03'
  sleep 0.5
  pty_send $'print -r -- "NOW=$PWD"; exit\n'
  pty_finish
  assert_contains "$WT_PTY_OUT" "workytree: your shell's directory was removed; moved to $HOME/wts/app/fix"
  assert_contains "$WT_PTY_OUT" "NOW=$HOME/wts/app/fix"
}

test_cd_to_a_missing_worktree_fails_and_stays_put() {
  fixture
  local out; out="$(zsh_i 'cd ~; wt cd app fix NOPE && touch m; print rc=$?; pwd')"
  assert_contains "$out" "workytree: not found: $HOME/wts/app/fix/NOPE"
  assert_contains "$out" "rc=1"$'\n'"$HOME"
  assert_not_exists "$HOME/m"
}

run_tests

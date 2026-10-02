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

# R23/Finding 4: `cmd_cd` is currently a literal alias for `cmd_path` (lib/cmd/path.zsh),
# so testing through the real CLI cannot distinguish "the wrapper translated cd -> path" from
# "it didn't bother, and cd/path happen to produce the same output anyway". Stub out
# $WORKYTREE_BIN with a spy that records its own $1 so the wrapper's translation is verified
# directly, independent of that CLI coincidence.
test_cd_translates_to_path_subcommand() {
  fixture
  local stub="$TMP_ROOT/stub-workytree" log="$TMP_ROOT/stub.log"
  cat > "$stub" <<'SCRIPT'
#!/usr/bin/env zsh
print -r -- "$1" > "$WT_STUB_LOG"
print -r -- "/stub/target/path"
SCRIPT
  chmod +x "$stub"
  zsh -c "
    export WT_STUB_LOG='$log'
    source '$SHELL_FILE'
    WORKYTREE_BIN='$stub'
    workytree cd app fix T >/dev/null
  "
  assert_eq "$(cat "$log")" "path"
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
  # Two separate checks, not one "cd: $target" substring: `print -P "%F{70}cd:%f $target"`
  # puts a color-reset escape between "cd:" and the space+path, so the literal adjacent
  # string only appears when the terminal is reported as colorless. Checking "cd:" and the
  # path independently verifies the ordinary auto-cd still ran without depending on that.
  assert_contains "$out" "cd:"
  assert_contains "$out" "$HOME/wts/app/fix/PROJ-1"
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

# The wrapper decides whether to arm the channel by scanning the command line for --ai, and
# that scan has to agree with the CLI's own parsing or the two disagree about whether this run
# opted in. `--` ends option parsing for create (lib/cmd/create.zsh), so a literal --ai after
# it is a repo name, not the flag.
#
# This exercises the scan directly rather than through a real `create`: a create whose repo
# name is `--ai` fails before `git worktree add` ever runs, so the post-checkout probe used
# above would have nothing to observe and would pass no matter what the wrapper decided.
test_ai_flag_scan_matches_the_cli_parsing() {
  fixture
  local out
  out="$(zsh_i '
    for a in "create app fix PROJ-1" "create --ai app fix" "create app fix PROJ-1 --ai" "create -- --ai fix" "create --ai -- x"; do
      _workytree_has_ai_flag ${=a} && print "$a -> ARMED" || print "$a -> NOT-ARMED"
    done')"
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

run_tests

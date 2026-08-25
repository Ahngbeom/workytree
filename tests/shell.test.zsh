#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"
SHELL_FILE="$WT_TEST_ROOT/shell/workytree.zsh"

# zsh_i <code>: run in an interactive zsh with an isolated ZDOTDIR that sources the integration
zsh_i() {
  export ZDOTDIR="$HOME"
  print -r -- "source '$SHELL_FILE'" > "$ZDOTDIR/.zshrc"
  zsh -i -c "$1" 2>&1
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
  local out; out="$(ZDOTDIR="$HOME" zsh -i -c 'wt' 2>&1)"
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
  local out; out="$(ZDOTDIR="$HOME" zsh -i -c 'wt' 2>&1)"
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
  local out; out="$(ZDOTDIR="$HOME" zsh -i -c 'wt' 2>&1)"
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

test_create_cds_into_worktree() {
  fixture
  # >/dev/null 2>&1 (not just >/dev/null): `git worktree add` writes its "Preparing
  # worktree..." progress line to STDERR, and zsh_i merges the whole session's stderr into
  # its capture (2>&1) -- an unsuppressed stderr here would leak into the `pwd` capture below.
  assert_eq "$(zsh_i 'wt create app fix T main -y >/dev/null 2>&1; pwd')" "$HOME/wts/app/fix/T"
  assert_eq "$(zsh_i 'wt cd app fix T >/dev/null; pwd')" "$HOME/wts/app/fix/T"
  assert_eq "$(zsh_i 'wt cd app >/dev/null; pwd')" "$HOME/src/app"
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

run_tests

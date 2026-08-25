#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

# config_unset and config_remove_section have no CLI surface (cmd_config only exposes
# path|get|set|edit, and the brief doesn't ask for more) so they're reached the same way the
# rest of the suite reaches library internals it doesn't have a command for: source the module
# directly and call the functions in-process. lib/config.zsh guards its own extendedglob-dependent
# patterns internally (setopt localoptions extendedglob per function), so this test file
# deliberately does NOT set extendedglob itself — that absence is what proves the module is
# self-sufficient rather than relying on the caller's option state.
source "$WT_TEST_ROOT/lib/ui.zsh"
source "$WT_TEST_ROOT/lib/config.zsh"

test_config_path_honors_xdg() {
  assert_eq "$(wt config path)" "$XDG_CONFIG_HOME/workytree/config"
  WORKYTREE_CONFIG=/x/y wt config path | read -r p; assert_eq "$p" "/x/y"
}

test_get_reads_global_project_repo_keys() {
  write_config <<'EOF'
# top comment
default_project = fd   # trailing comment
kinds = feature,fix

[project fd]
repo_root     = ~/products
worktree_root = ~/wts

[repo backend]
path = ~/src/api
project = fd
EOF
  assert_eq "$(wt config get default_project)" "fd"
  assert_eq "$(wt config get kinds)" "feature,fix"
  assert_eq "$(wt config get project.fd.repo_root)" "$HOME/products"
  assert_eq "$(wt config get repo.backend.project)" "fd"
  assert_exit 1 wt config get project.fd.nope
}

test_set_replaces_in_place_and_preserves_comments() {
  write_config <<'EOF'
# keep me
default_project = fd

[project fd]
repo_root = ~/a
worktree_root = ~/b
EOF
  wt config set project.fd.worktree_root ~/c
  wt config set default_project other
  local f="$XDG_CONFIG_HOME/workytree/config"
  assert_contains "$(cat "$f")" "# keep me"
  assert_eq "$(grep -c 'worktree_root' "$f")" "1"
  assert_eq "$(wt config get project.fd.worktree_root)" "$HOME/c"
  assert_eq "$(wt config get default_project)" "other"
}

test_set_appends_missing_key_and_section() {
  write_config <<'EOF'
[project fd]
repo_root = ~/a
EOF
  wt config set project.fd.worktree_root ~/b
  wt config set project.new.repo_root ~/n
  wt config set alias_wt false
  local f="$XDG_CONFIG_HOME/workytree/config"
  assert_eq "$(wt config get project.fd.worktree_root)" "$HOME/b"
  assert_eq "$(wt config get project.new.repo_root)" "$HOME/n"
  assert_eq "$(wt config get alias_wt)" "false"
  # global key must land before the first section header
  assert_eq "$(head -1 "$f")" "alias_wt = false"
}

test_set_creates_file_when_missing() {
  wt config set default_project fd
  assert_eq "$(wt config get default_project)" "fd"
}

test_parse_error_reports_line() {
  write_config <<'EOF'
default_project = fd
this is not valid
EOF
  local out; out="$(wt config get default_project 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "config:2"
}

test_duplicate_project_is_error() {
  write_config <<'EOF'
[project a]
repo_root = ~/x
worktree_root = ~/y
[project a]
repo_root = ~/z
worktree_root = ~/w
EOF
  assert_exit 1 wt config get default_project
}

test_unset_removes_key_preserves_rest_of_file() {
  write_config <<'EOF'
# keep me
default_project = fd
kinds = feature,fix

[project fd]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  config_unset kinds
  config_unset project.fd.repo_root
  local f="$XDG_CONFIG_HOME/workytree/config"
  assert_eq "$(sed -n '1p' "$f")" "# keep me"
  assert_eq "$(sed -n '2p' "$f")" "default_project = fd"
  assert_eq "$(wt config get default_project)" "fd"
  assert_eq "$(wt config get project.fd.worktree_root)" "$HOME/b"
  assert_exit 1 wt config get kinds
  assert_exit 1 wt config get project.fd.repo_root
  assert_eq "$(grep -c '^kinds' "$f")" "0"
  assert_eq "$(grep -c 'repo_root' "$f")" "0"
}

test_unset_missing_key_is_noop() {
  write_config <<'EOF'
default_project = fd

[project fd]
repo_root = ~/a
EOF
  local f="$XDG_CONFIG_HOME/workytree/config"
  local before; before="$(cat "$f")"
  config_load
  config_unset project.fd.nope
  config_unset does_not_exist
  assert_eq "$(cat "$f")" "$before"
  assert_eq "$(wt config get default_project)" "fd"
  assert_eq "$(wt config get project.fd.repo_root)" "$HOME/a"
}

test_remove_section_middle_preserves_following() {
  write_config <<'EOF'
[project fd]
repo_root = ~/a

[project other]
repo_root = ~/x
worktree_root = ~/y

[repo backend]
path = ~/src/api
project = other
EOF
  config_load
  config_remove_section project fd
  assert_eq "$(wt config get project.other.repo_root)" "$HOME/x"
  assert_eq "$(wt config get project.other.worktree_root)" "$HOME/y"
  assert_eq "$(wt config get repo.backend.path)" "$HOME/src/api"
  assert_exit 1 wt config get project.fd.repo_root
}

test_remove_section_last_in_file() {
  write_config <<'EOF'
[project fd]
repo_root = ~/a

[project other]
repo_root = ~/x
EOF
  config_load
  config_remove_section project other
  assert_eq "$(wt config get project.fd.repo_root)" "$HOME/a"
  assert_exit 1 wt config get project.other.repo_root
}

test_remove_only_section_in_file() {
  write_config <<'EOF'
default_project = fd

[project fd]
repo_root = ~/a
EOF
  config_load
  config_remove_section project fd
  assert_eq "$(wt config get default_project)" "fd"
  assert_exit 1 wt config get project.fd.repo_root
}

test_duplicate_key_in_section_is_error() {
  write_config <<'EOF'
[project fd]
repo_root = ~/a
repo_root = ~/b
EOF
  local out; out="$(wt config get project.fd.repo_root 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "config:3"
}

test_duplicate_global_key_is_error() {
  write_config <<'EOF'
default_project = fd
default_project = other
EOF
  local out; out="$(wt config get default_project 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "config:2"
}

# Regression for the expand_path infinite-loop bug: a self-referential env var must resolve in
# one pass, not hang. Guarded with a timeout so a regression here cannot hang the whole suite.
test_expand_path_self_reference_does_not_hang() {
  local script="$WT_TEST_ROOT/lib/config.zsh"
  local cmd="source '$script'; SELFREF='\$SELFREF' expand_path '\$SELFREF'"
  local out rc
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout 3 zsh -c "$cmd" 2>&1)"; rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    out="$(gtimeout 3 zsh -c "$cmd" 2>&1)"; rc=$?
  else
    # No timeout(1)/gtimeout(1) on this machine: bound it ourselves rather than skip the test.
    local outfile; outfile="$(mktemp)"
    ( zsh -c "$cmd" > "$outfile" 2>&1 ) &
    local pid=$!
    local -i i=0
    while (( i < 30 )) && kill -0 "$pid" 2>/dev/null; do sleep 0.1; (( i++ )); done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=124
    else
      wait "$pid"; rc=$?
    fi
    out="$(cat "$outfile")"; rm -f "$outfile"
  fi
  assert_eq "$rc" "0" "expand_path self-reference should return promptly, not hang"
  assert_eq "$out" '$SELFREF'
}

# R38 (fix round 1 of Task 11): a config that fails to PARSE (duplicate key/section, an
# unparseable line) must not die() inside config_load() -- bin/workytree's main() calls
# config_load() before ANY command, including __complete, ever gets control, so a die()
# there would kill Tab completion (and `config path`/`config edit`, the very commands that
# could repair the file) on every keystroke against a broken config. config_load() instead
# records the failure in WT_CONFIG_LOAD_ERROR and resets every array to empty;
# require_config and `config get`/`set` must surface it loudly (same message, same
# "config:N"), while __complete/`config path`/`config edit`/help/--version must keep
# working. R23: a passing exit-code assertion alone would not catch a consumer that
# silently treats a broken config as an absent one (the exact defect this fix addresses --
# `config get` on an empty WT_CFG also exits 1, just with the WRONG message), so every
# "must surface loudly" case below asserts on the "config:N" message text too, not only the
# exit code.
_broken_config() {
  write_config <<'EOF'
kinds = a
kinds = b
EOF
}

test_broken_config_complete_is_silent() {
  _broken_config
  local errfile; errfile="$(mktemp)"
  local out; out="$(wt __complete commands 2>"$errfile")"
  assert_eq "$?" "0"
  assert_contains "$out" "create"
  assert_eq "$(cat "$errfile")" ""

  out="$(wt __complete repos 2>"$errfile")"
  assert_eq "$?" "0"
  assert_eq "$out" ""
  assert_eq "$(cat "$errfile")" ""
  rm -f "$errfile"
}

test_broken_config_path_and_edit_still_work() {
  _broken_config
  assert_eq "$(wt config path)" "$XDG_CONFIG_HOME/workytree/config"
  local out; out="$(EDITOR=cat wt config edit)"
  assert_eq "$?" "0"
  assert_eq "$out" $'kinds = a\nkinds = b'
}

test_broken_config_help_and_version_still_work() {
  _broken_config
  assert_exit 0 wt help
  assert_contains "$(wt --version)" "workytree"
}

test_broken_config_require_config_command_exits_3_with_message() {
  _broken_config
  local out; out="$(wt list 2>&1)"
  assert_eq "$?" "3"
  assert_contains "$out" "config:2"
}

test_broken_config_get_and_set_exit_1_with_message() {
  _broken_config
  local out; out="$(wt config get kinds 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$out" "config:2"

  out="$(wt config set foo bar 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$out" "config:2"
}

test_broken_config_init_still_refuses() {
  _broken_config
  local out; out="$(wt init x ~/a ~/b 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$out" "config already exists"
}

# R39 (fix round 2 of Task 11): `project list`/`remove`/`default` and `repo list`/`remove`
# read WT_PROJECTS/WT_PCFG/WT_CFG/WT_REPOS/WT_RCFG directly, calling neither require_config
# nor (before this fix) any recorded-failure check -- against a broken config they fell
# through to their own "no projects"/"no repos registered" empty-state messages, silently
# telling the user their configuration was EMPTY when it was actually UNREADABLE. Exit code
# 3 (not 1): a parse failure describes the state of the config FILE, the same category
# require_config's own checks already use exit 3 for -- these commands are peers of the
# require_config-gated commands (they query/mutate the same config-derived project/repo
# universe), not peers of `config get`/`set` (whose exit 1 only preserves that ONE
# subcommand's own pre-existing "key not found" exit code, per R38's own reasoning).
test_broken_config_project_and_repo_commands_exit_3_with_message() {
  _broken_config
  local out
  out="$(wt project list 2>&1)";      assert_eq "$?" "3"; assert_contains "$out" "config:2"
  out="$(wt project remove x 2>&1)";  assert_eq "$?" "3"; assert_contains "$out" "config:2"
  out="$(wt project default x 2>&1)"; assert_eq "$?" "3"; assert_contains "$out" "config:2"
  out="$(wt repo list 2>&1)";         assert_eq "$?" "3"; assert_contains "$out" "config:2"
  out="$(wt repo remove x 2>&1)";     assert_eq "$?" "3"; assert_contains "$out" "config:2"
}

# `project add` reaches the SAME require_loadable_config guard (it needs to read existing
# WT_PROJECTS/WT_PCFG for its own dangling-default-project repair logic), but must still
# work with NO config file at all -- that bootstrap case is exactly how the first config
# gets created, and R39 must not break it.
test_project_add_still_bootstraps_with_no_config_at_all() {
  assert_exit 0 wt project add me ~/src ~/wts
}

run_tests

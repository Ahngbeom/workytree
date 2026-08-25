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

run_tests

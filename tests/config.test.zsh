#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

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

run_tests

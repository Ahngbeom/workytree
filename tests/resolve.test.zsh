#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

# Two projects: fd (nested product/layer/repo layout) and me (flat)
fixture() {
  make_repo "$HOME/fd/products/acme/backend/server"
  make_repo "$HOME/fd/products/acme/frontend/front"
  make_repo "$HOME/me/src/blog"
  make_repo "$HOME/elsewhere/legacy-api"
  write_config <<EOF
default_project = fd
[project fd]
repo_root = ~/fd/products
worktree_root = ~/fd/wts
scan_depth = 4
[project me]
repo_root = ~/me/src
worktree_root = ~/me/wts
[repo api]
path = ~/elsewhere/legacy-api
project = me
EOF
}

test_missing_config_exits_3() {
  assert_exit 3 wt repos
  assert_contains "$(wt repos 2>&1)" "workytree init"
}

test_repos_lists_registered_then_scanned() {
  fixture
  local out; out="$(wt repos)"
  assert_contains "$out" "api"
  assert_contains "$out" "server"
  assert_contains "$out" "blog"
  assert_eq "$(wt repos | wc -l | tr -d ' ')" "4"
  assert_eq "$(wt repos | head -1 | cut -f1)" "api"
}

test_scan_depth_limits_discovery() {
  fixture
  wt config set project.fd.scan_depth 1 >/dev/null
  local out; out="$(wt repos)"
  assert_eq "${out//server/}" "$out" "server must not be found at depth 1"
}

test_path_resolves_registered_and_scanned() {
  fixture
  assert_eq "$(wt path api)" "$HOME/elsewhere/legacy-api"
  assert_eq "$(wt path server)" "$HOME/fd/products/acme/backend/server"
  assert_eq "$(wt path server fix)" "$HOME/fd/wts/server/fix"
  assert_eq "$(wt path server fix PROJ-1)" "$HOME/fd/wts/server/fix/PROJ-1"
  assert_eq "$(wt path api fix PROJ-1)" "$HOME/me/wts/api/fix/PROJ-1"
}

test_ambiguous_name_needs_project() {
  fixture
  make_repo "$HOME/me/src/server"
  local out; out="$(wt path server 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "ambiguous"
  assert_contains "$out" "--project"
  assert_eq "$(wt path server --project me)" "$HOME/me/src/server"
}

test_unknown_repo_and_project() {
  fixture
  assert_exit 1 wt path nope
  assert_exit 1 wt path server --project ghost
}

test_path_without_args_infers_from_cwd() {
  fixture
  cd "$HOME/fd/products/acme/backend/server"
  assert_eq "$(wt path)" "$HOME/fd/products/acme/backend/server"
  cd "$HOME"
  assert_exit 1 wt path
}

test_list_shows_worktrees() {
  fixture
  assert_contains "$(wt list server)" "$HOME/fd/products/acme/backend/server"
  assert_contains "$(wt list)" "repo: blog"
}

run_tests

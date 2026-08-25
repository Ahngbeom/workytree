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

# Two projects whose repo_roots overlap: outer's repo_root contains inner's repo_root, and
# both reach the SAME physical repo. R18: the project with the longest matching repo_root
# prefix (inner) wins, and `repos`/`path` must agree on that -- never two different answers
# from the same config.
fixture_nested() {
  make_repo "$HOME/fd/products/backend/server"
  write_config <<EOF
default_project = outer
[project outer]
repo_root = ~/fd/products
worktree_root = ~/fd/wts-outer
[project inner]
repo_root = ~/fd/products/backend
worktree_root = ~/fd/wts-inner
EOF
}

test_nested_repo_roots_collapse_to_most_specific_project() {
  fixture_nested
  # repos and path must not disagree: exactly one row, naming the more specific project.
  assert_eq "$(wt repos | wc -l | tr -d ' ')" "1"
  assert_eq "$(wt repos | cut -f2)" "inner"
  assert_eq "$(wt path server)" "$HOME/fd/products/backend/server"
  assert_eq "$(wt path server fix PROJ-1)" "$HOME/fd/wts-inner/server/fix/PROJ-1"
}

test_nested_repo_roots_project_flag_overrides_specificity() {
  fixture_nested
  assert_eq "$(wt path server fix PROJ-1 --project outer)" "$HOME/fd/wts-outer/server/fix/PROJ-1"
  assert_eq "$(wt path server fix PROJ-1 --project inner)" "$HOME/fd/wts-inner/server/fix/PROJ-1"
}

test_nested_roots_do_not_mask_genuine_ambiguity() {
  fixture_nested
  make_repo "$HOME/me/src/server"
  write_config <<EOF
default_project = outer
[project outer]
repo_root = ~/fd/products
worktree_root = ~/fd/wts-outer
[project inner]
repo_root = ~/fd/products/backend
worktree_root = ~/fd/wts-inner
[project me]
repo_root = ~/me/src
worktree_root = ~/me/wts
EOF
  # outer+inner collapse to one physical repo ("inner"); "me" names a genuinely different
  # physical repo -- that must still be a hard ambiguity error, not silently resolved.
  assert_eq "$(wt repos | wc -l | tr -d ' ')" "2"
  local out; out="$(wt path server 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "ambiguous"
  assert_contains "$out" "inner"
  assert_contains "$out" "me"
  assert_eq "${out//outer/}" "$out" "outer must have collapsed into inner, not survived as a third candidate"
}

# R19: cmd_path's zero-arg branch must never leak git's raw, unprefixed error / exit 128 when
# infer_current_repo succeeds (cwd is known) but there is no working tree to show a toplevel
# for -- inside a bare repo, or inside a .git/ directory itself.
test_path_from_dotgit_or_bare_repo_errors_cleanly() {
  fixture
  cd "$HOME/fd/products/acme/backend/server/.git"
  local out; out="$(wt path 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "workytree: "
  assert_contains "$out" "work tree"

  git init -q --bare "$HOME/fd/products/acme/backend/bare.git"
  cd "$HOME/fd/products/acme/backend/bare.git"
  out="$(wt path 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "workytree: "
  assert_contains "$out" "work tree"
}

run_tests

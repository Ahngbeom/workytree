#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

test_version_prints_semver() {
  local out; out="$(wt --version)"
  assert_eq "$?" 0
  assert_contains "$out" "workytree 0."
}

test_help_exits_zero() {
  assert_exit 0 wt help
  assert_exit 0 wt --help
  assert_contains "$(wt help)" "workytree create"
}

test_no_args_is_usage_error() { assert_exit 2 wt; }

test_unknown_command_is_usage_error() {
  assert_exit 2 wt bogus
  assert_contains "$(wt bogus 2>&1)" "workytree: unknown command: bogus"
}

test_global_options_are_accepted_anywhere() {
  # --no-color / -y / --project are consumed before dispatch; help still works after them
  assert_exit 0 wt --no-color help
  assert_exit 0 wt help -y --project x
}

# hostile_zshenv: a ZDOTDIR whose .zshenv flips options, aliases mv, shadows git with a
# function and announces itself. bin/workytree must read none of it.
hostile_zshenv() {
  mkdir -p "$HOME/zdot"
  cat > "$HOME/zdot/.zshenv" <<'EOF'
print -u2 ZSHENV-RAN
setopt err_exit no_clobber ksh_arrays
alias mv='mv -i'
git() { print -u2 GIT-FUNCTION-RAN; command git "$@"; }
EOF
  export ZDOTDIR="$HOME/zdot"
}

test_cli_ignores_the_users_zshenv() {
  make_repo "$HOME/src/app"
  write_config <<'EOF'
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  hostile_zshenv
  local rc
  wt --version >/dev/null 2>"$HOME/err"; rc=$?
  assert_eq "$rc" 0 "--version under err_exit"
  wt config set stale_days 9 >/dev/null 2>>"$HOME/err"
  assert_eq "$(wt config get stale_days 2>>"$HOME/err")" 9 "config set under noclobber"
  wt create app fix Z main -y >/dev/null 2>>"$HOME/err"
  wt remove app fix Z -y >/dev/null 2>>"$HOME/err"; rc=$?
  assert_eq "$rc" 0 "remove under noclobber"
  assert_not_exists "$HOME/wts/app/fix/Z"
  assert_eq "$(grep -c -e ZSHENV-RAN -e GIT-FUNCTION-RAN "$HOME/err")" 0 "no .zshenv code ran"
  unset ZDOTDIR
}

test_shell_init_reports_ai_alias_and_config_state() {
  assert_eq "$(wt __shell-init 2>&1)" "ai=0 alias=1 config=ok" "no config file"
  write_config <<'EOF'
ai_session = ask
alias_wt = false
EOF
  assert_eq "$(wt __shell-init 2>&1)" "ai=1 alias=0 config=ok"
  print 'ai_session = off' >> "$XDG_CONFIG_HOME/workytree/config"
  local out rc
  out="$(wt __shell-init 2>&1)"; rc=$?
  assert_eq "$rc" 0
  assert_eq "$out" "ai=0 alias=1 config=error" "a broken config reads as defaults, and says so"
}

test_wrapper_protocol_never_reaches_git_hooks() {
  make_repo "$HOME/src/app"
  write_config <<'EOF'
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  printf '#!/bin/sh\necho "hook sees [${WORKYTREE_SHELL-}${WT_SHELL-}${WORKYTREE_AI_SKIP-}${WT_AI_SKIP-}]" >&2\n' \
    > "$HOME/src/app/.git/hooks/post-checkout"
  chmod +x "$HOME/src/app/.git/hooks/post-checkout"
  assert_contains "$(WORKYTREE_SHELL=terminal WORKYTREE_AI_SKIP=stdin wt create app fix H main -y 2>&1)" "hook sees []"
}
run_tests

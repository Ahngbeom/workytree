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
  assert_eq "$?" 3
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
  local out; out="$(wt config get default_project 2>&1)"
  assert_eq "$?" 3
  assert_contains "$out" "config:4"
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
  assert_eq "$?" 3
  assert_contains "$out" "config:3"
}

test_duplicate_global_key_is_error() {
  write_config <<'EOF'
default_project = fd
default_project = other
EOF
  local out; out="$(wt config get default_project 2>&1)"
  assert_eq "$?" 3
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

# R44 (fix round 5): 3, not the 1 R38 chose. Exit 1 from `config get` now means exactly one
# thing -- the key is not set -- so the assertion below pairs the code with the message the
# same way every other config-state test does. The companion assertion for the OTHER meaning
# of 1 lives in test_config_get_unset_key_on_valid_config_is_exit_1 below: without it,
# collapsing both meanings onto one code would still pass this test.
test_broken_config_get_and_set_exit_3_with_message() {
  _broken_config
  local out; out="$(wt config get kinds 2>&1)"
  assert_eq "$?" "3"
  assert_contains "$out" "config:2"

  out="$(wt config set foo bar 2>&1)"
  assert_eq "$?" "3"
  assert_contains "$out" "config:2"
}

# The other half of R44: on a VALID config, a genuinely unset key is still exit 1, and its
# message is `config get`'s own "config key not set", never a config:N load error. The two
# tests together pin that 1 and 3 mean different things through the same subcommand.
test_config_get_unset_key_on_valid_config_is_exit_1() {
  write_config <<'EOF'
default_project = fd

[project fd]
repo_root = ~/a
worktree_root = ~/b
EOF
  local out; out="$(wt config get nosuchkey 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$out" "config key not set: nosuchkey"
  [[ "$out" == *"config:"[0-9]* ]] && { (( ++_fail )); print -u2 "  FAIL: unset key reported as a load error: $out"; print >> "$WT_FAIL_FILE" "FAIL: unset key reported as a load error"; } || (( ++_pass ))
}

# R41 (fix round 3): `init` against a config that failed to PARSE now names the SPECIFIC
# recorded failure (the same "config:N" message every other consumer surfaces), not the
# generic "config already exists" -- that generic text would be misleading here since no
# USABLE config, valid or otherwise, actually exists at this path yet.
test_broken_config_init_still_refuses() {
  _broken_config
  local out; out="$(wt init x ~/a ~/b 2>&1)"
  assert_eq "$?" "3"   # R44: was 1 (die); the same recorded load error every consumer exits 3 for
  assert_contains "$out" "config:2"
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

# R41 (fix round 3 of Task 11): config_load's classification of the config PATH, extended
# past "parses badly" (R38) to "cannot be read at all" or "is not a file at all". Shapes
# enumerated below; see the fix-round-3 report section for the full table including shapes
# that already worked (absent, empty, valid, duplicate key/section, unparseable line --
# covered by earlier tests in this file) and are not repeated here.

# Shape: present but UNREADABLE (chmod 000). Finding 1 -- previously bypassed the recorder
# entirely: `< "$WT_CONFIG_FILE"` failed at the shell level with its own raw diagnostic,
# WT_CONFIG_LOAD_ERROR stayed empty, and `config get` fell through to "key not set" (the
# coincidentally-right-exit-code trap R38 exists to prevent) while `list` blamed "no
# [project] defined" instead of the real permission problem.
test_unreadable_config_all_consumers() {
  _broken_config  # reused only for its directory/file setup; overwritten below
  write_config <<'EOF'
kinds = a
EOF
  local cfg="$XDG_CONFIG_HOME/workytree/config"
  chmod 000 "$cfg"
  local errfile; errfile="$(mktemp)"
  local out
  out="$(wt __complete commands 2>"$errfile")"
  assert_eq "$?" "0"; assert_contains "$out" "create"; assert_eq "$(cat "$errfile")" ""
  out="$(wt __complete repos 2>"$errfile")"
  assert_eq "$?" "0"; assert_eq "$out" ""; assert_eq "$(cat "$errfile")" ""
  rm -f "$errfile"

  out="$(wt config get kinds 2>&1)"
  assert_eq "$?" "3"; assert_contains "$out" "not readable"

  out="$(wt list 2>&1)"
  assert_eq "$?" "3"; assert_contains "$out" "not readable"

  assert_eq "$(wt config path)" "$cfg"
  assert_exit 0 wt help
  assert_contains "$(wt --version)" "workytree"

  out="$(wt init x ~/a ~/b 2>&1)"
  assert_eq "$?" "3"; assert_contains "$out" "not readable"

  chmod 644 "$cfg"  # must be readable/deletable again before setup_env's teardown rm -rf
}

# Shape: a DIRECTORY sitting at the config path. Finding 2 -- previously `init` proceeded
# past its own refusal (WT_CONFIG_EXISTS is file-existence-of-a-REGULAR-file, false for a
# directory), `_config_write` touch-created into it (raw "is a directory" diagnostic) and
# then `mv "$tmp" "$file"` SILENTLY SUCCEEDED (mv-into-a-directory is valid mv usage), so
# `init` reported success while writing nothing and leaving a stray temp file behind.
test_directory_at_config_path_all_consumers() {
  local cfg="$XDG_CONFIG_HOME/workytree/config"
  mkdir -p "$cfg"
  local out

  out="$(wt init x ~/a ~/b 2>&1)"
  assert_eq "$?" "3"
  assert_contains "$out" "not a regular file"
  assert_eq "$(print -l -- "$cfg"/*(N))" ""  # no stray temp file left inside

  local errfile; errfile="$(mktemp)"
  out="$(wt __complete commands 2>"$errfile")"
  assert_eq "$?" "0"; assert_contains "$out" "create"; assert_eq "$(cat "$errfile")" ""
  out="$(wt __complete repos 2>"$errfile")"
  assert_eq "$?" "0"; assert_eq "$out" ""; assert_eq "$(cat "$errfile")" ""
  rm -f "$errfile"

  out="$(wt config get kinds 2>&1)"
  assert_eq "$?" "3"; assert_contains "$out" "not a regular file"

  out="$(wt list 2>&1)"
  assert_eq "$?" "3"; assert_contains "$out" "not a regular file"

  assert_eq "$(wt config path)" "$cfg"

  # `config edit` must still exec an editor rather than fail on workytree's OWN attempt to
  # touch-create over the directory (R41: `-e`, not `-f`, guards that touch-create) --
  # whatever the editor itself then does with a directory target is between it and the
  # user, not a workytree-authored diagnostic.
  out="$(EDITOR=cat wt config edit 2>&1)"
  assert_contains "$out" "Is a directory"        # cat's own message: the editor was reached
  [[ "$out" == *"cmd_config:"* ]] && { (( ++_fail )); print -u2 "  FAIL: workytree's own raw diagnostic leaked: $out"; } || (( ++_pass ))
  assert_eq "$(print -l -- "$cfg"/*(N))" ""      # still no stray file created inside
}

# Shape: symlink to a VALID config -- must behave exactly like a normal file, and a write
# (config_set) must go THROUGH the link (this file's own header comment) rather than
# replacing it with a plain file.
test_symlink_to_valid_config_works_and_writes_through() {
  mkdir -p "$HOME/elsewhere" "$XDG_CONFIG_HOME/workytree"
  cat > "$HOME/elsewhere/realconfig" <<'EOF'
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  ln -s "$HOME/elsewhere/realconfig" "$XDG_CONFIG_HOME/workytree/config"
  assert_eq "$(wt __complete projects)" "me"
  assert_exit 0 wt config set default_project me
  assert_contains "$(cat "$HOME/elsewhere/realconfig")" "default_project = me"
  [[ -L "$XDG_CONFIG_HOME/workytree/config" ]] && (( ++_pass )) || { (( ++_fail )); print -u2 "  FAIL: symlink was replaced, not written through"; }
}

# Shape: symlink to a NONEXISTENT target (dangling). Treated the same as "absent" for
# reading -- there is no partial/corrupt content sitting at either to diagnose -- so a
# require_config command reports the ordinary "no config found" message (not a load-error),
# and `project add`/`config set` can still create the config by writing THROUGH the link.
test_dangling_symlink_treated_as_absent_and_writable_through() {
  mkdir -p "$XDG_CONFIG_HOME/workytree"
  ln -s "$HOME/does-not-exist-target" "$XDG_CONFIG_HOME/workytree/config"
  local out; out="$(wt list 2>&1)"
  assert_eq "$?" "3"
  assert_contains "$out" "no config found"
  assert_exit 0 wt project add me ~/src ~/wts
  assert_contains "$(cat "$HOME/does-not-exist-target")" "[project me]"
  [[ -L "$XDG_CONFIG_HOME/workytree/config" ]] && (( ++_pass )) || { (( ++_fail )); print -u2 "  FAIL: dangling symlink was replaced, not written through"; }
}

# Shape: config path whose PARENT directory does not exist yet. Already-correct behavior
# (`mkdir -p "${file:h}"` in _config_write) -- pinned explicitly since R41 restructured the
# write-target checks around it.
test_config_write_creates_missing_parent_directories() {
  export WORKYTREE_CONFIG="$HOME/nope/deeper/config"
  assert_exit 0 wt project add me ~/src ~/wts
  assert_contains "$(cat "$WORKYTREE_CONFIG")" "[project me]"
}

# _config_write's OWN refusal (R41), tested directly against the library function (no CLI
# surface reaches it independently of an upstream guard today -- every current caller
# already calls require_loadable_config/checks WT_CONFIG_LOAD_ERROR first, per R38/R39, so
# a `wt` subprocess test alone would only prove the UPSTREAM guard, not this one). Same
# in-process pattern this file's own header comment already establishes for
# config_unset/config_remove_section. die()'s `exit` inside `$(...)` only unwinds that
# command substitution's subshell, not this test process.
test_config_write_itself_refuses_directory_target_leaves_no_temp_file() {
  local dir="$XDG_CONFIG_HOME/workytree/config"
  mkdir -p "$dir"
  local out; out="$(config_set default_project x 2>&1)"
  # R42 (fix round 4): 3, not the 1 this asserted in round 3. A write that cannot proceed
  # because of the STATE of the config file or its location is the same category
  # require_loadable_config/require_config already exit 3 for on the read side -- nothing
  # about the user's arguments is wrong. See lib/config.zsh's _config_die_state.
  assert_eq "$?" "3"
  assert_contains "$out" "not a regular file"
  assert_eq "$(print -l -- "$dir"/*(N))" ""
}

# R42 (fix round 4 of Task 11): the config DIRECTORY read-only while the config FILE itself
# is writable (mode 644). The old guard checked `-w` on the FILE only, which is the wrong
# question for a temp-file-plus-rename write: `mktemp` failed ("mkstemp failed ...
# Permission denied"), `> "$tmp"` failed against the empty path it left behind ("no such
# file or directory"), `mv "" "$file"` failed ("mv: : No such file or directory") -- and
# because none of those three exit statuses was checked, `config set` printed
# "set default_project = me" and exited 0 over a file it had never touched.
#
# R23: exit code alone would not catch a regression here (plenty of failures exit non-zero),
# so every case asserts workytree's OWN wording -- "config directory is not writable (check
# permissions)" / "could not create the config file (check permissions)", both authored in
# lib/config.zsh and emitted by nothing else -- AND that the success message is absent AND
# that no raw shell diagnostic (mktemp's/mv's/zsh's own) leaked to stderr.
_assert_no_raw_shell_diagnostic() {
  local err="$1" what="$2" pat
  for pat in "mktemp:" "mv:" "mkstemp" "_config_write:" "_config_prepare_write_target:" \
             "config_remove_section:" "no such file or directory" "permission denied:"; do
    if [[ "$err" == *"$pat"* ]]; then
      (( ++_fail )); print -u2 "  FAIL: raw shell diagnostic [$pat] leaked from $what: $err"
      print >> "$WT_FAIL_FILE" "FAIL: raw shell diagnostic [$pat] leaked from $what: $err"
      return
    fi
  done
  (( ++_pass ))
}

test_readonly_config_directory_refuses_every_write_path() {
  make_repo "$HOME/src/app"
  write_config <<'EOF'
# keep me
kinds = feature,fix

[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  local dir="$XDG_CONFIG_HOME/workytree" cfg="$XDG_CONFIG_HOME/workytree/config"
  local before; before="$(cat "$cfg")"
  chmod 644 "$cfg"
  chmod 555 "$dir"

  local errfile; errfile="$(mktemp)"
  local out rc

  # config set -> _config_write
  out="$(wt config set default_project me 2>"$errfile")"; rc=$?
  assert_eq "$rc" "3" "config set on a read-only config directory"
  assert_eq "$out" "" "config set must print no success line"
  assert_contains "$(cat "$errfile")" "config directory is not writable"
  _assert_no_raw_shell_diagnostic "$(cat "$errfile")" "config set"

  # project add -> config_set
  out="$(wt project add two ~/src ~/wts 2>"$errfile")"; rc=$?
  assert_eq "$rc" "3" "project add on a read-only config directory"
  [[ "$out" == *"added project"* ]] && { (( ++_fail )); print -u2 "  FAIL: project add claimed success: $out"; print >> "$WT_FAIL_FILE" "FAIL: project add claimed success"; } || (( ++_pass ))
  assert_contains "$(cat "$errfile")" "config directory is not writable"
  _assert_no_raw_shell_diagnostic "$(cat "$errfile")" "project add"

  # repo add -> config_set
  out="$(wt repo add "$HOME/src/app" 2>"$errfile")"; rc=$?
  assert_eq "$rc" "3" "repo add on a read-only config directory"
  [[ "$out" == *"registered repo"* ]] && { (( ++_fail )); print -u2 "  FAIL: repo add claimed success: $out"; print >> "$WT_FAIL_FILE" "FAIL: repo add claimed success"; } || (( ++_pass ))
  assert_contains "$(cat "$errfile")" "config directory is not writable"
  _assert_no_raw_shell_diagnostic "$(cat "$errfile")" "repo add"

  # project default -> config_set
  out="$(wt project default me 2>"$errfile")"; rc=$?
  assert_eq "$rc" "3" "project default on a read-only config directory"
  assert_eq "$out" "" "project default must print no success line"
  assert_contains "$(cat "$errfile")" "config directory is not writable"

  # project remove -> config_remove_section (a DIFFERENT writer, same choke point)
  out="$(wt project remove me 2>"$errfile")"; rc=$?
  assert_eq "$rc" "3" "project remove on a read-only config directory"
  assert_eq "$out" "" "project remove must print no success line"
  assert_contains "$(cat "$errfile")" "config directory is not writable"
  _assert_no_raw_shell_diagnostic "$(cat "$errfile")" "project remove"

  # config_unset, reached in-process (no CLI surface -- this file's header comment)
  out="$(config_unset default_project 2>&1)"; rc=$?
  assert_eq "$rc" "3" "config_unset on a read-only config directory"
  assert_contains "$out" "config directory is not writable"

  rm -f "$errfile"
  assert_eq "$(cat "$cfg")" "$before" "the config file must be untouched"
  assert_eq "$(print -l -- "$dir"/*(N))" "$cfg" "no temp file left behind"
  chmod 755 "$dir"  # restore before teardown_env's rm -rf, and before any later run
}

# Same read-only directory, but with NO config file yet: the very first write must refuse
# at the create step rather than report a config it could not write.
test_readonly_config_directory_refuses_first_write() {
  local dir="$XDG_CONFIG_HOME/workytree"
  mkdir -p "$dir"
  chmod 555 "$dir"
  local errfile; errfile="$(mktemp)"
  local out rc

  out="$(wt init x ~/src ~/wts 2>"$errfile")"; rc=$?
  assert_eq "$rc" "3" "init into a read-only config directory"
  [[ "$out" == *"config written"* || "$out" == *"added project"* ]] && { (( ++_fail )); print -u2 "  FAIL: init claimed success: $out"; print >> "$WT_FAIL_FILE" "FAIL: init claimed success"; } || (( ++_pass ))
  assert_contains "$(cat "$errfile")" "could not create the config file"
  _assert_no_raw_shell_diagnostic "$(cat "$errfile")" "init"
  assert_eq "$(print -l -- "$dir"/*(N))" "" "nothing created in the read-only directory"

  # `config edit` is the recovery path and must still reach the editor -- and must not leak
  # its own touch-create diagnostic while getting there (R42).
  out="$(EDITOR=true wt config edit 2>&1)"; rc=$?
  assert_eq "$rc" "0" "config edit must still reach the editor"
  _assert_no_raw_shell_diagnostic "$out" "config edit"

  rm -f "$errfile"
  chmod 755 "$dir"
}

# The config PARENT tree cannot be created at all (its own parent is read-only). Distinct
# from the two cases above: this refusal comes from _config_prepare_write_target's checked
# `mkdir -p`, not from the file-create or directory-writability steps.
test_uncreatable_config_directory_refuses() {
  mkdir -p "$HOME/locked"
  chmod 555 "$HOME/locked"
  export WORKYTREE_CONFIG="$HOME/locked/deeper/config"
  local out; out="$(wt project add me ~/src ~/wts 2>&1)"
  assert_eq "$?" "3"
  assert_contains "$out" "could not create the config directory"
  _assert_no_raw_shell_diagnostic "$out" "project add into an uncreatable directory"
  assert_not_exists "$HOME/locked/deeper"
  chmod 755 "$HOME/locked"
}

run_tests

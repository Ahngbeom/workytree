# Shared helpers for tests/*.test.zsh. Source this at the top of each test file.
WT_TEST_ROOT="${0:A:h:h}"
WT_BIN="$WT_TEST_ROOT/bin/workytree"
typeset -gi _pass=0 _fail=0
typeset -g TMP_ROOT=""

# assert_* failures inside a `$(...)` command substitution run in a subshell, so the
# `(( ++_fail ))` increment never reaches the parent shell's counter. This file mirrors
# every failure here too, so run_tests can detect a failure even when the in-process
# counter was silently swallowed by a subshell. $$ is the top-level script's PID and does
# not change inside command substitutions in zsh, so this path is stable for the whole run.
typeset -g WT_FAIL_FILE="${TMPDIR:-/tmp}/wt-test-fail.$$"
: > "$WT_FAIL_FILE"

setup_env() {
  # Resolve to the physical path: macOS's mktemp -d lands under /var/folders, and /var is
  # itself a symlink to /private/var. Tools that canonicalize cwd (e.g. `git rev-parse
  # --show-toplevel`) would otherwise report a path that disagrees with $HOME textually
  # while naming the same directory.
  TMP_ROOT="${$(mktemp -d):A}"
  export HOME="$TMP_ROOT/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  unset WORKYTREE_PROMPT_INPUT WORKYTREE_PROMPT_KEYS WORKYTREE_CONFIG WORKYTREE_ALIAS ZDOTDIR
  cd "$TMP_ROOT"
}
teardown_env() { cd /; [[ -n "$TMP_ROOT" ]] && rm -rf "$TMP_ROOT"; }

# make_repo <dir>: git repo on branch main with one commit
make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  print hello > "$1/README.md"
  git -C "$1" add -A && git -C "$1" commit -qm init
}

write_config() { mkdir -p "$XDG_CONFIG_HOME/workytree"; cat > "$XDG_CONFIG_HOME/workytree/config"; }

wt() { "$WT_BIN" "$@" < /dev/null; }

assert_eq() {
  if [[ "$1" == "$2" ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL ${3:-}: expected [$2] got [$1]"; print >> "$WT_FAIL_FILE" "FAIL ${3:-}: expected [$2] got [$1]"; fi
}
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL ${3:-}: [$1] does not contain [$2]"; print >> "$WT_FAIL_FILE" "FAIL ${3:-}: [$1] does not contain [$2]"; fi
}
assert_exit() {
  local want="$1"; shift
  "$@" >/dev/null 2>&1; local got=$?
  assert_eq "$got" "$want" "exit code of: $*"
}
assert_dir() { if [[ -d "$1" ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL: dir missing $1"; print >> "$WT_FAIL_FILE" "FAIL: dir missing $1"; fi }
assert_not_exists() { if [[ ! -e "$1" ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL: exists $1"; print >> "$WT_FAIL_FILE" "FAIL: exists $1"; fi }

run_tests() {
  local t
  for t in ${(ok)functions[(I)test_*]}; do
    setup_env
    print "  $t"
    $t
    teardown_env
  done
  local -i file_fail
  file_fail=$(grep -c . "$WT_FAIL_FILE" 2>/dev/null)
  file_fail=${file_fail:-0}
  if (( file_fail > _fail )); then
    print "$_pass passed, $file_fail failed"
  else
    print "$_pass passed, $_fail failed"
  fi
  local -i ok=1
  (( _fail == 0 && file_fail == 0 )) || ok=0
  rm -f "$WT_FAIL_FILE"
  (( ok ))
}

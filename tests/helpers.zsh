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
  export XDG_STATE_HOME="$HOME/.local/state"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  unset WORKYTREE_PROMPT_INPUT WORKYTREE_PROMPT_KEYS WORKYTREE_CONFIG WORKYTREE_ALIAS ZDOTDIR \
    WORKYTREE_SHELL WORKYTREE_AI_SKIP WORKYTREE_AI_RUNFILE WORKYTREE_CD_CAPABLE EDITOR VISUAL NO_COLOR
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

# pty_start [code]: an interactive zsh on a pseudo-terminal, so stdin, stdout and /dev/tty are
# all a terminal, with $HOME/.zshrc sourcing the wrapper. With <code> it runs `zsh -i -c <code>`;
# without, a line-mode shell (no ZLE) that runs whatever pty_send types.
typeset -g WT_PTY_OUT=''
pty_start() {
  zmodload zsh/zpty
  print -r -- "print -r -- \$\$ > '$HOME/.pty.pid'; export TMPDIR='$TMP_ROOT'; source '$WT_TEST_ROOT/shell/workytree.zsh'" > "$HOME/.zshrc"
  WT_PTY_OUT=''
  if (( $# )); then
    zpty -b WT_PTY "ZDOTDIR=${(q)HOME} TERM=xterm-256color zsh -d -i -c ${(q)1}"
  else
    zpty -b WT_PTY "ZDOTDIR=${(q)HOME} TERM=xterm-256color zsh -d -i +Z"
  fi
}
# No 2>/dev/null on zpty builtins: zpty -d then closes the saved stderr, and every later
# FAIL line of the test file goes nowhere.
_pty_drain() { local chunk; while zpty -r -t WT_PTY chunk; do WT_PTY_OUT+="$chunk"; done; }
# pty_wait <text> [tenths=100]: rc 1 if <text> has not appeared by then.
pty_wait() {
  local -i i
  for (( i = 0; i < ${2:-100}; i++ )); do
    _pty_drain
    [[ "$WT_PTY_OUT" == *"$1"* ]] && return 0
    sleep 0.1
  done
  return 1
}
pty_send() { zpty -w -n WT_PTY "$1"; }
_pty_kill_tree() { local c; for c in $(pgrep -P "$1"); do _pty_kill_tree "$c"; done; kill -9 "$1" 2>/dev/null; }
# pty_finish [tenths=200]: waits for the shell to exit and leaves the transcript, CRs removed,
# in WT_PTY_OUT. Call it in the shell that ran pty_start, not in a $(...): zpty cannot watch a
# child of another process. A shell still running at the deadline is killed with everything it
# started (zpty -d alone waits on an fzf that ignores SIGHUP), and the transcript ends in
# "[pty timed out]".
pty_finish() {
  local -i i
  for (( i = 0; i < ${1:-200}; i++ )); do
    _pty_drain
    zpty -t WT_PTY || break
    sleep 0.1
  done
  if zpty -t WT_PTY; then
    WT_PTY_OUT+=$'\n[pty timed out]'
    [[ -s "$HOME/.pty.pid" ]] && _pty_kill_tree "$(<"$HOME/.pty.pid")"
  fi
  _pty_drain
  zpty -d WT_PTY
  WT_PTY_OUT="${WT_PTY_OUT//$'\r'/}"
}
# pty_run <code>: pty_start <code>, then pty_finish; prints the transcript.
pty_run() { pty_start "$1"; pty_finish; print -r -- "$WT_PTY_OUT"; }

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
assert_exists() { if [[ -e "$1" ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL: missing $1${2:+ ($2)}"; print >> "$WT_FAIL_FILE" "FAIL: missing $1${2:+ ($2)}"; fi }
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

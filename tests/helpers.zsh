# Shared helpers for tests/*.test.zsh. Source this at the top of each test file.
WT_TEST_ROOT="${0:A:h:h}"
WT_BIN="$WT_TEST_ROOT/bin/workytree"
typeset -gi _pass=0 _fail=0
typeset -g TMP_ROOT=""

setup_env() {
  TMP_ROOT="$(mktemp -d)"
  export HOME="$TMP_ROOT/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  unset WORKYTREE_PROMPT_INPUT WORKYTREE_CONFIG WORKYTREE_ALIAS ZDOTDIR
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
  if [[ "$1" == "$2" ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL ${3:-}: expected [$2] got [$1]"; fi
}
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL ${3:-}: [$1] does not contain [$2]"; fi
}
assert_exit() {
  local want="$1"; shift
  "$@" >/dev/null 2>&1; local got=$?
  assert_eq "$got" "$want" "exit code of: $*"
}
assert_dir() { if [[ -d "$1" ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL: dir missing $1"; fi }
assert_not_exists() { if [[ ! -e "$1" ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL: exists $1"; fi }

run_tests() {
  local t
  for t in ${(ok)functions[(I)test_*]}; do
    setup_env
    print "  $t"
    $t
    teardown_env
  done
  print "$_pass passed, $_fail failed"
  (( _fail == 0 ))
}

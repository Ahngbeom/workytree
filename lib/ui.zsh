# Colored output helpers. Color only when stdout is a TTY, NO_COLOR is unset, and --no-color not given.
typeset -gi WT_COLOR=1
typeset -g WT_C_INFO='' WT_C_OK='' WT_C_WARN='' WT_C_ERR='' WT_C_DIM='' WT_C_RESET=''
ui_init() {
  if (( WT_COLOR )) && [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    WT_C_INFO=$'\033[38;5;39m' WT_C_OK=$'\033[38;5;70m' WT_C_WARN=$'\033[38;5;178m'
    WT_C_ERR=$'\033[38;5;196m' WT_C_DIM=$'\033[38;5;244m' WT_C_RESET=$'\033[0m'
  else
    WT_C_INFO='' WT_C_OK='' WT_C_WARN='' WT_C_ERR='' WT_C_DIM='' WT_C_RESET=''
  fi
}
info()    { print -r -- "${WT_C_INFO}$*${WT_C_RESET}"; }
success() { print -r -- "${WT_C_OK}$*${WT_C_RESET}"; }
# R52: warn goes to stderr, not stdout -- `wt repo list | wc -l` (or any other script piping a
# command's stdout) must never count a "no repos registered"-style warning as if it were data.
# info/success stay on stdout deliberately: create's summary lines are stdout-before-the-path,
# and moving them would break the "last stdout line is the target path" contract the shell
# wrapper (shell/workytree.zsh) depends on.
warn()    { print -u2 -r -- "${WT_C_WARN}$*${WT_C_RESET}"; }
dim()     { print -r -- "${WT_C_DIM}$*${WT_C_RESET}"; }
error()   { print -u2 -r -- "${WT_C_ERR}workytree: $*${WT_C_RESET}"; }
hint()    { print -u2 -r -- "${WT_C_DIM}  ↳ hint: $*${WT_C_RESET}"; }
die()         { error "$*"; exit 1; }
# die_with_hints <msg> <hint>...: error, then one hint line per remaining argument.
die_with_hints() {
  error "$1"; shift
  local h; for h in "$@"; do hint "$h"; done
  exit 1
}

# ui_progress <current> <total> <label>: one step-bar line on stderr.
ui_progress() {
  local -i cur=$1 total=$2 width=20 filled
  filled=$(( total > 0 ? cur * width / total : width ))
  # Pad with an ASCII placeholder, then substitute: under LC_ALL=C, (l::) counts bytes, so
  # padding with the 3-byte █ directly yields a third as many glyphs and a short bar.
  local done_part="${(l:filled::#:)${:-}}" todo_part="${(l:width-filled::#:)${:-}}"
  print -u2 -r -- "${WT_C_INFO}[${done_part//\#/█}${WT_C_DIM}${todo_part//\#/░}${WT_C_INFO}]${WT_C_RESET} $cur/$total $3"
}
ui_rule() { print -u2 -r -- "${WT_C_DIM}──────── $1 ────────${WT_C_RESET}"; }
usage_error() { error "$*"; exit 2; }

# _wt_indent_and_cap <text>: format git's raw stderr for a refusal message -- indent every
# line by 2 spaces (readable inside a larger message) and cap it at 20 lines (git chatter
# from e.g. a corrupt index can run long; the point is to show enough for a user to tell a
# benign warning from a real problem, not to dump everything). Empty input gets a
# placeholder so the message never ends with a dangling ": ".
_wt_indent_and_cap() {
  local text="$1"
  [[ -z "$text" ]] && { print -r -- "  (git produced no diagnostic output)"; return; }
  local -a lines; lines=("${(@f)text}")
  local -i total=${#lines}
  (( total > 20 )) && lines=("${lines[@]:0:20}" "... (truncated, ${total} lines total)")
  local l
  for l in "${lines[@]}"; do print -r -- "  $l"; done
}

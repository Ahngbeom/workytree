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
die()         { error "$*"; exit 1; }
usage_error() { error "$*"; exit 2; }

# R38: `get`/`set` both read/write through WT_CFG/WT_PCFG/WT_RCFG, which config_load()
# leaves EMPTY (not partially populated) after a recorded parse failure -- without an
# explicit check here, `config get <key>` on a broken config would silently fall through to
# the ordinary "config key not set: <key>" path below (the WRONG message, discarding the
# file:line the user actually needs to fix it). `path` and `edit` do not touch parsed config
# state at all -- they must keep working unconditionally, since `edit` is the tool's own
# recovery path for a config broken this way.
#
# R44 (fix round 5): that check is now `require_loadable_config` (lib/resolve.zsh) -- the
# SAME function every other consumer calls, exit 3 -- rather than a local copy exiting 1.
# R38 originally kept 1 here to match `config get`'s own "key not set" exit code, but 1 was
# only ever what config_load's historical die() happened to return, and matching it made a
# load failure INDISTINGUISHABLE from `config get`'s legitimate exit 1 for a genuinely unset
# key: a caller could not tell "your config is broken" from "that key isn't set". It also
# meant `config get` and `list` reported DIFFERENT codes for the SAME broken config, and
# `config set` reported 1 for a load failure but 3 (R42's _config_die_state) for a write
# failure. R31's principle settles it: exit 3 describes the state of the config FILE, 1 and
# 2 describe the user's input. Exit 1 from `config get` now means exactly one thing -- the
# key is not set.
cmd_config() {
  local sub="${1:-}"; shift 2>/dev/null
  case "$sub" in
    path) config_file_path ;;
    get)  require_loadable_config
          [[ $# -eq 1 ]] || usage_error "usage: workytree config get <key>"
          config_get "$1" || { error "config key not set: $1"; exit 1; } ;;
    set)  require_loadable_config
          [[ $# -eq 2 ]] || usage_error "usage: workytree config set <key> <value>"
          config_set "$1" "$2"; success "set $1 = $2"
          # Turning AI sessions ON needs a new shell before it takes effect. The wrapper
          # resolves that question once, when it is sourced (shell/workytree.zsh), because the
          # answer costs a CLI invocation and it needs it before deciding whether to create the
          # runfile at all. Without this hint the failure is silent and easy to misread as the
          # feature being broken: `wt create` just does not open a session, in the very shell
          # where the user has only now switched it on.
          #
          # Only for turning it ON. `off` is honored immediately -- the CLI re-reads ai_session
          # on every run -- so saying "open a new shell" there would be noise about nothing.
          #
          # An `if`, not `[[ ... ]] && warn`: this is the last command in the branch, so a
          # false test would become `config set`'s own exit status and report failure for a
          # write that succeeded.
          if [[ "${1##*.}" == ai_session && "$2" == (ask|always) ]]; then
            warn "open a new shell (or re-source your shell config) before this takes effect"
          fi ;;
    # R41: `-e` (not `-f`) guards the touch-create -- a directory or other non-regular
    # occupant at the config path is left alone rather than attempting `: > "$f"` against
    # it (which would fail with a raw "is a directory" diagnostic before ever reaching the
    # editor). `edit` still execs the editor on whatever is actually there either way --
    # it is the tool's own recovery path for every config-broken shape (R38), including
    # ones this process can't itself write a fresh empty file over.
    # R42: both preparation steps are BEST-EFFORT and silenced. `edit` must reach the
    # editor for every broken shape (it is the recovery path), so it must not refuse the
    # way the config WRITERS now do -- but it also must not leak `mkdir`'s or the
    # redirection's own raw diagnostic when the directory is read-only. Neither step's
    # failure is a success claim: whatever the editor then reports about a file it cannot
    # open is between it and the user.
    edit) local f; f="$(config_file_path)"; mkdir -p "${f:h}" 2>/dev/null
          [[ -e "$f" ]] || { : > "$f" } 2>/dev/null
          exec "${VISUAL:-${EDITOR:-vi}}" "$f" ;;
    *)    usage_error "usage: workytree config path|get <key>|set <key> <value>|edit" ;;
  esac
}

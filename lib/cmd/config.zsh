# R38: `get`/`set` both read/write through WT_CFG/WT_PCFG/WT_RCFG, which config_load()
# leaves EMPTY (not partially populated) after a recorded parse failure -- without an
# explicit check here, `config get <key>` on a broken config would silently fall through to
# the ordinary "config key not set: <key>" path below (still exit 1, but the WRONG message,
# discarding the file:line the user actually needs to fix it). `path` and `edit` do not
# touch parsed config state at all -- they must keep working unconditionally, since `edit`
# is the tool's own recovery path for a config broken this way.
cmd_config() {
  local sub="${1:-}"; shift 2>/dev/null
  case "$sub" in
    path) config_file_path ;;
    get)  [[ -z "$WT_CONFIG_LOAD_ERROR" ]] || { error "$WT_CONFIG_LOAD_ERROR"; exit 1; }
          [[ $# -eq 1 ]] || usage_error "usage: workytree config get <key>"
          config_get "$1" || { error "config key not set: $1"; exit 1; } ;;
    set)  [[ -z "$WT_CONFIG_LOAD_ERROR" ]] || { error "$WT_CONFIG_LOAD_ERROR"; exit 1; }
          [[ $# -eq 2 ]] || usage_error "usage: workytree config set <key> <value>"
          config_set "$1" "$2"; success "set $1 = $2" ;;
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

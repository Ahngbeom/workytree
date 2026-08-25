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
    edit) local f; f="$(config_file_path)"; mkdir -p "${f:h}"; [[ -f "$f" ]] || : > "$f"
          exec "${VISUAL:-${EDITOR:-vi}}" "$f" ;;
    *)    usage_error "usage: workytree config path|get <key>|set <key> <value>|edit" ;;
  esac
}

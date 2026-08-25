cmd_config() {
  local sub="${1:-}"; shift 2>/dev/null
  case "$sub" in
    path) config_file_path ;;
    get)  [[ $# -eq 1 ]] || usage_error "usage: workytree config get <key>"
          config_get "$1" || { error "config key not set: $1"; exit 1; } ;;
    set)  [[ $# -eq 2 ]] || usage_error "usage: workytree config set <key> <value>"
          config_set "$1" "$2"; success "set $1 = $2" ;;
    edit) local f; f="$(config_file_path)"; mkdir -p "${f:h}"; [[ -f "$f" ]] || : > "$f"
          exec "${VISUAL:-${EDITOR:-vi}}" "$f" ;;
    *)    usage_error "usage: workytree config path|get <key>|set <key> <value>|edit" ;;
  esac
}

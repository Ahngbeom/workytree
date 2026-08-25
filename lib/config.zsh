# Single point of config-file I/O. Format: INI-like; "[project <name>]" / "[repo <name>]" sections,
# "key = value" lines, "#" comments (whole line, or after whitespace). No repeated keys.
typeset -g  WT_CONFIG_FILE=""
typeset -gi WT_CONFIG_EXISTS=0
typeset -gA WT_CFG WT_PCFG WT_RCFG
typeset -ga WT_PROJECTS WT_REPOS

config_file_path() {
  print -r -- "${WORKYTREE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/workytree/config}"
}

# expand_path <p>: "~/x" and "$VAR"/"${VAR}" expansion; trailing slash removed.
expand_path() {
  local p="$1"
  [[ "$p" == "~" ]] && p="$HOME"
  p="${p/#\~\//$HOME/}"
  while [[ "$p" =~ '\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?' ]]; do
    p="${p/"$MATCH"/${(P)match[1]:-}}"
  done
  print -r -- "${p%/}"
}

_config_strip_comment() {
  local line="$1"
  [[ "$line" == [[:space:]]#\#* ]] && { print -r -- ""; return; }
  print -r -- "${line%%[[:space:]]##\#*}"
}

config_load() {
  WT_CONFIG_FILE="$(config_file_path)"
  WT_CFG=() WT_PCFG=() WT_RCFG=() WT_PROJECTS=() WT_REPOS=()
  WT_CONFIG_EXISTS=0
  [[ -f "$WT_CONFIG_FILE" ]] || return 0
  WT_CONFIG_EXISTS=1
  local raw line lineno=0 sect_type="" sect_name="" key value
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    (( lineno++ ))
    line="$(_config_strip_comment "${raw%%$'\r'}")"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ "$line" =~ '^[[:space:]]*\[[[:space:]]*(project|repo)[[:space:]]+([^]]*)\][[:space:]]*$' ]]; then
      sect_type="$match[1]"
      sect_name="${${match[2]##[[:space:]]#}%%[[:space:]]#}"
      if [[ "$sect_type" == project ]]; then
        (( ${WT_PROJECTS[(Ie)$sect_name]} )) && die "duplicate [project $sect_name] at $WT_CONFIG_FILE:$lineno"
        WT_PROJECTS+=("$sect_name")
      else
        (( ${WT_REPOS[(Ie)$sect_name]} )) && die "duplicate [repo $sect_name] at $WT_CONFIG_FILE:$lineno"
        WT_REPOS+=("$sect_name")
      fi
      continue
    fi
    if [[ "$line" =~ '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$' ]]; then
      key="$match[1]" value="${match[2]%%[[:space:]]#}"
      case "$sect_type" in
        "")      WT_CFG[$key]="$value" ;;
        project) WT_PCFG[$sect_name.$key]="$value" ;;
        repo)    WT_RCFG[$sect_name.$key]="$value" ;;
      esac
      continue
    fi
    die "config parse error at $WT_CONFIG_FILE:$lineno: $line"
  done < "$WT_CONFIG_FILE"
}

# _config_split_key <dotted> -> sets REPLY_TYPE REPLY_NAME REPLY_KEY
_config_split_key() {
  local key="$1" rest
  case "$key" in
    project.*.*|repo.*.*)
      REPLY_TYPE="${key%%.*}"; rest="${key#*.}"; REPLY_NAME="${rest%.*}"; REPLY_KEY="${rest##*.}" ;;
    *.*) usage_error "invalid config key: $key (use <key>, project.<name>.<key>, repo.<name>.<key>)" ;;
    *)   REPLY_TYPE="" REPLY_NAME="" REPLY_KEY="$key" ;;
  esac
}

# config_get <dotted-key>: prints value (path-like keys expanded); rc 1 if unset
config_get() {
  local REPLY_TYPE REPLY_NAME REPLY_KEY v
  _config_split_key "$1"
  case "$REPLY_TYPE" in
    project) (( ${+WT_PCFG[$REPLY_NAME.$REPLY_KEY]} )) || return 1; v="${WT_PCFG[$REPLY_NAME.$REPLY_KEY]}" ;;
    repo)    (( ${+WT_RCFG[$REPLY_NAME.$REPLY_KEY]} )) || return 1; v="${WT_RCFG[$REPLY_NAME.$REPLY_KEY]}" ;;
    *)       (( ${+WT_CFG[$REPLY_KEY]} )) || return 1; v="${WT_CFG[$REPLY_KEY]}" ;;
  esac
  case "$REPLY_KEY" in
    repo_root|worktree_root|path) expand_path "$v" ;;
    *) print -r -- "$v" ;;
  esac
}

# _config_write <type> <name> <key> <value> <delete:0|1>
# Rewrites the file line by line, replacing the key inside its section, appending the key
# at the end of the section, or appending a new section. Comments and order are preserved.
_config_write() {
  local want_type="$1" want_name="$2" key="$3" value="$4" delete="$5"
  local file tmp line cur_type="" cur_name="" in_target=0 seen_target=0 done=0
  file="$(config_file_path)"
  mkdir -p "${file:h}"
  [[ -f "$file" ]] || : > "$file"
  tmp="$(mktemp "${file}.XXXXXX")"
  [[ -z "$want_type" ]] && { in_target=1; seen_target=1; }
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ '^[[:space:]]*\[[[:space:]]*(project|repo)[[:space:]]+([^]]*)\][[:space:]]*$' ]]; then
        if (( in_target && !done && !delete )); then print -r -- "$key = $value"; done=1; fi
        cur_type="$match[1]"; cur_name="${${match[2]##[[:space:]]#}%%[[:space:]]#}"
        if [[ "$cur_type" == "$want_type" && "$cur_name" == "$want_name" ]]; then in_target=1; seen_target=1; else in_target=0; fi
        print -r -- "$line"; continue
      fi
      if (( in_target && !done )) && [[ "$(_config_strip_comment "$line")" =~ "^[[:space:]]*${key}[[:space:]]*=" ]]; then
        (( delete )) || print -r -- "$key = $value"
        done=1; continue
      fi
      print -r -- "$line"
    done < "$file"
    if (( !done && !delete )); then
      if (( seen_target )); then
        print -r -- "$key = $value"
      else
        print -r -- ""; print -r -- "[$want_type $want_name]"; print -r -- "$key = $value"
      fi
    fi
  } > "$tmp"
  mv "$tmp" "$file"
}

config_set()   { local REPLY_TYPE REPLY_NAME REPLY_KEY; _config_split_key "$1"; _config_write "$REPLY_TYPE" "$REPLY_NAME" "$REPLY_KEY" "$2" 0; config_load; }
config_unset() { local REPLY_TYPE REPLY_NAME REPLY_KEY; _config_split_key "$1"; _config_write "$REPLY_TYPE" "$REPLY_NAME" "$REPLY_KEY" "" 1; config_load; }

# config_remove_section <project|repo> <name>: drops the header and every line until the next header
config_remove_section() {
  local want_type="$1" want_name="$2" file tmp line skipping=0
  file="$(config_file_path)"
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "${file}.XXXXXX")"
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ '^[[:space:]]*\[[[:space:]]*(project|repo)[[:space:]]+([^]]*)\][[:space:]]*$' ]]; then
        local n="${${match[2]##[[:space:]]#}%%[[:space:]]#}"
        if [[ "$match[1]" == "$want_type" && "$n" == "$want_name" ]]; then skipping=1; continue; else skipping=0; fi
      fi
      (( skipping )) || print -r -- "$line"
    done < "$file"
  } > "$tmp"
  mv "$tmp" "$file"
  config_load
}

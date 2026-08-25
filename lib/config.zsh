# Single point of config-file I/O. Format: INI-like; "[project <name>]" / "[repo <name>]" sections,
# "key = value" lines, "#" comments (whole line, or after whitespace — a "#" glued to a non-space
# character is not treated as a comment start). No repeated keys: a key reused within the same
# section (or twice at global scope) is a hard error naming file:lineno, same as a duplicate
# section header. Writes (config_set/config_unset/config_remove_section) write through a
# symlinked config file rather than replacing the link, and normalize the whole file to LF line
# endings even when the original used CRLF.
typeset -g  WT_CONFIG_FILE=""
typeset -gi WT_CONFIG_EXISTS=0
typeset -gA WT_CFG WT_PCFG WT_RCFG
typeset -ga WT_PROJECTS WT_REPOS

config_file_path() {
  print -r -- "${WORKYTREE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/workytree/config}"
}

# expand_path <p>: "~/x" and "$VAR"/"${VAR}" expansion; trailing slash removed. Each "$VAR" is
# expanded in a single left-to-right pass over the ORIGINAL string — the substituted value is
# appended to the result and never re-scanned, so a self- or mutually-referential variable
# (e.g. FOO='$FOO') cannot make this loop forever.
expand_path() {
  local p="$1"
  [[ "$p" == "~" ]] && p="$HOME"
  p="${p/#\~\//$HOME/}"
  local result="" rest="$p"
  while [[ "$rest" =~ '\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?' ]]; do
    result+="${rest[1,MBEGIN-1]}${(P)match[1]:-}"
    rest="${rest[MEND+1,-1]}"
  done
  result+="$rest"
  print -r -- "${result%/}"
}

# config_unset_var_refs <raw>: prints, one per line, the name of every "$VAR"/"${VAR}"
# reference in <raw> that currently names an UNSET shell variable. Mirrors expand_path's own
# left-to-right, non-rescanning scan (same regex, same MBEGIN/MEND stepping) so "is this
# reference unset" agrees exactly with what expand_path itself would silently substitute ""
# for. R32: a repo_root/worktree_root like "$WORK/wts" with $WORK unset expands to "/wts" --
# an accidentally ABSOLUTE-looking path that a plain "is it absolute" check would wave
# through -- so callers validating a root value check this FIRST and report the unset
# variable by name, rather than a confusing "not absolute" or "unusable" verdict about a
# string the user never actually meant.
config_unset_var_refs() {
  local rest="$1"
  while [[ "$rest" =~ '\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?' ]]; do
    (( ${+parameters[$match[1]]} )) || print -r -- "$match[1]"
    rest="${rest[MEND+1,-1]}"
  done
}

_config_strip_comment() {
  setopt localoptions extendedglob
  local line="$1"
  [[ "$line" == [[:space:]]#\#* ]] && { print -r -- ""; return; }
  print -r -- "${line%%[[:space:]]##\#*}"
}

config_load() {
  setopt localoptions extendedglob
  WT_CONFIG_FILE="$(config_file_path)"
  WT_CFG=() WT_PCFG=() WT_RCFG=() WT_PROJECTS=() WT_REPOS=()
  WT_CONFIG_EXISTS=0
  [[ -f "$WT_CONFIG_FILE" ]] || return 0
  WT_CONFIG_EXISTS=1
  local raw line lineno=0 sect_type="" sect_name="" key value
  local -A seen_keys
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
      seen_keys=()
      continue
    fi
    if [[ "$line" =~ '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$' ]]; then
      key="$match[1]" value="${match[2]%%[[:space:]]#}"
      (( ${+seen_keys[$key]} )) && die "duplicate key $key at $WT_CONFIG_FILE:$lineno"
      seen_keys[$key]=1
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
  setopt localoptions extendedglob
  local want_type="$1" want_name="$2" key="$3" value="$4" delete="$5"
  local file tmp line cur_type="" cur_name="" in_target=0 seen_target=0 done=0
  file="$(config_file_path)"
  mkdir -p "${file:h}"
  [[ -f "$file" ]] || : > "$file"
  [[ -L "$file" ]] && file="${file:A}"
  tmp="$(mktemp "${file}.XXXXXX")"
  [[ -z "$want_type" ]] && { in_target=1; seen_target=1; }
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
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
  setopt localoptions extendedglob
  local want_type="$1" want_name="$2" file tmp line skipping=0
  file="$(config_file_path)"
  [[ -f "$file" ]] || return 0
  [[ -L "$file" ]] && file="${file:A}"
  tmp="$(mktemp "${file}.XXXXXX")"
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
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

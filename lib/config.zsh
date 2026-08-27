# Single point of config-file I/O. Format: INI-like; "[project <name>]" / "[repo <name>]" /
# "[agent <name>]" sections, "key = value" lines, "#" comments (whole line, or after
# whitespace — a "#" glued to a non-space character is not treated as a comment start). No
# repeated keys: a key reused within the same section (or twice at global scope) is a hard
# error naming file:lineno, same as a duplicate
# section header. Writes (config_set/config_unset/config_remove_section) write through a
# symlinked config file rather than replacing the link, and normalize the whole file to LF line
# endings even when the original used CRLF.
#
# R38: a config file that fails to PARSE (duplicate key/section, an unparseable line) does
# NOT die() here. bin/workytree's main() calls config_load() unconditionally, before any
# command-specific code -- including __complete -- ever gets control, so a die() here would
# kill Tab completion (and `config path`/`config edit`, the very commands that could repair
# the file) on every keystroke against a broken config. Instead the failure is RECORDED in
# WT_CONFIG_LOAD_ERROR (empty = no failure) and every array is reset to empty, exactly as if
# the config had no usable content -- config_load() itself never exits the process. Callers
# that need a loaded config to do their job (require_config, `config get`/`set`) check
# WT_CONFIG_LOAD_ERROR and refuse loudly with this same message; callers that can legitimately
# run against absent/empty config data (`__complete`, `config path`, `config edit`, `help`,
# `--version`) don't need to check it at all -- reset-to-empty already gives them the
# "produce nothing, don't crash" behavior they want.
typeset -g  WT_CONFIG_FILE=""
typeset -gi WT_CONFIG_EXISTS=0
typeset -g  WT_CONFIG_LOAD_ERROR=""
typeset -gA WT_CFG WT_PCFG WT_RCFG WT_ACFG
typeset -ga WT_PROJECTS WT_REPOS WT_AGENTS

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

# _config_load_fail <message>: records a parse failure (R38) in WT_CONFIG_LOAD_ERROR and
# discards every array back to empty -- a config that failed to parse gets treated as having
# NO usable content by any consumer that doesn't explicitly check WT_CONFIG_LOAD_ERROR,
# rather than the partial/inconsistent state parsing had reached at the point of failure.
# WT_CONFIG_EXISTS is deliberately left untouched: it is file-EXISTENCE, not
# file-VALIDITY, and callers like `cmd_init` rely on that distinction to keep refusing a
# broken-but-present config rather than silently overwriting it.
_config_load_fail() {
  WT_CONFIG_LOAD_ERROR="$1"
  WT_CFG=() WT_PCFG=() WT_RCFG=() WT_ACFG=() WT_PROJECTS=() WT_REPOS=() WT_AGENTS=()
}

config_load() {
  setopt localoptions extendedglob
  WT_CONFIG_FILE="$(config_file_path)"
  WT_CFG=() WT_PCFG=() WT_RCFG=() WT_ACFG=() WT_PROJECTS=() WT_REPOS=() WT_AGENTS=()
  WT_CONFIG_EXISTS=0
  WT_CONFIG_LOAD_ERROR=""
  # R41: classify the path BEFORE ever attempting to read it, rather than letting the read
  # itself (`< "$WT_CONFIG_FILE"` below) fail at the shell level -- an open() failure there
  # prints its own raw diagnostic ("config_load:N: permission denied: ...") straight to
  # stderr, breaking the empty-stderr guarantee __complete depends on (R38), and never
  # reaches _config_load_fail, so WT_CONFIG_LOAD_ERROR stays empty and every consumer built
  # on top of it in R38/R39 falls through to the WRONG diagnosis (`config get` reports "key
  # not set" instead of naming the real problem; `require_config` reports "no [project]
  # defined" instead of the actual unreadable/non-file path). Finding 1, fix round 3.
  #
  # -e is false for BOTH a genuinely absent path and a symlink whose target doesn't exist
  # (a "dangling" symlink) -- both are treated as absent, not a recorded failure: there is
  # no partial/corrupt content sitting at either to diagnose, only nothing, exactly like a
  # config file that was never created (and `config_set`/`_config_write` already know how
  # to create one by writing through a symlink at that path). Anything else that occupies
  # the path (following a live symlink to what it actually points at) but isn't a readable
  # regular file -- a directory, a socket, a regular file this process cannot read -- is a
  # recorded failure with its own clear message, never silence and never a raw diagnostic.
  if [[ ! -e "$WT_CONFIG_FILE" ]]; then
    return 0
  fi
  if [[ ! -f "$WT_CONFIG_FILE" ]]; then
    _config_load_fail "config path exists but is not a regular file: $WT_CONFIG_FILE"; return 1
  fi
  # R43: readability is OBSERVED, not predicted. `-r` reports what the permission bits say
  # open() *should* do; on a filesystem where those disagree with the real answer (unusual
  # ACLs, some network filesystems) a `-r` pre-check waves the file through and the actual
  # `< "$WT_CONFIG_FILE"` below fails at the shell level instead -- reinstating exactly the
  # Finding-1 defect this classification exists to prevent (raw "permission denied" on
  # stderr, WT_CONFIG_LOAD_ERROR left empty, `config get` reporting "key not set"). Opening
  # the file for real and discarding it is the same open() the read below performs, with its
  # own diagnostic suppressed, so the verdict cannot disagree with what actually happens.
  # `: < file` opens and closes immediately -- no fd stays alive, so nothing downstream (the
  # parse loop's own early `return 1`s included) has an fd lifetime to manage.
  if ! { : < "$WT_CONFIG_FILE" } 2>/dev/null; then
    _config_load_fail "config file exists but is not readable (check permissions): $WT_CONFIG_FILE"; return 1
  fi
  WT_CONFIG_EXISTS=1
  local raw line lineno=0 sect_type="" sect_name="" key value
  local -A seen_keys
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    (( lineno++ ))
    line="$(_config_strip_comment "${raw%%$'\r'}")"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ "$line" =~ '^[[:space:]]*\[[[:space:]]*(project|repo|agent)[[:space:]]+([^]]*)\][[:space:]]*$' ]]; then
      sect_type="$match[1]"
      sect_name="${${match[2]##[[:space:]]#}%%[[:space:]]#}"
      case "$sect_type" in
        project)
          if (( ${WT_PROJECTS[(Ie)$sect_name]} )); then
            _config_load_fail "duplicate [project $sect_name] at $WT_CONFIG_FILE:$lineno"; return 1
          fi
          WT_PROJECTS+=("$sect_name") ;;
        repo)
          if (( ${WT_REPOS[(Ie)$sect_name]} )); then
            _config_load_fail "duplicate [repo $sect_name] at $WT_CONFIG_FILE:$lineno"; return 1
          fi
          WT_REPOS+=("$sect_name") ;;
        agent)
          if (( ${WT_AGENTS[(Ie)$sect_name]} )); then
            _config_load_fail "duplicate [agent $sect_name] at $WT_CONFIG_FILE:$lineno"; return 1
          fi
          WT_AGENTS+=("$sect_name") ;;
      esac
      seen_keys=()
      continue
    fi
    if [[ "$line" =~ '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$' ]]; then
      key="$match[1]" value="${match[2]%%[[:space:]]#}"
      if (( ${+seen_keys[$key]} )); then
        _config_load_fail "duplicate key $key at $WT_CONFIG_FILE:$lineno"; return 1
      fi
      seen_keys[$key]=1
      case "$sect_type" in
        "")      WT_CFG[$key]="$value" ;;
        project) WT_PCFG[$sect_name.$key]="$value" ;;
        repo)    WT_RCFG[$sect_name.$key]="$value" ;;
        agent)   WT_ACFG[$sect_name.$key]="$value" ;;
      esac
      continue
    fi
    _config_load_fail "config parse error at $WT_CONFIG_FILE:$lineno: $line"; return 1
  done < "$WT_CONFIG_FILE"
}

# _config_split_key <dotted> -> sets REPLY_TYPE REPLY_NAME REPLY_KEY
_config_split_key() {
  local key="$1" rest
  case "$key" in
    project.*.*|repo.*.*|agent.*.*)
      REPLY_TYPE="${key%%.*}"; rest="${key#*.}"; REPLY_NAME="${rest%.*}"; REPLY_KEY="${rest##*.}" ;;
    *.*) usage_error "invalid config key: $key (use <key>, project.<name>.<key>, repo.<name>.<key>, agent.<name>.<key>)" ;;
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
    agent)   (( ${+WT_ACFG[$REPLY_NAME.$REPLY_KEY]} )) || return 1; v="${WT_ACFG[$REPLY_NAME.$REPLY_KEY]}" ;;
    *)       (( ${+WT_CFG[$REPLY_KEY]} )) || return 1; v="${WT_CFG[$REPLY_KEY]}" ;;
  esac
  case "$REPLY_KEY" in
    repo_root|worktree_root|path) expand_path "$v" ;;
    *) print -r -- "$v" ;;
  esac
}

# _config_die_state <message>: a config-FILE-STATE failure raised from a WRITE path.
# Exit 3, not die()'s exit 1: nothing about the user's ARGUMENTS is wrong when the config
# directory is read-only or the config path is occupied by a directory -- it is the state
# of the config file/its location that makes the command impossible, which is the exact
# category this tool reserves exit 3 for on the READ side already (require_loadable_config
# /require_config, lib/resolve.zsh; R31/R39). Same category, same code.
_config_die_state() { error "$1"; exit 3; }

# _config_prepare_write_target <file>: refuse -- with workytree's own prefixed message,
# exit 3, and nothing created or left behind -- every reason the temp-file-plus-rename
# strategy the writers below use could not actually complete. On success sets
# REPLY_WRITE_TARGET to the path to actually write (a symlink resolved to its target, so
# the link is preserved and its target updated).
#
# R42: `mktemp`+`mv` need a writable *containing directory*, which is a different question
# from whether the config FILE is writable. A read-only directory holding a mode-644 config
# passed the old file-only `-w` check, then `mktemp` failed (raw "mkstemp failed ...
# Permission denied"), `> "$tmp"` failed against the resulting empty path (raw "no such file
# or directory"), `mv "" "$file"` failed (raw "mv: : No such file or directory") -- and
# because not one of those three exit statuses was ever checked, `_config_write` returned 0
# and its caller printed "set default_project = me" over a file it had not touched. Every
# refusal below happens BEFORE any temp file exists and BEFORE any caller reaches its
# success message; the writers additionally check each external command's own exit status
# afterwards, so a failure these predicates cannot foresee still refuses instead of
# reporting a write that did not happen.
#
# R41/Finding 2 (still enforced here): a DIRECTORY at the config path made `mv "$tmp"
# "$file"` SILENTLY SUCCEED -- mv-into-a-directory is valid mv usage, not a bug in mv --
# leaving a stray temp-named file inside it while `cmd_init` reported success.
typeset -g REPLY_WRITE_TARGET=""
_config_prepare_write_target() {
  local file="$1" dir="${file:h}"

  # 1. The parent tree ("~/.config/workytree") is created on demand -- mkdir -p prints its
  #    own raw diagnostic and returns non-zero when it cannot, so suppress and re-report.
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" 2>/dev/null || _config_die_state "could not create the config directory (check permissions): $dir"
  fi

  # 2. Whatever already occupies the path must be a regular file this process can write.
  [[ -e "$file" && ! -f "$file" ]] && _config_die_state "config path exists but is not a regular file: $file"
  [[ -e "$file" && ! -w "$file" ]] && _config_die_state "config file exists but is not writable (check permissions): $file"

  # 3. Create it if absent. Done through the ORIGINAL path so a dangling symlink is written
  #    THROUGH (the link creating its own target) rather than replaced.
  if [[ ! -e "$file" ]]; then
    { : > "$file" } 2>/dev/null || _config_die_state "could not create the config file (check permissions): $file"
  fi

  # 4. Resolve a symlink: the temp file, the rename, and the directory that must accept both
  #    all belong to the link's TARGET, not to the directory the link happens to live in.
  [[ -L "$file" ]] && file="${file:A}"
  dir="${file:h}"

  # 5. The containing directory must accept a new entry (mktemp) and a rename (mv). This is
  #    the check R42 was missing entirely.
  [[ -w "$dir" && -x "$dir" ]] || _config_die_state "config directory is not writable (check permissions): $dir"

  # 6. Both writers READ the file back line by line to patch one line in place. Probe the
  #    open for real rather than trusting `-r` (R43, same reasoning as config_load's).
  { : < "$file" } 2>/dev/null || _config_die_state "config file exists but is not readable (check permissions): $file"

  REPLY_WRITE_TARGET="$file"
}

# _config_mktemp <target-file>: creates the sibling temp file, refusing (exit 3, no
# leftovers) if mktemp itself fails -- the status R42 found unchecked. Sets REPLY_TMP.
typeset -g REPLY_TMP=""
_config_mktemp() {
  local file="$1" tmp
  tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || tmp=""
  [[ -n "$tmp" ]] || _config_die_state "could not create a temporary file in the config directory (check permissions): ${file:h}"
  REPLY_TMP="$tmp"
}

# _config_write <type> <name> <key> <value> <delete:0|1>
# Rewrites the file line by line, replacing the key inside its section, appending the key
# at the end of the section, or appending a new section. Comments and order are preserved.
_config_write() {
  setopt localoptions extendedglob
  local want_type="$1" want_name="$2" key="$3" value="$4" delete="$5"
  local file tmp line cur_type="" cur_name="" in_target=0 seen_target=0 done=0
  file="$(config_file_path)"
  _config_prepare_write_target "$file"; file="$REPLY_WRITE_TARGET"
  _config_mktemp "$file"; tmp="$REPLY_TMP"
  [[ -z "$want_type" ]] && { in_target=1; seen_target=1; }
  # Tidiness: a brand-new (empty) config must not START with a blank line. The blank line
  # printed just below the loop exists to visually separate a newly-appended section from
  # whatever content came before it -- there is nothing to separate from when the file is
  # empty, which is exactly the FIRST config_set of a fresh `workytree init`/`project add`.
  local -i had_content=0
  [[ -s "$file" ]] && had_content=1
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      if [[ "$line" =~ '^[[:space:]]*\[[[:space:]]*(project|repo|agent)[[:space:]]+([^]]*)\][[:space:]]*$' ]]; then
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
        (( had_content )) && print -r -- ""
        print -r -- "[$want_type $want_name]"; print -r -- "$key = $value"
      fi
    fi
  } > "$tmp" || _config_write_failed "$tmp" "$file"
  _config_commit_temp "$tmp" "$file"
}

# _config_write_failed <tmp> <file> / _config_commit_temp <tmp> <file>: the two remaining
# unchecked external steps R42 named. Producing the new content can fail after the temp
# file exists (a full disk, a quota), and `mv` can fail on its own; either way the temp
# file is removed first so a refusal never leaves one behind, and the refusal happens
# before any caller's success message.
_config_write_failed() {
  rm -f "$1" 2>/dev/null
  _config_die_state "could not write the updated config (check permissions and free space): $2"
}
_config_commit_temp() {
  mv "$1" "$2" 2>/dev/null && return 0
  rm -f "$1" 2>/dev/null
  _config_die_state "could not replace the config file (check permissions): $2"
}

config_set()   { local REPLY_TYPE REPLY_NAME REPLY_KEY; _config_split_key "$1"; _config_write "$REPLY_TYPE" "$REPLY_NAME" "$REPLY_KEY" "$2" 0; config_load; }
config_unset() { local REPLY_TYPE REPLY_NAME REPLY_KEY; _config_split_key "$1"; _config_write "$REPLY_TYPE" "$REPLY_NAME" "$REPLY_KEY" "" 1; config_load; }

# config_remove_section <project|repo> <name>: drops the header and every line until the next header
config_remove_section() {
  setopt localoptions extendedglob
  local want_type="$1" want_name="$2" file tmp line skipping=0
  file="$(config_file_path)"
  # Nothing at all there -> nothing to remove, same no-op as always. Something there that
  # ISN'T a usable write target (a directory, an unwritable file, a read-only containing
  # directory, ...) -> refuse loudly (R41/R42) rather than silently no-op past it, through
  # the same choke point _config_write uses.
  [[ -e "$file" ]] || return 0
  _config_prepare_write_target "$file"; file="$REPLY_WRITE_TARGET"
  _config_mktemp "$file"; tmp="$REPLY_TMP"
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      if [[ "$line" =~ '^[[:space:]]*\[[[:space:]]*(project|repo|agent)[[:space:]]+([^]]*)\][[:space:]]*$' ]]; then
        local n="${${match[2]##[[:space:]]#}%%[[:space:]]#}"
        if [[ "$match[1]" == "$want_type" && "$n" == "$want_name" ]]; then skipping=1; continue; else skipping=0; fi
      fi
      (( skipping )) || print -r -- "$line"
    done < "$file"
  } > "$tmp" || _config_write_failed "$tmp" "$file"
  _config_commit_temp "$tmp" "$file"
  config_load
}

# `status`: worktree/branch overview across the configured workspace. lib/status.zsh collects
# and judges one repo; this file runs those collectors in parallel and renders the result as
# a table, JSON, or an fzf list whose keys hand off to `remove`, the browser, and the shell
# wrapper's cd.

typeset -gi WT_STATUS_MAX_JOBS=8
typeset -g  WT_STATUS_FZF_MIN=0.38
typeset -g  ST_REPO='' ST_HEADER=''
typeset -gi ST_FETCH=0 ST_OFFLINE=0 ST_STALE_FILTER=0 ST_STALE_DAYS=-1 ST_JSON=0 ST_PLAIN=0 ST_PROGRESS=0
typeset -ga ST_RECS ST_LINES

_status_parse_opts() {
  ST_REPO='' ST_FETCH=0 ST_OFFLINE=0 ST_STALE_FILTER=0 ST_STALE_DAYS=-1 ST_JSON=0 ST_PLAIN=0
  while (( $# )); do
    case "$1" in
      --fetch)   ST_FETCH=1 ;;
      --offline) ST_OFFLINE=1 ;;
      --stale)
        ST_STALE_FILTER=1
        [[ "${2:-}" == <-> ]] && { ST_STALE_DAYS=$2; shift; } ;;
      --json)    ST_JSON=1 ;;
      --plain)   ST_PLAIN=1 ;;
      -*|*$'\t'*) usage_error "usage: workytree status [repo] [--fetch|--offline] [--stale [days]] [--json] [--plain]" ;;
      *)
        [[ -z "$ST_REPO" ]] || usage_error "usage: workytree status [repo] [--fetch|--offline] [--stale [days]] [--json] [--plain]"
        ST_REPO="$1" ;;
    esac
    shift
  done
  (( ST_FETCH && ST_OFFLINE )) && usage_error "--fetch and --offline cannot be combined"
  return 0
}

# status_stale_days <project>: --stale <days> if given, else stale_days ([project] -> global),
# else 30.
status_stale_days() {
  (( ST_STALE_DAYS >= 0 )) && { print -r -- $ST_STALE_DAYS; return; }
  local v
  v="$(project_setting "$1" stale_days)" || { print -r -- 30; return; }
  [[ "$v" == <1-> ]] && { print -r -- "$v"; return; }
  warn "ignoring invalid stale_days value: $v (expected a positive integer)"
  print -r -- 30
}

# _status_targets: "name<TAB>project<TAB>repo_path" for every repo in scope.
_status_targets() {
  if [[ -n "$ST_REPO" ]]; then
    local r; r="$(resolve_repo "$ST_REPO")" || exit $?
    print -r -- "$ST_REPO"$'\t'"${r%%$'\t'*}"$'\t'"${r#*$'\t'}"
  else
    all_repos "$WT_PROJECT_OPT"
  fi
}

# _status_collect_one <name> <project> <repo_path> <stale_days> <out_prefix>: one repo's
# records into <out_prefix>.rows, its reason lines into <out_prefix>.notes.
_status_collect_one() {
  local name="$1" project="$2" rp="$3" days="$4" out="$5"
  {
    if (( ST_FETCH )); then
      wt_fetch_origin "$rp" >/dev/null 2>&1 || print -u2 -r -- "could not fetch origin; showing local refs"
    fi
    (( ST_OFFLINE )) || forge_pr_rows "$rp" > "$out.prs"
    status_collect_repo "$project" "$name" "$rp" "$days" "$out.prs" > "$out.rows"
  } 2> "$out.notes"
}

# _status_collect <notes_file>: records for every repo in scope on stdout, in config order
# however the jobs finish; "repo: reason" lines appended to <notes_file>.
_status_collect() {
  local notes_file="$1" out tmp t name project rp l
  out="$(_status_targets)" || exit $?
  local -a targets names; targets=("${(@f)out}")
  local -A days
  tmp="$(mktemp -d 2>/dev/null)" || die "could not create a temp directory"
  local -i i=0 j n=0
  for t in "${targets[@]}"; do [[ -n "$t" ]] && (( ++n )); done
  # One forge detection per host, before the jobs fork and inherit WT_FORGE_KINDS.
  if (( ! ST_OFFLINE )); then
    for t in "${targets[@]}"; do
      [[ -n "$t" ]] || continue
      IFS=$'\t' read -r name project rp <<< "$t"
      forge_host_path "$(git -C "$rp" remote get-url origin 2>/dev/null)" 2>/dev/null || continue
      forge_kind "${reply[1]}" >/dev/null
    done
  fi
  for t in "${targets[@]}"; do
    [[ -n "$t" ]] || continue
    IFS=$'\t' read -r name project rp <<< "$t"
    (( ${+days[$project]} )) || days[$project]="$(status_stale_days "$project")"
    names[++i]="$name"
    status_pool_wait $WT_STATUS_MAX_JOBS
    _status_collect_one "$name" "$project" "$rp" "${days[$project]}" "$tmp/$i" &
    (( ST_PROGRESS && n > WT_STATUS_MAX_JOBS && i % WT_STATUS_MAX_JOBS == 0 )) && ui_progress $i $n "collecting"
  done
  wait
  for (( j = 1; j <= i; j++ )); do
    [[ -s "$tmp/$j.rows" ]] && cat "$tmp/$j.rows"
    [[ -s "$tmp/$j.notes" ]] || continue
    while IFS= read -r l; do
      [[ -n "$l" ]] && print -r -- "${names[j]}: $l"
    done < "$tmp/$j.notes" >> "$notes_file"
  done
  rm -rf "$tmp"
}

# _status_sort: records on stdin -> worktrees, branches, orphans, main checkouts, errors;
# oldest first within each (activity, or last commit for branches; unknown last). Main
# checkouts are never cleanup candidates, so they go below the rows that are.
_status_sort() {
  local line ts
  local -a f
  local -i rank
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    f=("${(@ps:\t:)line}")
    case "${f[1]}" in worktree) rank=1 ;; branch) rank=2 ;; orphan) rank=3 ;; main) rank=4 ;; *) rank=5 ;; esac
    ts="${f[11]}"; [[ "${f[1]}" == branch ]] && ts="${f[13]}"
    [[ "$ts" == <-> ]] || ts=9999999999
    print -r -- "$rank"$'\t'"$ts"$'\t'"$line"
  done | sort -t $'\t' -k1,1n -k2,2n -s | cut -f3-
}

_status_filter() {
  local line
  local -a f
  while IFS= read -r line; do
    f=("${(@ps:\t:)line}")
    (( ! ST_STALE_FILTER )) || [[ "${f[9]}" == (safe|stale) ]] && print -r -- "$line"
  done
  return 0
}

# _status_records <notes_file>: collected, sorted and filtered records.
_status_records() {
  setopt localoptions pipefail
  _status_collect "$1" | _status_sort | _status_filter
}

# _status_display <record>: reply=(mark repo name active commit state pr tags).
_status_display() {
  local -a f state
  f=("${(@ps:\t:)1}")
  local mark=' ' name pr=- active=- commit=-
  local -i now=$EPOCHSECONDS
  case "${f[9]}" in safe) mark='✓' ;; stale) mark='●' ;; dirty) mark='!' ;; esac
  case "${f[1]}" in
    error)  mark='?' name="${f[26]}" ;;
    orphan) name="${f[6]}/${f[7]}" ;;
    *)      name="${f[8]}"; [[ "$name" == - ]] && name="(detached) ${f[5]:t}" ;;
  esac
  [[ "${f[1]}" == (main|orphan|error) ]] && state+=("${f[1]}")
  [[ " ${f[10]} " == *" external "* ]] && state+=(external)
  (( f[14] )) && [[ "${f[1]}" != main ]] && state+=(merged)
  (( f[15] )) && state+=(gone)
  case "${f[16]}" in real) state+=(dirty) ;; unknown) state+=('dirty?') ;; esac
  (( f[21] )) && state+=(locked)
  (( f[22] )) && state+=(prunable)
  [[ "${f[17]}" == <1-> ]] && state+=("↑${f[17]}")
  [[ "${f[18]}" == <1-> ]] && state+=("↓${f[18]}")
  [[ "${f[23]}" != - ]] && pr="${f[23]} ${f[24]}"
  [[ "${f[11]}" == <-> ]] && { status_fmt_age $(( now - f[11] )); active=$REPLY; }
  [[ "${f[13]}" == <-> ]] && { status_fmt_age $(( now - f[13] )); commit=$REPLY; }
  reply=("$mark" "${f[3]}" "$name" "$active" "$commit" "${${(j: :)state}:--}" "$pr" "${f[10]/#-/}")
}

# _status_format <records>: ST_RECS (records), ST_LINES (aligned display lines, colored when
# ui_init enabled color) and ST_HEADER (matching column header). The TAGS column is what
# fzf's query (and ctrl-s) matches "stale", "gone" etc. against: fzf only searches what
# --with-nth displays.
_status_format() {
  local line c
  local -a d w
  local -i k r
  w=(1 4 6 6 6 5 2 4)
  ST_RECS=() ST_LINES=()
  for line in "${(@f)1}"; do
    [[ -n "$line" ]] || continue
    _status_display "$line"
    ST_RECS+=("$line"); d+=("${reply[@]}")
    for (( k = 2; k <= 8; k++ )); do (( ${#reply[k]} > w[k] )) && w[k]=${#reply[k]}; done
  done
  ST_HEADER="  ${(r:w[2]:):-REPO}  ${(r:w[3]:):-BRANCH}  ${(l:w[4]:):-ACTIVE}  ${(l:w[5]:):-COMMIT}  ${(r:w[6]:):-STATE}  ${(r:w[7]:):-PR}  TAGS"
  for (( r = 0; r < ${#ST_RECS}; r++ )); do
    case "${d[r*8+1]}" in
      '✓') c="$WT_C_OK" ;; '●') c="$WT_C_WARN" ;; '!'|'?') c="$WT_C_ERR" ;; *) c='' ;;
    esac
    ST_LINES+=("$c${d[r*8+1]}$WT_C_RESET ${(r:w[2]:)d[r*8+2]}  ${(r:w[3]:)d[r*8+3]}  ${(l:w[4]:)d[r*8+4]}  ${(l:w[5]:)d[r*8+5]}  ${(r:w[6]:)d[r*8+6]}  ${(r:w[7]:)d[r*8+7]}  $WT_C_DIM${d[r*8+8]}$WT_C_RESET")
  done
}

_status_print_notes() {
  local l
  [[ -s "$1" ]] || return 0
  while IFS= read -r l; do warn "note: $l"; done < "$1"
}

_status_render_table() {
  local records="$1" notes_file="$2"
  if [[ -z "$records" ]]; then
    warn "no worktrees or branches found"
  else
    _status_format "$records"
    print -r -- "$ST_HEADER"
    print -rl -- "${ST_LINES[@]}"
  fi
  _status_print_notes "$notes_file"
}

# _status_jstr <value>: REPLY = JSON string literal, null for "-".
_status_jstr() {
  [[ "$1" == - ]] && { REPLY=null; return; }
  local s="$1" out='' c
  local -i i
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  if [[ "$s" == *[[:cntrl:]]* ]]; then
    for (( i = 1; i <= ${#s}; i++ )); do
      c="${s[i]}"
      if [[ "$c" == [[:cntrl:]] ]]; then printf -v c '\\u%04x' "'$c"; fi
      out+="$c"
    done
    s="$out"
  fi
  REPLY="\"$s\""
}

_status_render_json() {
  local records="$1" notes_file="$2" line sep='' obj t
  local -a f
  local -i now=$EPOCHSECONDS
  local -a tags
  print -rn -- '{"notes":['
  if [[ -s "$notes_file" ]]; then
    while IFS= read -r line; do
      _status_jstr "$line"; print -rn -- "$sep$REPLY"; sep=','
    done < "$notes_file"
  fi
  print -rn -- '],"rows":['
  sep=''
  for line in "${(@f)records}"; do
    [[ -n "$line" ]] || continue
    f=("${(@ps:\t:)line}")
    obj=''
    for t in type:1 project:2 repo:3 path:5 kind:6 ticket:7 branch:8 flag:9; do
      _status_jstr "${f[${t#*:}]}"; obj+="\"${t%%:*}\":$REPLY,"
    done
    tags=(); [[ "${f[10]}" != - ]] && tags=(${=f[10]})
    obj+='"tags":['
    for t in "${tags[@]}"; do obj+="\"$t\","; done
    obj="${obj%,}],"
    [[ "${f[11]}" == <-> ]] && obj+="\"active_age_s\":$(( now - f[11] ))," || obj+='"active_age_s":null,'
    [[ "${f[13]}" == <-> ]] && obj+="\"commit_age_s\":$(( now - f[13] ))," || obj+='"commit_age_s":null,'
    [[ "${f[12]}" == <-> ]] && obj+="\"created_at\":${f[12]}," || obj+='"created_at":null,'
    (( f[14] )) && obj+='"merged":true,' || obj+='"merged":false,'
    (( f[15] )) && obj+='"gone":true,' || obj+='"gone":false,'
    _status_jstr "${f[16]}"; obj+="\"dirty\":$REPLY,"
    for t in ahead:17 behind:18 base_ahead:19 base_behind:20; do
      [[ "${f[${t#*:}]}" == <-> ]] && obj+="\"${t%%:*}\":${f[${t#*:}]}," || obj+="\"${t%%:*}\":null,"
    done
    (( f[21] )) && obj+='"locked":true,' || obj+='"locked":false,'
    (( f[22] )) && obj+='"prunable":true,' || obj+='"prunable":false,'
    if [[ "${f[23]}" != - ]]; then
      _status_jstr "${f[24]}"; obj+="\"pr\":{\"number\":${f[23]#?},\"state\":$REPLY,"
      _status_jstr "${f[25]}"; obj+="\"url\":$REPLY},"
    else
      obj+='"pr":null,'
    fi
    _status_jstr "${f[26]}"; obj+="\"note\":$REPLY"
    print -rn -- "$sep{$obj}"; sep=','
  done
  print -r -- ']}'
}

# Field 27 of each fzf line is the display text; 1-26 are the record, which every binding
# receives whole through {} so nothing re-parses what is on screen.
_status_fzf_input() {
  local -i k
  for (( k = 1; k <= ${#ST_RECS}; k++ )); do print -r -- "${ST_RECS[k]}"$'\t'"${ST_LINES[k]}"; done
}

cmd_status() {
  require_config
  _status_parse_opts "$@"
  local notes_file records
  local -i interactive=0 rc
  if (( ! ST_JSON && ! ST_PLAIN )) && [[ -t 0 ]] && { [[ -t 1 ]] || (( WT_CAN_CD )); }; then
    _status_fzf_ok && interactive=1
  fi
  # The wrapper captures stdout to find a cd target, but it still lands on the terminal.
  (( interactive || WT_CAN_CD )) && ui_init force
  [[ -t 2 ]] && ST_PROGRESS=1
  notes_file="$(mktemp 2>/dev/null)" || die "could not create a temp file"
  records="$(_status_records "$notes_file")" || { rc=$?; rm -f "$notes_file"; exit $rc; }
  if (( ST_JSON )); then _status_render_json "$records" "$notes_file"
  elif (( interactive )); then _status_run_fzf "$records" "$notes_file"
  else _status_render_table "$records" "$notes_file"; fi
  rm -f "$notes_file"
}

# __status-rows [status options]: the fzf input for a reload.
cmd___status-rows() {
  require_config
  _status_parse_opts "$@"
  ui_init force
  local notes_file records
  local -i rc
  notes_file="$(mktemp 2>/dev/null)" || die "could not create a temp file"
  records="$(_status_records "$notes_file")" || { rc=$?; rm -f "$notes_file"; exit $rc; }
  rm -f "$notes_file"
  [[ -n "$records" ]] || return 0
  _status_format "$records"
  _status_fzf_input
}

# _status_fzf_ok: fzf is installed and new enough for the bindings below.
_status_fzf_ok() {
  (( $+functions[fzf] || $+commands[fzf] )) || return 1
  local v; v="$(fzf --version 2>/dev/null)"; v="${v%% *}"
  local -a have want
  have=("${(@s:.:)v}") want=("${(@s:.:)WT_STATUS_FZF_MIN}")
  [[ "${have[1]:-}" == <-> && "${have[2]:-}" == <-> ]] || { warn "could not read fzf's version; showing a table instead"; return 1; }
  (( have[1] > want[1] || (have[1] == want[1] && have[2] >= want[2]) )) && return 0
  warn "fzf $v is older than $WT_STATUS_FZF_MIN; showing a table instead"
  return 1
}

_status_preview_window() {
  local size; size="$({ stty size < /dev/tty; } 2>/dev/null)"
  (( ${${size##* }:-0} >= 120 )) && print -r -- 'right,50%' || print -r -- 'down,50%'
}

# _status_reload_args: reply = the options that reproduce this listing in __status-rows.
_status_reload_args() {
  reply=()
  [[ -n "$WT_PROJECT_OPT" ]] && reply+=(--project "$WT_PROJECT_OPT")
  (( WT_COLOR )) || reply+=(--no-color)
  [[ -n "$ST_REPO" ]] && reply+=("$ST_REPO")
  if (( ST_STALE_FILTER )); then
    reply+=(--stale)
    (( ST_STALE_DAYS >= 0 )) && reply+=("$ST_STALE_DAYS")
  fi
  (( ST_OFFLINE )) && reply+=(--offline)
  return 0
}

_status_run_fzf() {
  local records="$1" notes_file="$2" bin="$WORKYTREE_HOME/bin/workytree" line sel here_repo='' l
  local -a f args
  local -i best=0
  # The repo whose worktree this shell stands in: where the wrapper should send the shell if
  # ctrl-d removes that worktree out from under it.
  for line in "${(@f)records}"; do
    f=("${(@ps:\t:)line}")
    [[ "${f[1]}" == (main|worktree) && "${PWD:A}/" == "${f[5]:A}/"* ]] || continue
    (( ${#f[5]} > best )) && { best=${#f[5]}; here_repo="${f[4]}"; }
  done
  _status_reload_args; args=("${reply[@]}")
  local qbin="${(q)bin}"
  local rows_cmd="$qbin __status-rows${args:+ ${(j: :)${(q)args[@]}}}"
  local fetch_cmd="$rows_cmd"; (( ST_OFFLINE )) || fetch_cmd+=" --fetch"
  local header="enter: cd · ctrl-d: remove · ctrl-o: open PR · ctrl-r: refresh with fetch · ctrl-s: stale only"
  _status_format "$records"
  header+=$'\n'"$ST_HEADER"
  if [[ -s "$notes_file" ]]; then
    while IFS= read -r l; do header+=$'\n'"note: $l"; done < "$notes_file"
  fi
  # fzf runs bindings through $SHELL -c, and they are written for sh, not the user's shell.
  sel="$(_status_fzf_input | SHELL=/bin/sh fzf --ansi --no-sort --layout=reverse \
    --delimiter=$'\t' --with-nth=27 --header="$header" \
    --preview="$qbin __status-preview {}" --preview-window="$(_status_preview_window)" \
    --bind="ctrl-d:execute($qbin __status-action remove {})+reload($rows_cmd)" \
    --bind="ctrl-o:execute-silent($qbin __status-action open {})" \
    --bind="ctrl-r:reload($fetch_cmd)" \
    --bind="ctrl-s:transform-query(if [ {q} = stale ]; then echo; else echo stale; fi)")"
  if [[ -n "$sel" ]]; then
    f=("${(@ps:\t:)sel}")
    if [[ "${f[1]}" == (main|worktree) && -d "${f[5]}" ]]; then print -r -- "${f[5]}"; return 0; fi
  fi
  [[ -n "$here_repo" && ! -d "$PWD" ]] && print -r -- "$here_repo"
  return 0
}

_status_kb() {
  local -i kb=$1
  if (( kb >= 1048576 )); then print -r -- "$(( kb / 1048576 )) GB"
  elif (( kb >= 1024 )); then print -r -- "$(( kb / 1024 )) MB"
  else print -r -- "$kb KB"; fi
}

_status_when() {
  [[ "$1" == <-> ]] || { print -r -- unknown; return; }
  status_fmt_age $(( EPOCHSECONDS - $1 ))
  print -r -- "$(strftime '%Y-%m-%d %H:%M' $1) ($REPLY ago)"
}

# __status-preview <fzf line>: details for the highlighted row.
cmd___status-preview() {
  local -a f; f=("${(@ps:\t:)${1:-}}")
  (( ${#f} >= 26 )) || return 0
  local type="${f[1]}" repo_path="${f[4]}" p="${f[5]}" br="${f[8]}" kb created
  print -r -- "$type · ${f[3]}${f[10]:+ · ${f[10]}}"
  [[ "$p" != - ]] && print -r -- "path      $p"
  if [[ "$type" == error ]]; then print -r -- "error     ${f[26]}"; return 0; fi
  [[ "$type" == (main|worktree) ]] && print -r -- "created   $(_status_when "${f[12]}")"
  [[ "$type" != branch ]] && print -r -- "active    $(_status_when "${f[11]}")"
  if [[ "$br" != - ]]; then
    created="$(git -C "$repo_path" reflog show --date=unix --format=%gd "refs/heads/$br" -- 2>/dev/null | tail -1)"
    created="${${created##*\{}%\}}"
    print -r -- "branch    $br"
    print -r -- "  created     $(_status_when "$created")"
    print -r -- "  last commit $(_status_when "${f[13]}")"
    [[ "${f[17]}" == <-> ]] && print -r -- "  upstream    ↑${f[17]} ↓${f[18]}"
    (( f[15] )) && print -r -- "  upstream    gone (deleted on the remote)"
    [[ "${f[19]}" == <-> ]] && print -r -- "  base        ↑${f[19]} ↓${f[20]}"
  fi
  [[ "${f[23]}" != - ]] && print -r -- "PR        ${f[23]} ${f[24]}  ${f[25]}"
  case "$type" in
    main|worktree)
      [[ -d "$p" ]] || return 0
      local changes; changes="$(GIT_OPTIONAL_LOCKS=0 git -C "$p" status --short 2>&1)"
      print; print -r -- "changes:"
      if [[ -z "$changes" ]]; then print -r -- "  (none)"
      else
        local -a cl; cl=("${(@f)changes}")
        print -rl -- "${(@)cl[1,15]/#/  }"
        (( ${#cl} > 15 )) && print -r -- "  … $(( ${#cl} - 15 )) more"
      fi
      print; print -r -- "recent commits:"
      git -C "$p" log --oneline -5 2>/dev/null | sed 's/^/  /' ;;
    branch)
      print; print -r -- "recent commits:"
      git -C "$repo_path" log --oneline -5 "refs/heads/$br" -- 2>/dev/null | sed 's/^/  /'
      print; print -r -- "delete it yourself: git -C ${(q)repo_path} branch -d ${(q)br}" ;;
    orphan)
      print
      if dir_is_cruft_only "$p"; then print -r -- "holds only IDE/OS files; \`wt prune ${f[3]}\` removes it"
      else print -r -- "holds real files; inspect before deleting"; fi ;;
  esac
  if [[ "$p" != - && -d "$p" ]]; then
    kb="$(du -sk -- "$p" 2>/dev/null)"; kb="${kb%%[[:space:]]*}"
    [[ "$kb" == <-> ]] && { print; print -r -- "size      $(_status_kb $kb)"; }
  fi
  return 0
}

_status_pause() {
  { : < /dev/tty; } 2>/dev/null || return 0
  print -nu2 -- "press any key to return to the list…"
  read -rsk1 < /dev/tty
  print -u2
}

# __status-action remove|open <fzf line>: what ctrl-d / ctrl-o do to the highlighted row.
cmd___status-action() {
  local action="${1:-}"
  local -a f; f=("${(@ps:\t:)${2:-}}")
  (( ${#f} >= 26 )) || usage_error "usage: workytree __status-action remove|open <record>"
  case "$action" in
    remove)
      if [[ "${f[1]}" == worktree && "${f[6]}" != - ]]; then
        ( WT_PROJECT_OPT="${f[2]}"; cmd_remove "${f[3]}" "${f[6]}" "${f[7]}" )
      else
        warn "only worktrees under worktree_root can be removed from here"
        [[ "${f[1]}" == branch ]] && hint "delete the branch yourself: git -C ${(q)f[4]} branch -d ${(q)f[8]}"
        [[ "${f[1]}" == orphan ]] && hint "wt prune ${f[3]} removes orphan directories that hold only IDE/OS files"
      fi
      _status_pause ;;
    open)
      [[ "${f[25]}" != - ]] || return 0
      if (( $+commands[open] )); then open "${f[25]}"
      elif (( $+commands[xdg-open] )); then xdg-open "${f[25]}" >/dev/null 2>&1
      fi ;;
    *) usage_error "usage: workytree __status-action remove|open <record>" ;;
  esac
  return 0
}

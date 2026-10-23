# `status --branches`: renderers, fzf arguments and the details pane for the 17-field branch
# records of lib/branches.zsh. Callers pick these over the worktree ones by ST_BRANCHES, never by
# record shape.

# _branches_display <record>: reply=(mark repo branch local remote why commit class).
_branches_display() {
  local -a f
  f=("${(@ps:\t:)1}")
  local mark=' ' branch="${f[5]:--}" lcl=- rmt=- commit=- cls="${f[11]:--}"
  local -i now=$EPOCHSECONDS
  case "$cls" in
    safe) mark='✓' ;;
    force) [[ "${f[10]:-}" == stale ]] && mark='●' || mark='!' ;;
    *) cls=keep ;;
  esac
  [[ "$branch" == - ]] && { branch="${f[17]:--}"; mark='?'; }
  [[ "${f[6]:--}" != - ]] && lcl='●'
  if [[ "${f[7]:--}" != - ]]; then
    case "${f[9]:--}" in me) rmt='● me' ;; teammate) rmt='● teammate' ;; *) rmt='●' ;; esac
  elif [[ "${f[8]:-0}" == 1 ]]; then
    rmt=gone
  fi
  [[ "${f[12]:--}" == <-> ]] && { status_fmt_age $(( now - f[12] )); commit=$REPLY; }
  reply=("$mark" "${f[3]:--}" "$branch" "$lcl" "$rmt" "${f[10]:--}" "$commit" "$cls")
}

# _branches_format <records>: ST_RECS, ST_LINES and ST_HEADER like _status_format. The line
# ends in the class word with nothing after it.
_branches_format() {
  local line c
  local -a d w
  local -i k r
  w=(1 4 6 5 6 3 6)
  ST_RECS=() ST_LINES=()
  for line in "${(@f)1}"; do
    [[ -n "$line" ]] || continue
    _branches_display "$line"
    ST_RECS+=("$line"); d+=("${reply[@]}")
    for (( k = 2; k <= 7; k++ )); do (( ${#reply[k]} > w[k] )) && w[k]=${#reply[k]}; done
  done
  ST_HEADER="  ${(r:w[2]:):-REPO}  ${(r:w[3]:):-BRANCH}  ${(r:w[4]:):-LOCAL}  ${(r:w[5]:):-REMOTE}  ${(r:w[6]:):-WHY}  ${(l:w[7]:):-COMMIT}  CLASS"
  for (( r = 0; r < ${#ST_RECS}; r++ )); do
    case "${d[r*8+1]}" in
      '✓') c="$WT_C_OK" ;; '●') c="$WT_C_WARN" ;; '!'|'?') c="$WT_C_ERR" ;; *) c='' ;;
    esac
    ST_LINES+=("$c${d[r*8+1]}$WT_C_RESET ${(r:w[2]:)d[r*8+2]}  ${(r:w[3]:)d[r*8+3]}  ${(r:w[4]:)d[r*8+4]}  ${(r:w[5]:)d[r*8+5]}  ${(r:w[6]:)d[r*8+6]}  ${(l:w[7]:)d[r*8+7]}  $WT_C_DIM${d[r*8+8]}$WT_C_RESET")
  done
}

_branches_render_table() {
  local records="$1" notes_file="$2"
  if [[ -z "$records" ]]; then
    warn "no branches found"
  else
    _branches_format "$records"
    print -r -- "$ST_HEADER"
    print -rl -- "${ST_LINES[@]}"
  fi
  _status_print_notes "$notes_file"
}

_branches_render_json() {
  local records="$1" notes_file="$2" line sep='' obj t s
  local -a f
  local -i now=$EPOCHSECONDS
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
    while (( ${#f} < 17 )); do f+=(-); done
    obj=''
    for t in type:1 project:2 repo:3 branch:5; do
      _status_jstr "${f[${t#*:}]}"; obj+="\"${t%%:*}\":$REPLY,"
    done
    if [[ "${f[6]}" != - ]]; then
      (( f[8] )) && s=true || s=false
      obj+="\"local\":{\"sha\":\"${f[6]}\",\"gone\":$s},"
    else
      obj+='"local":null,'
    fi
    if [[ "${f[7]}" != - ]]; then
      _status_jstr "${f[9]}"; obj+="\"remote\":{\"sha\":\"${f[7]}\",\"owner\":$REPLY},"
    else
      obj+='"remote":null,'
    fi
    for t in why:10 class:11; do
      _status_jstr "${f[${t#*:}]}"; obj+="\"${t%%:*}\":$REPLY,"
    done
    [[ "${f[12]}" == <-> ]] && obj+="\"commit_age_s\":$(( now - f[12] ))," || obj+='"commit_age_s":null,'
    [[ "${f[13]}" == <-> ]] && obj+="\"base_ahead\":${f[13]}," || obj+='"base_ahead":null,'
    _status_jstr "${f[14]}"; obj+="\"key\":$REPLY,"
    if [[ "${f[15]}" != - ]]; then
      _status_jstr "${f[16]}"; obj+="\"pr\":{\"number\":${f[15]#?},\"state\":$REPLY},"
    else
      obj+='"pr":null,'
    fi
    _status_jstr "${f[17]}"; obj+="\"note\":$REPLY"
    print -rn -- "$sep{$obj}"; sep=','
  done
  print -r -- ']}'
}

# _branches_fetch_age <repo_path...>: REPLY = seconds since the fetch of the repo fetched
# longest ago ("-" when none was), reply = (<repos> <repos never fetched>). A repo's fetch is
# the newest non-empty FETCH_HEAD among its checkouts; a failed fetch leaves it empty.
_branches_fetch_age() {
  local rp line p fh
  local -a t
  local -i n=0 never=0 newest oldest=-1
  for rp in "$@"; do
    (( ++n )); newest=0
    for line in "${(@f)$(git -C "$rp" worktree list --porcelain 2>/dev/null)}"; do
      [[ "$line" == "worktree "* ]] || continue
      p="${line#worktree }"
      fh="$(git -C "$p" rev-parse --path-format=absolute --git-path FETCH_HEAD 2>/dev/null)" || fh="$p/.git/FETCH_HEAD"
      [[ -s "$fh" ]] && zstat -A t +mtime -- "$fh" 2>/dev/null || continue
      (( t[1] > newest )) && newest=${t[1]}
    done
    if (( ! newest )); then (( ++never ))
    elif (( oldest < 0 || newest < oldest )); then oldest=$newest; fi
  done
  if (( oldest < 0 )); then REPLY=-; else REPLY=$(( EPOCHSECONDS - oldest )); fi
  reply=($n $never)
}

# _branches_fzf_header: REPLY = the key line and the fetch-age line of the branch list.
_branches_fzf_header() {
  local keys="tab: mark · alt-d: delete marked · ctrl-r: refresh with fetch · ctrl-s: safe only · ctrl-b: worktrees"
  local out line age ages
  local -a rps
  local -i fetched never
  REPLY="$keys"
  out="$(_status_targets 2>/dev/null)" || return 0
  for line in "${(@f)out}"; do [[ -n "$line" ]] && rps+=("${${(@ps:\t:)line}[3]}"); done
  (( ${#rps} )) || return 0
  _branches_fetch_age "${rps[@]}"
  age="$REPLY" never=${reply[2]} fetched=$(( reply[1] - reply[2] ))
  if [[ "$age" == - ]]; then
    ages="refs never fetched in $never repo${${never:#1}:+s}"
  else
    status_fmt_age $age
    ages="refs fetched $REPLY ago (oldest) in $fetched repo${${fetched:#1}:+s}"
    (( never )) && ages+=", $never repo${${never:#1}:+s} never fetched"
  fi
  REPLY="$keys"$'\n'"$ages — ctrl-r before deleting"
}

# _branches_fzf_args <quoted bin> <quoted reload args>: reply = the branch list's fzf
# arguments, REPLY = its header lines above the column header.
_branches_fzf_args() {
  local qbin="$1" qargs="$2" rows fetch
  rows="$qbin __status-rows$qargs --branches"
  fetch="$rows"; (( ST_OFFLINE )) || fetch+=" --fetch"
  _branches_fzf_header
  reply=(--multi --with-nth=18 --bind=enter:ignore
    --preview="$qbin __status-branch-preview {}"
    --bind="alt-d:execute($qbin __status-action delete-branches {+f}$qargs)+deselect-all+reload($rows)"
    --bind="ctrl-r:reload($fetch)"
    --bind="ctrl-s:transform-query(if [ {q} = 'safe\$' ]; then echo; else echo 'safe\$'; fi)")
}

# __status-branch-preview <fzf line>: both sides of the highlighted branch row, from local
# refs only.
cmd___status-branch-preview() {
  local -a f; f=("${(@ps:\t:)${1:-}}")
  (( ${#f} >= 17 )) || return 0
  local rp="${f[4]}" side label sha extra
  if [[ "${f[1]}" == error ]]; then print -r -- "error · ${f[3]}"; print -r -- "${f[17]}"; return 0; fi
  print -r -- "${f[5]} · ${f[3]} · ${f[10]}"
  print -r -- "note      ${f[17]}"
  [[ "${f[15]}" != - ]] && print -r -- "PR        ${f[15]} ${f[16]}"
  for side in local:6 origin:7; do
    label="${side%%:*}" sha="${f[${side#*:}]}" extra=''
    print
    if [[ "$sha" == - ]]; then print -r -- "${(r:10:)label}-"; continue; fi
    [[ "$label" == local ]] && (( f[8] )) && extra='  (upstream gone)'
    [[ "$label" == origin && "${f[9]}" != - ]] && extra="  (${f[9]})"
    print -r -- "${(r:10:)label}$sha$extra"
    print -r -- "  author  $(git -C "$rp" log -1 --format='%an <%ae>' "$sha" -- 2>/dev/null)"
    git -C "$rp" log --oneline -5 "$sha" -- 2>/dev/null | sed 's/^/  /'
  done
  return 0
}

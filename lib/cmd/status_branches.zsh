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

# BR_PLAN_AHEAD[k] is BR_PLAN[k]'s base_ahead: append to both or neither (_br_plan_add).
typeset -ga BR_PLAN BR_PLAN_AHEAD BR_APPROVED
typeset -gA BR_REPO_NAME

# _branches_remote_all_mine <repo_path> <base_ref|-> <remote_sha> <user_email>: rc 0 when the
# tip and every commit of base..sha (only the tip when base is -) were authored by user_email,
# ignoring case.
_branches_remote_all_mine() {
  local rp="$1" base="$2" sha="$3" email="${(L)4}" out='' a
  [[ -n "$email" ]] || return 1
  if [[ "$base" != - ]]; then
    out="$(git -C "$rp" log --format=%ae "$sha" --not "$base" -- 2>/dev/null)" || return 1
  fi
  if [[ -z "$out" ]]; then
    out="$(git -C "$rp" log -1 --format=%ae "$sha" -- 2>/dev/null)" || return 1
  fi
  [[ -n "$out" ]] || return 1
  for a in "${(@f)out}"; do [[ "${(L)a}" == "$email" ]] || return 1; done
  return 0
}

# _br_plan_add <class> <repo_path> <branch> <target> <local_sha> <remote_sha> <reason> [ahead]
_br_plan_add() {
  BR_PLAN+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5"$'\t'"$6"$'\t'"${7//$'\t'/ }")
  BR_PLAN_AHEAD+=("${8:--}")
}

# _br_plan_unlisted <repo_path> <branch> <error note|->: a skip entry for a marked name the
# fresh collection left out.
_br_plan_unlisted() {
  local rp="$1" b="$2" reason="$3" lsha rsha target=-
  lsha="$(git -C "$rp" rev-parse -q --verify "refs/heads/$b" 2>/dev/null)" || lsha=-
  rsha="$(git -C "$rp" rev-parse -q --verify "refs/remotes/origin/$b" 2>/dev/null)" || rsha=-
  if [[ "$lsha" != - && "$rsha" != - ]]; then target=local+origin
  elif [[ "$lsha" != - ]]; then target=local
  elif [[ "$rsha" != - ]]; then target=origin; fi
  if [[ "$reason" == - ]]; then
    if [[ "$target" == - ]]; then reason="no longer exists"
    elif [[ $'\n'"$(git -C "$rp" worktree list --porcelain 2>/dev/null)"$'\n' == *$'\nbranch refs/heads/'"$b"$'\n'* ]]; then
      reason="checked out in a worktree"
    else reason="base branch"; fi
  fi
  _br_plan_add skip "$rp" "$b" "$target" "$lsha" "$rsha" "$reason"
}

# _branches_plan <records_file>: BR_PLAN from the marked fzf lines, re-judged from current refs
# (after fetching origin where a remote or pushed row needs it). BR_REPO_NAME maps repo_path
# to the repo name. Of each line only project, repo, repo_path, branch, owner and why are read.
_branches_plan() {
  local file="$1" line rp b key tmp prs days l base email rec lsha rsha owner why cls note ahead target unfetched
  local -a f order marked_rp marked_b
  local -A project seen need_fetch fetched frec err_note days_of base_of email_of
  local -i i k tl tr
  BR_PLAN=() BR_PLAN_AHEAD=() BR_REPO_NAME=()
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    f=("${(@ps:\t:)line}")
    (( ${#f} >= 10 )) || continue
    rp="${f[4]}" b="${f[5]}"
    # An error record has no branch, and "-" is not a valid branch name.
    [[ "$rp" == - || "$b" == - ]] && continue
    if (( ! ${+project[$rp]} )); then
      order+=("$rp"); project[$rp]="${f[2]}"; BR_REPO_NAME[$rp]="${f[3]}"
    fi
    [[ "${f[9]}" == me || "${f[10]}" == pushed ]] && need_fetch[$rp]=1
    key="$rp"$'\t'"$b"
    (( ${+seen[$key]} )) && continue
    seen[$key]=1; marked_rp+=("$rp"); marked_b+=("$b")
  done < "$file"
  (( ${#order} )) || return 0

  tmp="$(mktemp -d 2>/dev/null)" || die "could not create a temp directory"
  i=0
  for rp in "${order[@]}"; do
    (( ++i ))
    fetched[$rp]=none
    # wt_fetch_origin succeeds without an origin, which would vouch for leftover origin refs.
    if ! git -C "$rp" remote get-url origin >/dev/null 2>&1; then fetched[$rp]=noremote
    elif (( ${+need_fetch[$rp]} )); then
      if wt_fetch_origin "$rp"; then fetched[$rp]=ok; else fetched[$rp]=failed; fi
    fi
    prs=''
    : > "$tmp/$i.err"
    if (( ! ST_OFFLINE )) && forge_pr_rows "$rp" > "$tmp/$i.prs" 2>> "$tmp/$i.err"; then prs="$tmp/$i.prs"; fi
    (( ${+days_of[${project[$rp]}]} )) || days_of[${project[$rp]}]="$(status_stale_days "${project[$rp]}")"
    days="${days_of[${project[$rp]}]}"
    for line in ${(f)"$(status_collect_branches "${project[$rp]}" "${BR_REPO_NAME[$rp]}" "$rp" "$days" ${prs:+"$prs"} 2>> "$tmp/$i.err")"}; do
      f=("${(@ps:\t:)line}")
      if [[ "${f[1]}" == error ]]; then err_note[$rp]="${f[17]}"
      else frec[$rp$'\t'${f[5]}]="$line"; fi
    done
    while IFS= read -r l; do [[ -n "$l" ]] && warn "note: ${BR_REPO_NAME[$rp]}: $l"; done < "$tmp/$i.err"
    base="$(status_base_ref "$rp" 2>/dev/null)" || base=-
    base_of[$rp]="$base"
    email_of[$rp]="$(git -C "$rp" config user.email 2>/dev/null)"
  done
  rm -rf "$tmp"

  for (( k = 1; k <= ${#marked_rp}; k++ )); do
    rp="${marked_rp[k]}" b="${marked_b[k]}"
    rec="${frec[$rp$'\t'$b]:-}"
    if [[ -z "$rec" ]]; then _br_plan_unlisted "$rp" "$b" "${err_note[$rp]:--}"; continue; fi
    f=("${(@ps:\t:)rec}")
    lsha="${f[6]}" rsha="${f[7]}" owner="${f[9]}" why="${f[10]}" cls="${f[11]}" ahead="${f[13]}" note="${f[17]}"
    if [[ "$cls" != (safe|force) ]]; then
      target=local+origin
      [[ "$rsha" == - ]] && target=local
      [[ "$lsha" == - ]] && target=origin
      _br_plan_add skip "$rp" "$b" "$target" "$lsha" "$rsha" "$note"
      continue
    fi
    tl=0 tr=0 base="${base_of[$rp]}"
    [[ "$lsha" != - ]] && tl=1
    case "${fetched[$rp]}" in
      ok) unfetched='' ;;
      failed) unfetched="could not fetch origin" ;;
      noremote) unfetched="no origin remote" ;;
      *) unfetched="origin was not fetched" ;;
    esac
    if [[ "$rsha" != - && "$owner" == me ]]; then
      if [[ -n "$unfetched" ]]; then _br_plan_add skip "$rp" "$b" origin - "$rsha" "$unfetched"
      elif [[ "$base" == - ]]; then
        _br_plan_add skip "$rp" "$b" origin - "$rsha" "no base branch, so commits by others cannot be ruled out"
      elif _branches_remote_all_mine "$rp" "$base" "$rsha" "${email_of[$rp]}"; then tr=1
      else _br_plan_add skip "$rp" "$b" origin - "$rsha" "has commits by others"; fi
    fi
    # pushed means "origin keeps every commit", which only a fresh origin ref can say.
    if [[ "$why" == pushed && -n "$unfetched" ]]; then
      cls=force note="$unfetched, so not proven: $note"
    fi
    # The record's base_ahead and note also counted the origin side this plan no longer deletes.
    if (( tl && ! tr )) && [[ "$rsha" != - && "$owner" == me ]]; then
      ahead=-
      if [[ "$base" != - ]]; then
        ahead="$(git -C "$rp" rev-list --count "$lsha" --not "$base" -- 2>/dev/null)" || ahead=-
      fi
      if [[ "$cls" == force ]]; then
        if [[ "$ahead" == <-> ]]; then note="local only, $ahead commits not in ${${base#refs/remotes/}#refs/heads/}"
        else note="local only, an unknown number of commits not in the base"; fi
      fi
    fi
    if (( tl && tr )); then target=local+origin
    elif (( tl )); then target=local
    elif (( tr )); then target=origin
    else continue; fi
    (( tl )) || lsha=-
    (( tr )) || rsha=-
    _br_plan_add "$cls" "$rp" "$b" "$target" "$lsha" "$rsha" "$note" "$ahead"
  done
  return 0
}

# _br_plan_sha <local_sha> <remote_sha>: REPLY = the short sha, local7/remote7 when they differ.
_br_plan_sha() {
  if [[ "$1" != - && "$2" != - && "$1" != "$2" ]]; then REPLY="${1[1,7]}/${2[1,7]}"
  elif [[ "$1" != - ]]; then REPLY="${1[1,7]}"
  elif [[ "$2" != - ]]; then REPLY="${2[1,7]}"
  else REPLY=-; fi
}

# _branches_print_plan: BR_PLAN as the three groups, on stderr.
_branches_print_plan() {
  local e c head
  local -a f
  local -i w1=4 w2=6 w3=6 w4=7 n
  for e in "${BR_PLAN[@]}"; do
    f=("${(@ps:\t:)e}")
    (( ${#BR_REPO_NAME[${f[2]}]} > w1 )) && w1=${#BR_REPO_NAME[${f[2]}]}
    (( ${#f[3]} > w2 )) && w2=${#f[3]}
    (( ${#f[4]} > w3 )) && w3=${#f[4]}
    _br_plan_sha "${f[5]}" "${f[6]}"; (( ${#REPLY} > w4 )) && w4=${#REPLY}
  done
  for c in safe force skip; do
    case "$c" in
      safe) head="safe — merged or its ticket is merged" ;;
      force) head="needs force — commits would exist nowhere else" ;;
      skip) head=skipped ;;
    esac
    print -u2 -r -- "$head"
    n=0
    for e in "${BR_PLAN[@]}"; do
      f=("${(@ps:\t:)e}")
      [[ "${f[1]}" == "$c" ]] || continue
      (( ++n ))
      _br_plan_sha "${f[5]}" "${f[6]}"
      print -u2 -r -- "  ${(r:w1:)BR_REPO_NAME[${f[2]}]}  ${(r:w2:)f[3]}  ${(r:w3:)f[4]}  ${(r:w4:)REPLY}  ${f[7]}"
    done
    (( n )) || print -u2 -r -- "  (none)"
  done
}

# _branches_ask: BR_APPROVED = the safe entries after one yes, plus each force entry its own
# yes approved.
_branches_ask() {
  local ahead
  local -a f safe
  local -i k refs=0
  BR_APPROVED=()
  for (( k = 1; k <= ${#BR_PLAN}; k++ )); do
    f=("${(@ps:\t:)BR_PLAN[k]}")
    [[ "${f[1]}" == safe ]] || continue
    safe+=("${BR_PLAN[k]}")
    if [[ "${f[4]}" == local+origin ]]; then (( refs += 2 )); else (( ++refs )); fi
  done
  (( ${#safe} )) && prompt_confirm "delete the $refs safe refs?" n && BR_APPROVED+=("${safe[@]}")
  for (( k = 1; k <= ${#BR_PLAN}; k++ )); do
    f=("${(@ps:\t:)BR_PLAN[k]}")
    [[ "${f[1]}" == force ]] || continue
    ahead="${BR_PLAN_AHEAD[k]}"; [[ "$ahead" == <-> ]] || ahead="an unknown number of"
    prompt_confirm "force-delete ${f[3]} (${f[4]}) and lose $ahead commits?" n && BR_APPROVED+=("${BR_PLAN[k]}")
  done
  return 0
}

# _branches_delete <records_file>: alt-d. Plan, print, ask.
_branches_delete() {
  _branches_plan "$1"
  BR_APPROVED=()
  if (( ${#BR_PLAN} )); then
    _branches_print_plan
    _branches_ask
  else
    warn "no branch rows marked"
  fi
  _status_pause
  return 0
}

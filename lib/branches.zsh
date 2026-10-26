# `wt status` branch mode: pure classification functions over names, shas and states already
# collected (none of them calls git), and status_collect_branches, which reads those from git.
#
# status_collect_branches emits one record per branch name: 17 TAB-separated fields, "-" for
# every empty value; split with "${(@ps:\t:)line}".
#    1 type        branch|error                10 why        branch_row_why
#    2 project                                 11 class      branch_why_class
#    3 repo                                    12 commit_ts  newest of local and origin
#    4 repo_path                               13 base_ahead largest among the sides to delete
#    5 branch      name without origin/        14 key        ticket key of a backup name,
#    6 local_sha   full sha                                  proven or not
#    7 remote_sha  full sha                    15 pr_ref     PR whose head is this name: an
#                                                            open one, else the latest
#    8 gone        1 when the local upstream   16 pr_state
#                  is gone, else 0             17 note       why, in words; error: git's
#    9 owner       me|teammate|- (no origin)                 first line

branch_protected() {
  setopt localoptions extendedglob
  [[ $1 == (main|master|develop|release/*) ]]
}

branch_backup_name() {
  setopt localoptions extendedglob
  local n=${(L)1}
  [[ $n == (backup/*|*-backup|*-backup-*|*-before-*) ]]
}

# REPLY keeps the original case; a candidate starting with backup/before/pre is skipped.
branch_ticket_key() {
  setopt localoptions extendedglob
  local name=$1 rest cand
  local -i i
  REPLY=
  for (( i = 1; i <= ${#name}; i++ )); do
    (( i > 1 )) && [[ ${name[i-1]} != [/_-] ]] && continue
    rest=${name[i,-1]}
    [[ $rest =~ '^([A-Za-z]{2,}-[0-9]+)([/_-].*)?$' ]] || continue
    cand=$match[1]
    [[ ${(L)cand} == (backup|before|pre)* ]] && continue
    REPLY=$cand
    return 0
  done
  return 1
}

branch_name_has_key() {
  setopt localoptions extendedglob
  local name=${(L)1} key=${(L)2}
  [[ -n $key ]] || return 1
  [[ $name =~ "(^|[/_-])${key}([/_-]|\$)" ]]
}

# branch_ticket_pr <key> <pr_file>: REPLY = open|incomplete|merged|none for the PRs whose head
# has the key, reply = their refs; rc 1 when pr_file is unreadable. Reads <pr_file>.all, every
# PR, when it exists; <pr_file>.truncated means PRs may be missing, so no merge is proven.
branch_ticket_pr() {
  setopt localoptions extendedglob
  local key=$1 pr_file=$2 line src
  local -a f open_refs merged_refs
  reply=()
  REPLY=none
  [[ -r $pr_file ]] || return 1
  src=$pr_file; [[ -r $pr_file.all ]] && src=$pr_file.all
  while IFS= read -r line; do
    f=("${(@ps:\t:)line}")
    branch_name_has_key "${f[1]}" "$key" || continue
    case ${f[3]} in
      open|draft) open_refs+=("${f[2]}") ;;
      merged) merged_refs+=("${f[2]}") ;;
    esac
  done < "$src"
  if (( ${#open_refs} )); then REPLY=open; reply=("${open_refs[@]}")
  elif [[ -e $pr_file.truncated ]]; then REPLY=incomplete
  elif (( ${#merged_refs} )); then REPLY=merged; reply=("${merged_refs[@]}")
  fi
  return 0
}

branch_owner() {
  local author=${${(L)1}//[<>]/} user=${(L)2}
  if [[ -n $user && $author == $user ]]; then REPLY=me; else REPLY=teammate; fi
}

branch_pushed() {
  local branch=$1 local_sha=$2 remote_sha=$3 upstream=$4 track=$5
  [[ -n $local_sha && $local_sha != - && $local_sha == $remote_sha ]] && return 0
  [[ $upstream == "refs/remotes/origin/$branch" && $track != *ahead* ]]
}

branch_side_why() {
  local protected=$1 merged=$2 pushed=$3 backup_ok=$4 gone=$5 age=$6 stale=$7
  if (( protected )); then REPLY=protected
  elif (( merged )); then REPLY=merged
  elif (( pushed )); then REPLY=pushed
  elif (( backup_ok )); then REPLY=backup
  elif (( gone )); then REPLY=gone
  elif [[ $age == <-> && $stale == <-> ]] && (( age > stale )); then REPLY=stale
  else REPLY=unmerged
  fi
}

branch_row_why() {
  local local_why=$1 remote_why=$2 owner=$3 w best= rank=0 r
  local -A order=(merged 1 pushed 2 backup 3 stale 4 gone 5 unmerged 6)
  if [[ $local_why == protected || $remote_why == protected ]]; then
    REPLY=protected; return 0
  fi
  [[ $owner == teammate ]] && remote_why=-
  for w in $local_why $remote_why; do
    [[ $w == - ]] && continue
    r=${order[$w]:-0}
    (( r > rank )) && { rank=$r; best=$w; }
  done
  REPLY=${best:-read-only}
}

branch_why_class() {
  case $1 in
    merged|pushed|backup) REPLY=safe ;;
    gone|stale|unmerged) REPLY=force ;;
    *) REPLY=none ;;
  esac
}

# status_collect_branches <project> <repo> <repo_path> <stale_days> [pr_file]
# Branch records, oldest commit first, on stdout; reason lines on stderr; rc 0. A repo git
# cannot read becomes one error record. Without a readable pr_file nothing is proven by a PR.
status_collect_branches() {
  local project=${1:--} repo=${2:--} repo_path=$3 stale_days=$4 pr_file=${5:-}
  local -i now=$EPOCHSECONDS stale_s=$(( stale_days * 86400 ))
  local porcelain line
  if ! porcelain="$(git -C "$repo_path" worktree list --porcelain 2>&1)"; then
    line="${${porcelain%%$'\n'*}//$'\t'/ }"
    _status_emit error "$project" "$repo" "$repo_path" - - - 0 - - - - - - - - \
      "${line:-git worktree list failed}"
    return 0
  fi
  local -A checked_out
  for line in "${(@f)porcelain}"; do
    [[ $line == "branch refs/heads/"* ]] && checked_out[${line#branch refs/heads/}]=1
  done

  local base base_name=- base_show=-
  if base="$(status_base_ref "$repo_path")"; then
    base_show=${${base#refs/remotes/}#refs/heads/}
    base_name=${${base#refs/remotes/origin/}#refs/heads/}
  else
    base=-
    print -u2 -r -- "$repo: no base branch, so nothing counts as merged"
  fi
  local user_email
  user_email="$(git -C "$repo_path" config user.email 2>/dev/null)"

  local -A pr_ref pr_state pr_sha pr_open
  local b r s u h src
  if [[ -n $pr_file && -r $pr_file ]]; then
    while IFS=$'\t' read -r b r s u h; do pr_ref[$b]=$r pr_state[$b]=$s pr_sha[$b]=$h; done < "$pr_file"
    src=$pr_file; [[ -r $pr_file.all ]] && src=$pr_file.all
    while IFS=$'\t' read -r b r s u; do
      [[ $s == (open|draft) && -z ${pr_open[$b]:-} ]] && pr_open[$b]=$r$'\t'$s
    done < "$src"
  fi

  # Maps are keyed by full refname: %(refname:short) turns into heads/x when a tag x exists.
  local fmt=$'%(refname)\t%(objectname)\t%(committerdate:unix)\t%(upstream)\t%(upstream:track,nobracket)\t%(authoremail)'
  local refs= ref name
  local -A r_sha r_ts r_up r_track r_email r_ahead in_base names
  local -a f
  local -i no_ab=0
  [[ $base != - ]] && refs="$(git -C "$repo_path" for-each-ref --format="$fmt"$'\t'"%(ahead-behind:$base)" refs/heads refs/remotes/origin 2>/dev/null)"
  if [[ -z $refs ]]; then
    [[ $base != - ]] && no_ab=1
    refs="$(git -C "$repo_path" for-each-ref --format="$fmt" refs/heads refs/remotes/origin 2>/dev/null)"
  fi
  for line in "${(@f)refs}"; do
    [[ -n $line ]] || continue
    f=("${(@ps:\t:)line}")
    ref=${f[1]}
    case $ref in
      refs/heads/*) name=${ref#refs/heads/} ;;
      refs/remotes/origin/HEAD) continue ;;
      refs/remotes/origin/*) name=${ref#refs/remotes/origin/} ;;
      *) continue ;;
    esac
    r_sha[$ref]=${f[2]} r_ts[$ref]=${f[3]} r_up[$ref]=${f[4]} r_track[$ref]=${f[5]} r_email[$ref]=${f[6]}
    [[ ${f[7]:-} =~ '^[0-9]+ [0-9]+$' ]] && r_ahead[$ref]=${f[7]%% *}
    names[$name]=1
  done
  if [[ $base != - ]]; then
    for ref in ${(f)"$(git -C "$repo_path" for-each-ref --merged="$base" --format='%(refname)' refs/heads refs/remotes/origin 2>/dev/null)"}; do
      in_base[$ref]=1
    done
  fi

  local lref rref lsha rsha lwhy rwhy why cls owner why_owner key bk_state bk_refs note count ts del_ahead n
  local -i gone protected backup_ok merged pushed via_pr side_age stale_age rdel demoted
  local -a out del_refs
  for name in ${(k)names}; do
    [[ $name == "$base_name" ]] && continue
    (( ${+checked_out[$name]} )) && continue
    lref=refs/heads/$name rref=refs/remotes/origin/$name
    lsha=${r_sha[$lref]:--} rsha=${r_sha[$rref]:--}
    gone=0; [[ $lsha != - && ${r_track[$lref]} == gone ]] && gone=1
    owner=- demoted=0
    if [[ $rsha != - ]]; then
      branch_owner "${r_email[$rref]}" "$user_email"; owner=$REPLY
      # A tip inside the base can be the base commit the name was cut from, by anyone.
      if [[ $owner == me ]] && (( ${+in_base[$rref]} )) && [[ ${r_up[$lref]:-} != "$rref" ]]; then
        owner=teammate demoted=1
      fi
    fi
    rdel=0; [[ $owner == me && -z ${pr_open[$name]:-} ]] && rdel=1
    why_owner=$owner; [[ $owner == me ]] && (( ! rdel )) && why_owner=teammate
    protected=0; branch_protected "$name" && protected=1
    key=- bk_state=- bk_refs=-
    if branch_backup_name "$name" && branch_ticket_key "$name"; then
      key=$REPLY
      if branch_ticket_pr "$key" "$pr_file"; then bk_state=$REPLY bk_refs=${(j:, :)reply}
      else bk_state=skipped; fi
    fi
    backup_ok=0; [[ $bk_state == merged ]] && backup_ok=1

    lwhy=- rwhy=- via_pr=0 stale_age=-1 del_refs=()
    for ref in $lref $rref; do
      [[ -n ${r_sha[$ref]:-} ]] || continue
      merged=0 pushed=0
      status_merged_rule $(( ${+in_base[$ref]} )) "${pr_state[$name]:-}" "${pr_sha[$name]:-}" "${r_sha[$ref]}" && merged=1
      side_age=$(( now - ${r_ts[$ref]} ))
      if [[ $ref == "$lref" ]]; then
        [[ $rsha != - ]] && (( ! rdel )) \
          && branch_pushed "$name" "$lsha" "$rsha" "${r_up[$lref]}" "${r_track[$lref]}" && pushed=1
        branch_side_why $protected $merged $pushed $backup_ok $gone $side_age $stale_s; lwhy=$REPLY
        del_refs+=($ref)
      else
        branch_side_why $protected $merged 0 $backup_ok 0 $side_age $stale_s; rwhy=$REPLY
        (( rdel )) && del_refs+=($ref)
      fi
      if (( rdel )) || [[ $ref == "$lref" ]]; then
        (( merged && ! ${+in_base[$ref]} )) && via_pr=1
        [[ $REPLY == stale ]] && (( stale_age < 0 || side_age < stale_age )) && stale_age=$side_age
      fi
    done
    branch_row_why $lwhy $rwhy $why_owner; why=$REPLY
    branch_why_class $why; cls=$REPLY

    ts=${r_ts[$lref]:-0}
    (( ${r_ts[$rref]:-0} > ts )) && ts=${r_ts[$rref]}
    del_ahead=-
    if [[ $cls != none ]]; then
      for ref in $del_refs; do
        n=${r_ahead[$ref]:-}
        # git < 2.41 has no %(ahead-behind:...): count the local tip, which an equal origin tip shares.
        if [[ -z $n ]] && (( no_ab )) && [[ $ref == "$lref" || $rsha == "$lsha" ]]; then
          n="$(git -C "$repo_path" rev-list --count "$lsha" --not "$base" -- 2>/dev/null)" && r_ahead[$lref]=$n
          [[ $rsha == "$lsha" ]] && r_ahead[$rref]=$n
        fi
        [[ $n == <-> ]] || { del_ahead=-; break; }
        if [[ $del_ahead == - ]] || (( n > del_ahead )); then del_ahead=$n; fi
      done
    fi

    count="commits not in $base_show"; [[ $del_ahead != - ]] && count="$del_ahead $count"
    case $why in
      protected) note=protected ;;
      read-only)
        if [[ $owner == me ]]; then note="PR ${${pr_open[$name]}%%$'\t'*} is open"
        elif (( demoted )); then note="no commits beyond $base_show, not tracked locally"
        else note="origin branch by ${r_email[$rref]//[<>]/}"; fi ;;
      merged) if (( via_pr )); then note="PR ${pr_ref[$name]} merged"; else note="merged into $base_show"; fi ;;
      pushed) note="same as origin/$name" ;;
      backup) note="backup of $key (PR $bk_refs merged)" ;;
      *)
        case $bk_state in
          open) note="backup of $key: PR $bk_refs open" ;;
          none) note="backup of $key: no merged PR" ;;
          incomplete) note="backup of $key: PR list incomplete" ;;
          skipped) note="backup of $key: PR lookup skipped" ;;
          *)
            case $why in
              gone) note="upstream deleted, $count" ;;
              stale) status_fmt_age $stale_age; note="$REPLY old, $count" ;;
              *) note=$count ;;
            esac
            ;;
        esac
        ;;
    esac
    r=${pr_ref[$name]:--} s=${pr_state[$name]:--}
    [[ -n ${pr_open[$name]:-} ]] && { r=${pr_open[$name]%%$'\t'*} s=${pr_open[$name]#*$'\t'}; }
    f=(branch "$project" "$repo" "$repo_path" "$name" "$lsha" "$rsha" $gone "$owner" "$why" "$cls"
       "$ts" "$del_ahead" "$key" "$r" "$s" "${note//$'\t'/ }")
    out+=("${(l:12::0:)ts}"$'\t'"${(pj:\t:)f}")
  done
  for line in "${(@on)out}"; do print -r -- "${line#*$'\t'}"; done
  return 0
}

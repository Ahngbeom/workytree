# Branch classification for `wt status` branch mode: pure functions over names, shas and
# states already collected. None of them calls git.

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

branch_ticket_pr() {
  setopt localoptions extendedglob
  local key=$1 pr_file=$2 line
  local -a f open_refs merged_refs
  reply=()
  REPLY=none
  [[ -r $pr_file ]] || return 1
  while IFS= read -r line; do
    f=("${(@ps:\t:)line}")
    branch_name_has_key "${f[1]}" "$key" || continue
    case ${f[3]} in
      open|draft) open_refs+=("${f[2]}") ;;
      merged) merged_refs+=("${f[2]}") ;;
    esac
  done < "$pr_file"
  if (( ${#open_refs} )); then REPLY=open; reply=("${open_refs[@]}")
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
  elif [[ $age == <-> && $stale == <-> ]] && (( age >= stale )); then REPLY=stale
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

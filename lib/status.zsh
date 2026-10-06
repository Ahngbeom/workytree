# Data collection and judgement for `status` (rendering lives in lib/cmd/status.zsh).
#
# status_collect_repo emits one raw record per row: 26 TAB-separated fields, "-" for every
# empty value. zsh's `read` treats TAB as IFS whitespace and collapses an empty field into
# its neighbour, so readers split with "${(@ps:\t:)line}" and nothing is ever empty.
#   1 type      worktree|main|branch|orphan|error   14 merged     0|1
#   2 project                                       15 gone       0|1
#   3 repo                                          16 dirty      clean|idea-only|real|unknown|-
#   4 repo_path                                     17 ahead      vs upstream
#   5 path                                          18 behind     vs upstream
#   6 kind                                          19 base_ahead
#   7 ticket                                        20 base_behind
#   8 branch                                        21 locked     0|1
#   9 flag      safe|stale|dirty|-                  22 prunable   0|1
#  10 tags      space-separated                     23 pr_ref     #N or !N
#  11 active_ts epoch                               24 pr_state   open|draft|merged|closed
#  12 created_ts                                    25 pr_url
#  13 commit_ts                                     26 note       error rows only

zmodload -F zsh/stat b:zstat 2>/dev/null
zmodload zsh/datetime zsh/parameter zsh/zselect 2>/dev/null

# status_pool_wait <max>: block until fewer than <max> background jobs of this shell run. zsh
# has no `wait -n`; waiting for a whole batch instead lets one slow repo hold up the rest.
status_pool_wait() {
  while (( ${#jobstates} >= $1 )); do zselect -t 5; done
}

# Row-level helpers return through REPLY rather than stdout: a $(...) per row forks once per
# branch.

# status_fmt_age <seconds>: REPLY = <1h, Nh, Nd (<14d), Nw (<8w), Nmo (<2y), Ny; "-" passes
# through.
status_fmt_age() {
  [[ "$1" == <-> ]] || { REPLY=-; return; }
  local -i s=$1
  if   (( s < 3600 ));        then REPLY="<1h"
  elif (( s < 86400 ));       then REPLY="$(( s / 3600 ))h"
  elif (( s < 14 * 86400 ));  then REPLY="$(( s / 86400 ))d"
  elif (( s < 56 * 86400 ));  then REPLY="$(( s / 604800 ))w"
  elif (( s < 730 * 86400 )); then REPLY="$(( s / 2592000 ))mo"
  else                             REPLY="$(( s / 31536000 ))y"
  fi
}

# status_base_ref <repo_path>: the full ref that "merged" is measured against -- origin's
# default branch, else origin/main or origin/master, else the main checkout's branch.
status_base_ref() {
  local repo_path="$1" ref
  ref="$(git -C "$repo_path" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)"
  if [[ -n "$ref" ]] && git -C "$repo_path" show-ref --verify --quiet "$ref"; then
    print -r -- "$ref"; return 0
  fi
  for ref in refs/remotes/origin/main refs/remotes/origin/master; do
    git -C "$repo_path" show-ref --verify --quiet "$ref" && { print -r -- "$ref"; return 0; }
  done
  ref="$(git -C "$repo_path" symbolic-ref -q HEAD 2>/dev/null)" && [[ -n "$ref" ]] && { print -r -- "$ref"; return 0; }
  return 1
}

# status_flag <merged> <gone> <pr_state> <dirty> <ahead> <has_upstream> <base_ahead>
#             <locked> <age_s> <stale_s>
# REPLY = dirty|safe|stale|-. Losing work outranks everything, so dirty wins over safe and stale.
# An "unknown" dirt probe is dirty, never safe (R24).
status_flag() {
  local -i merged=$1 gone=$2 has_up=$6 locked=$8
  local pr_state=$3 dirt=$4 ahead=$5 base_ahead=$7 age=$9 stale=${10}
  [[ "$pr_state" == merged ]] && merged=1
  if [[ "$dirt" == (real|unknown) || "$ahead" == <1-> ]] \
     || { (( ! has_up && ! merged )) && [[ "$base_ahead" == <1-> ]]; }; then
    REPLY=dirty; return
  fi
  if (( ! locked )) && { (( merged || gone )) || [[ "$pr_state" == closed ]]; }; then
    REPLY=safe; return
  fi
  [[ "$age" == <-> ]] && (( age > stale )) && { REPLY=stale; return; }
  REPLY=-
}

# _status_max_mtime <file...>: REPLY = newest mtime among the files that exist, else "-".
_status_max_mtime() {
  local f; local -i best=0; local -a t
  for f in "$@"; do
    [[ -e "$f" ]] || continue
    zstat -A t +mtime -- "$f" 2>/dev/null || continue
    (( t[1] > best )) && best=${t[1]}
  done
  (( best )) && REPLY=$best || REPLY=-
}

# _status_created_ts <gitdir>: REPLY = birth time on macOS; elsewhere the first reflog entry,
# which `git worktree add` writes and reflog expiry (90 days by default) can later drop.
_status_created_ts() {
  local gitdir="$1" t line
  if [[ "$OSTYPE" == darwin* ]]; then
    t="$(command stat -f %B -- "$gitdir" 2>/dev/null)"
    [[ "$t" == <1-> ]] && { REPLY="$t"; return; }
  fi
  if [[ -r "$gitdir/logs/HEAD" ]] && IFS= read -r line < "$gitdir/logs/HEAD"; then
    local -a w; w=(${=${line%%$'\t'*}})
    [[ "${w[-2]:-}" == <1-> ]] && { REPLY="${w[-2]}"; return; }
  fi
  REPLY=-
}

# _status_track <track>: reply=(ahead behind) from %(upstream:track,nobracket).
_status_track() {
  local ahead=0 behind=0 part
  for part in "${(@s:, :)1}"; do
    case "$part" in
      "ahead "<->)  ahead="${part#ahead }" ;;
      "behind "<->) behind="${part#behind }" ;;
    esac
  done
  reply=($ahead $behind)
}

# _status_branch_fields <branch>: reply=(commit_ts merged gone ahead behind base_ahead
# base_behind has_upstream pr_ref pr_state pr_url judged_pr_state) for a local branch.
# judged_pr_state is what status_flag may rely on: a merged/closed PR counts only while the
# branch still points at the PR's head, so commits made after it, or a reused branch name,
# stay local-only work. Reads status_collect_repo's locals (b_ts b_up b_track b_ab b_tip
# b_merged pr_ref pr_state pr_url pr_sha base repo_path) through zsh's dynamic scoping; only
# status_collect_repo calls it.
_status_branch_fields() {
  local br="$1" commit=- merged=0 gone=0 ahead=- behind=- bahead=- bbehind=- has_up=0 counts
  local judged="${pr_state[$br]:--}"
  [[ "$judged" == (merged|closed) && "${pr_sha[$br]:-}" != "${b_tip[$br]:-}" ]] && judged=-
  [[ -n "${b_ts[$br]:-}" ]] && commit=${b_ts[$br]}
  if [[ -n "${b_up[$br]:-}" ]]; then
    has_up=1
    if [[ "${b_track[$br]}" == gone ]]; then gone=1
    else _status_track "${b_track[$br]}"; ahead=${reply[1]} behind=${reply[2]}; fi
  fi
  (( ${+b_merged[$br]} )) && merged=1
  if [[ -n "${b_ab[$br]:-}" ]]; then
    bahead=${b_ab[$br]%% *} bbehind=${b_ab[$br]##* }
  elif [[ "$base" != - ]]; then
    # git < 2.41 has no %(ahead-behind:...): count this branch on its own.
    counts="$(git -C "$repo_path" rev-list --left-right --count "$base...refs/heads/$br" 2>/dev/null)" \
      && { bbehind=${counts%%[[:space:]]*}; bahead=${counts##*[[:space:]]}; }
  fi
  reply=($commit $merged $gone $ahead $behind $bahead $bbehind $has_up
         "${pr_ref[$br]:--}" "${pr_state[$br]:--}" "${pr_url[$br]:--}" "$judged")
}

_status_emit() { local IFS=$'\t'; print -r -- "$*"; }

# _status_dirt_all <path...>: dirt_of[path] (the caller's associative array) = the
# _worktree_dirt_kind verdict for each path. `git status` is the slowest probe here, so a repo
# with many worktrees runs WT_STATUS_DIRT_JOBS of them at once.
# GIT_OPTIONAL_LOCKS=0 stops `git status` rewriting the index: the index mtime is the
# worktree's "last activity", and refreshing it would make every worktree look fresh on the
# next run.
typeset -gi WT_STATUS_DIRT_JOBS=4
_status_dirt_all() {
  local tmp p
  local -i i=0
  if ! tmp="$(mktemp -d 2>/dev/null)"; then
    for p; do GIT_OPTIONAL_LOCKS=0 _worktree_dirt_kind "$p"; dirt_of[$p]=$REPLY; done
    return
  fi
  for p; do
    (( ++i ))
    status_pool_wait $WT_STATUS_DIRT_JOBS
    { GIT_OPTIONAL_LOCKS=0 _worktree_dirt_kind "$p"; print -r -- "$REPLY" > "$tmp/$i"; } &
  done
  wait
  i=0
  for p; do
    (( ++i ))
    dirt_of[$p]=unknown
    [[ -s "$tmp/$i" ]] && dirt_of[$p]="$(<"$tmp/$i")"
  done
  rm -rf "$tmp"
}

# status_collect_repo <project> <repo> <repo_path> <stale_days> [pr_file]
# Raw records for one repo on stdout; one reason line per problem on stderr. Never fails:
# a repo git cannot read becomes a single error row.
status_collect_repo() {
  local project="$1" repo="$2" repo_path="$3" stale_days="$4" pr_file="${5:-}"
  local -i now=$EPOCHSECONDS stale_s=$(( stale_days * 86400 ))
  local porcelain line
  if ! porcelain="$(git -C "$repo_path" worktree list --porcelain 2>&1)"; then
    line="${${porcelain%%$'\n'*}//$'\t'/ }"
    _status_emit error "$project" "$repo" "$repo_path" - - - - - error - - - 0 0 - - - - - 0 0 - - - \
      "${line:-git worktree list failed}"
    return 0
  fi

  local -A pr_ref pr_state pr_url pr_sha
  local b r s u h
  if [[ -n "$pr_file" && -s "$pr_file" ]]; then
    while IFS=$'\t' read -r b r s u h; do pr_ref[$b]=$r pr_state[$b]=$s pr_url[$b]=$u pr_sha[$b]=$h; done < "$pr_file"
  fi

  local base base_local=- refs fmt
  base="$(status_base_ref "$repo_path")" || base=-
  [[ "$base" == refs/remotes/origin/* ]] && base_local="${base#refs/remotes/origin/}"
  [[ "$base" == refs/heads/* ]] && base_local="${base#refs/heads/}"

  # Keep this to two for-each-ref calls: a git call per branch multiplies with branch count.
  local -A b_ts b_up b_track b_ab b_tip b_merged
  local -a f
  fmt=$'%(refname:short)\t%(committerdate:unix)\t%(upstream)\t%(upstream:track,nobracket)\t%(objectname)'
  refs=""
  [[ "$base" != - ]] && refs="$(git -C "$repo_path" for-each-ref --format="$fmt"$'\t'"%(ahead-behind:$base)" refs/heads 2>/dev/null)"
  [[ -n "$refs" ]] || refs="$(git -C "$repo_path" for-each-ref --format="$fmt" refs/heads 2>/dev/null)"
  for line in "${(@f)refs}"; do
    [[ -n "$line" ]] || continue
    f=("${(@ps:\t:)line}")
    b_ts[${f[1]}]=${f[2]} b_up[${f[1]}]=${f[3]} b_track[${f[1]}]=${f[4]} b_tip[${f[1]}]=${f[5]}
    [[ -n "${f[6]:-}" ]] && b_ab[${f[1]}]=${f[6]}
  done
  if [[ "$base" != - ]]; then
    for line in ${(f)"$(git -C "$repo_path" for-each-ref --merged="$base" --format='%(refname:short)' refs/heads 2>/dev/null)"}; do
      b_merged[$line]=1
    done
  fi

  local wt_root wt_root_canon
  wt_root="$(worktree_parent "$project" "$repo")"; wt_root_canon="${wt_root:A}"

  local -A dirt_of
  local -a wt_dirs
  for line in "${(@f)porcelain}"; do
    [[ "$line" == "worktree "* && -d "${line#worktree }" ]] && wt_dirs+=("${line#worktree }")
  done
  _status_dirt_all "${wt_dirs[@]}"

  # Worktrees, in git's order; the first block is always the main checkout.
  local -A checked_out
  local -i idx=0 locked prunable
  local wpath= wbranch= gitdir kind ticket rel dirt active created flag type age
  local -a tags
  for line in "${(@f)porcelain}" ""; do
    case "$line" in
      "worktree "*) wpath="${line#worktree }" wbranch=- locked=0 prunable=0 ;;
      "branch refs/heads/"*) wbranch="${line#branch refs/heads/}" ;;
      locked|"locked "*) locked=1 ;;
      prunable|"prunable "*) prunable=1 ;;
      "")
        [[ -n "$wpath" ]] || continue
        (( ++idx ))
        [[ "$wbranch" != - ]] && checked_out[$wbranch]=1
        type=worktree kind=- ticket=- tags=()
        if (( idx == 1 )); then
          type=main
          gitdir="$(git -C "$repo_path" rev-parse --absolute-git-dir 2>/dev/null)" || gitdir=-
        elif [[ -f "$wpath/.git" ]] && IFS= read -r gitdir < "$wpath/.git" && [[ "$gitdir" == "gitdir: "* ]]; then
          gitdir="${gitdir#gitdir: }"
        else
          gitdir=-
        fi
        if [[ "$type" == worktree ]]; then
          rel="${wpath:A}"; rel="${rel#"$wt_root_canon"/}"
          if [[ "$rel" != "${wpath:A}" && "$rel" == */* ]]; then kind="${rel%%/*}" ticket="${rel#*/}"
          else tags+=(external); fi
        fi
        if [[ "$gitdir" != - ]]; then
          _status_max_mtime "$gitdir/index" "$gitdir/HEAD" "$gitdir/logs/HEAD"; active=$REPLY
          _status_created_ts "$gitdir"; created=$REPLY
        else
          active=- created=-
        fi
        if (( prunable )) || [[ ! -d "$wpath" ]]; then dirt=-
        else dirt="${dirt_of[$wpath]:-unknown}"; fi
        if [[ "$wbranch" != - ]]; then _status_branch_fields "$wbranch"
        else reply=(- 0 0 - - - - 0 - - - -); fi
        age=-; [[ "$active" != - ]] && age=$(( now - active ))
        if [[ "$type" == main ]]; then
          flag=- tags=(main)
        else
          status_flag ${reply[2]} ${reply[3]} ${reply[12]} $dirt ${reply[4]} ${reply[8]} ${reply[6]} $locked $age $stale_s
          flag=$REPLY
          [[ "$flag" != - ]] && tags=($flag $tags)
          (( reply[2] )) && tags+=(merged)
          (( reply[3] )) && tags+=(gone)
        fi
        (( locked )) && tags+=(locked)
        (( prunable )) && tags+=(prunable)
        _status_emit "$type" "$project" "$repo" "$repo_path" "$wpath" "$kind" "$ticket" "$wbranch" \
          "$flag" "${${(j: :)tags}:--}" "$active" "$created" "${reply[1]}" "${reply[2]}" "${reply[3]}" \
          "$dirt" "${reply[4]}" "${reply[5]}" "${reply[6]}" "${reply[7]}" "$locked" "$prunable" \
          "${reply[9]}" "${reply[10]}" "${reply[11]}" -
        wpath=
        ;;
    esac
  done

  # Local branches no worktree has checked out, minus the base branch itself.
  local br
  for br in ${(ok)b_ts}; do
    (( ${+checked_out[$br]} )) && continue
    [[ "$br" == "$base_local" ]] && continue
    _status_branch_fields "$br"
    age=-; [[ "${reply[1]}" != - ]] && age=$(( now - reply[1] ))
    status_flag ${reply[2]} ${reply[3]} ${reply[12]} - ${reply[4]} ${reply[8]} ${reply[6]} 0 $age $stale_s
    flag=$REPLY
    tags=(); [[ "$flag" != - ]] && tags=($flag)
    (( reply[2] )) && tags+=(merged)
    (( reply[3] )) && tags+=(gone)
    _status_emit branch "$project" "$repo" "$repo_path" - - - "$br" "$flag" "${${(j: :)tags}:--}" \
      - - "${reply[1]}" "${reply[2]}" "${reply[3]}" - "${reply[4]}" "${reply[5]}" "${reply[6]}" \
      "${reply[7]}" 0 0 "${reply[9]}" "${reply[10]}" "${reply[11]}" -
  done

  # Directories under <worktree_root>/<repo> that git does not know about. Read-only: no
  # `git worktree prune` first (that is `wt prune`'s job).
  local scan_rc dir
  _prune_scan "$project" "$repo" "$repo_path" 2>/dev/null; scan_rc=$?
  if (( scan_rc == 1 )); then
    print -u2 -r -- "orphan scan skipped: worktree_root for project '$project' failed prune's safety checks"
  fi
  if (( scan_rc == 0 )); then
    for dir in "${WT_SCAN_ORPHANS[@]}"; do
      rel="${dir#"$WT_SCAN_ROOT"/}"
      _status_max_mtime "$dir"
      _status_emit orphan "$project" "$repo" "$repo_path" "$dir" "${rel%%/*}" "${rel#*/}" - - orphan \
        "$REPLY" - - 0 0 - - - - - 0 0 - - - -
    done
  fi
  return 0
}

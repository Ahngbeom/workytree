# PR/MR lookup for `status`: one `gh`/`glab` call per repo, normalized to
# "branch<TAB>ref<TAB>state<TAB>url<TAB>head_sha" rows. Failures print one reason line on stderr and return 1;
# callers show the reason and carry on without PR data. A repo without origin yields no rows.

typeset -gi WT_FORGE_TIMEOUT=15

# forge_host_path <remote_url>: reply=(host path) for https://, ssh:// and scp-style
# (git@host:path) URLs; the path loses a trailing ".git". rc 1 when the URL has neither.
forge_host_path() {
  local url="$1" rest host p
  case "$url" in
    *://*)
      rest="${url#*://}"; rest="${rest#*@}"
      host="${rest%%/*}"; p="${rest#*/}"
      host="${host%%:*}" ;;
    *@*:*)
      rest="${url#*@}"; host="${rest%%:*}"; p="${rest#*:}" ;;
    *) return 1 ;;
  esac
  [[ "$p" == "$rest" ]] && return 1
  p="${p%/}"; p="${p%.git}"
  [[ -n "$host" && -n "$p" ]] || return 1
  reply=("$host" "$p")
}

_forge_has() { (( $+functions[$1] || $+commands[$1] )); }

# forge_kind <host>: github|gitlab|none. Self-hosted instances are recognized by whichever
# CLI is logged in to that host. `glab auth status` goes over the network, so answers are kept
# in WT_FORGE_KINDS; `status` fills it once per host before forking its per-repo jobs, which
# inherit it.
typeset -gA WT_FORGE_KINDS
forge_kind() {
  local host="$1"
  [[ -n "${WT_FORGE_KINDS[$host]:-}" ]] && { print -r -- "${WT_FORGE_KINDS[$host]}"; return; }
  WT_FORGE_KINDS[$host]="$(_forge_detect "$host")"
  print -r -- "${WT_FORGE_KINDS[$host]}"
}

_forge_detect() {
  local host="$1"
  case "$host" in
    github.com) print -r -- github; return ;;
    gitlab.com) print -r -- gitlab; return ;;
  esac
  if _forge_has gh && _forge_run gh auth status --hostname "$host"; then
    print -r -- github; return
  fi
  if _forge_has glab && _forge_run glab auth status --hostname "$host"; then
    print -r -- gitlab; return
  fi
  print -r -- none
}

# _forge_run <cmd...>: REPLY=stdout of <cmd>, which runs with stdin closed and prompts
# disabled. Killed after WT_FORGE_TIMEOUT seconds -> rc 124. macOS ships no timeout(1). The
# command's first stderr line lands in WT_FORGE_ERR.
typeset -g WT_FORGE_ERR=''
_forge_run() {
  local out_file err_file
  out_file="$(mktemp 2>/dev/null)" || return 1
  err_file="$(mktemp 2>/dev/null)" || { rm -f "$out_file"; return 1; }
  GH_PROMPT_DISABLED=1 NO_PROMPT=1 GIT_TERMINAL_PROMPT=0 "$@" </dev/null >"$out_file" 2>"$err_file" &
  local -i pid=$! rc ticks=$(( WT_FORGE_TIMEOUT * 10 )) timed_out=0
  while kill -0 "$pid" 2>/dev/null; do
    (( ticks-- > 0 )) || { kill "$pid" 2>/dev/null; timed_out=1; break; }
    sleep 0.1
  done
  wait "$pid" 2>/dev/null; rc=$?
  (( timed_out )) && rc=124
  WT_FORGE_ERR="$(head -1 "$err_file" 2>/dev/null)"
  REPLY="$(<"$out_file")"
  rm -f "$out_file" "$err_file"
  return $rc
}

# _forge_latest_per_branch: "branch ref state url sha updated" rows on stdin -> one
# "branch ref state url sha" row per branch, keeping the most recently updated. ISO-8601 UTC
# timestamps from one forge compare correctly as strings.
_forge_latest_per_branch() {
  local -A best when
  local -a order
  local b ref st u sha t
  while IFS=$'\t' read -r b ref st u sha t; do
    [[ -n "$b" ]] || continue
    if (( ! ${+when[$b]} )); then
      order+=("$b")
    elif [[ ! "$t" > "${when[$b]}" ]]; then
      continue
    fi
    when[$b]="$t"; best[$b]="$ref"$'\t'"$st"$'\t'"$u"$'\t'"$sha"
  done
  for b in "${order[@]}"; do print -r -- "$b"$'\t'"${best[$b]}"; done
}

# forge_pr_rows <repo_path>: PR/MR rows for origin's repository. state is one of
# open|draft|merged|closed; ref is "#N" (GitHub) or "!N" (GitLab); head_sha is the PR's last
# commit.
forge_pr_rows() {
  local repo_path="$1" url host rpath kind out
  local -i rc
  # No origin is not a failure: there is simply nothing to look up.
  url="$(git -C "$repo_path" remote get-url origin 2>/dev/null)" || return 0
  forge_host_path "$url" || { print -u2 -r -- "cannot parse origin URL ($url); PR lookup skipped"; return 1; }
  host="${reply[1]}" rpath="${reply[2]}"
  forge_kind "$host" >/dev/null   # in this shell, so the answer stays cached
  kind="${WT_FORGE_KINDS[$host]}"
  case "$kind" in
    github)
      _forge_has gh || { print -u2 -r -- "gh is not installed; PR lookup skipped"; return 1; }
      _forge_run gh pr list -R "$host/$rpath" --state all --limit 200 \
        --json headRefName,number,state,isDraft,url,headRefOid,updatedAt \
        --jq '.[] | [.headRefName, "#\(.number)", (if .isDraft and .state == "OPEN" then "draft" else (.state | ascii_downcase) end), .url, .headRefOid, .updatedAt] | @tsv'
      rc=$? out="$REPLY" ;;
    gitlab)
      _forge_has glab || { print -u2 -r -- "glab is not installed; MR lookup skipped"; return 1; }
      _forge_run glab mr list -R "$url" --all --per-page 100 -F json \
        --jq '.[] | [.source_branch, "!\(.iid)", (if .state == "opened" then (if .draft then "draft" else "open" end) elif .state == "locked" then "closed" else .state end), .web_url, .sha, .updated_at] | @tsv'
      rc=$? out="$REPLY" ;;
    *)
      print -u2 -r -- "origin host $host is not a GitHub/GitLab host known to gh or glab; PR lookup skipped"
      return 1 ;;
  esac
  if (( rc == 124 )); then
    print -u2 -r -- "$kind lookup timed out after ${WT_FORGE_TIMEOUT}s; PR column left empty"; return 1
  elif (( rc != 0 )); then
    print -u2 -r -- "$kind lookup failed (exit $rc)${WT_FORGE_ERR:+: $WT_FORGE_ERR}"; return 1
  fi
  _forge_latest_per_branch <<< "$out"
}

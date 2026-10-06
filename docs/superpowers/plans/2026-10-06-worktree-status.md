# wt status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `wt status`, an overview of every worktree, unattached branch and orphan directory in the configured workspace, with age, PR/MR and cleanup-safety signals, rendered as an fzf list (cd / remove / open PR) or a table / JSON.

**Architecture:** `lib/forge.zsh` turns origin into one `gh`/`glab` call per repo. `lib/status.zsh` collects one repo into 26-field TAB records and judges each row (`safe`/`stale`/`dirty`). `lib/cmd/status.zsh` runs those collectors in a job pool and renders. `prune`'s read-only orphan scan is split out so `status` can reuse it without pruning.

**Tech Stack:** zsh 5.9 (modules zsh/stat, zsh/datetime, zsh/parameter, zsh/zselect), git 2.50 (2.41+ for `%(ahead-behind:)`, older falls back), optional `fzf` ≥ 0.38, optional `gh`/`glab`.

**Spec:** `docs/superpowers/specs/2026-10-06-worktree-status-design.md`

Every code block in this plan was run in a prototype; each task's expected test counts are from replaying this plan, task by task, on a clean checkout.

## Global Constraints

- Shell: zsh only; every new file must pass `zsh -n` (CI lint job globs `lib/*.zsh lib/cmd/*.zsh tests/*.zsh`).
- No new required dependency: `fzf` (≥ 0.38), `gh`, `glab` are optional; no `jq` (both CLIs' built-in `--jq` is used).
- Never name a local `path` (R16: it is tied to `$PATH`).
- `status` changes nothing on disk or in git: no `git worktree prune`, no fetch unless `--fetch`, `git status` runs with `GIT_OPTIONAL_LOCKS=0`.
- "Could not determine" is never treated as clean (R24): dirt `unknown` is `dirty`, never `safe`.
- Records are 26 TAB-separated fields with `-` for every empty value; split with `"${(@ps:\t:)line}"`, never `IFS=$'\t' read` (it collapses empty fields).
- Tests stub external CLIs (`gh`, `glab`, `fzf`, `git`) as shell functions after sourcing `lib/`; no test-only environment hooks in product code (`bin/workytree` puts system dirs first on `PATH`, so fake executables cannot shadow real installs).
- Defaults: `stale_days` = 30, `WT_STATUS_MAX_JOBS` = 8, `WT_STATUS_DIRT_JOBS` = 4, `WT_FORGE_TIMEOUT` = 15 s, fzf minimum `0.38`.
- Comments follow `~/.claude/CLAUDE.md`: only what quietly breaks the next edit; measurements and history go in commit messages.

## Review Focus

1. **Running `status` twice** must not reset ages — `git status` rewrites the index, and the index mtime *is* "last activity". Pinned by `test_old_pushed_unmerged_worktree_is_stale` (second run) in Task 4.
2. **Branch names with `"`** (git allows them) must stay valid JSON. Pinned by `test_json_is_valid_and_escapes_branch_names` in Task 4.
3. **An install path with spaces** must survive fzf's `$SHELL -c` re-parsing of every binding. Pinned by `test_bindings_quote_a_bin_path_with_spaces` in Task 5.
4. **`--stale` when the last sorted row is filtered out** must still list the earlier rows — with `pipefail`, a filter loop ending in a false test fails the whole pipeline. Pinned by `test_stale_filter_and_override` in Task 4 (main checkouts sort last and are always filtered).
5. **No terminal at all** (CI, pipes): the preview-width probe must not print a shell error about `/dev/tty`. Pinned by `test_preview_window_probe_is_quiet` in Task 5.

## File Map

| File | Task | Responsibility |
|---|---|---|
| `lib/forge.zsh` (new) | 1 | origin URL → forge kind (cached per host) → normalized PR/MR rows |
| `lib/cmd/prune.zsh` | 2 | `_prune_scan` (read-only) split out of `prune_repo` |
| `lib/status.zsh` (new) | 3 | one repo → 26-field records; age format, base ref, flag rules, job pool |
| `lib/config.zsh`, `lib/agent.zsh` | 4 | `project_setting` (shared by `stale_days` and `ai_setting`) |
| `lib/ui.zsh` | 4 | `ui_init force` |
| `lib/cmd/status.zsh` (new) | 4, 5 | options, parallel collection, table/JSON (4); fzf, preview, actions (5) |
| `bin/workytree` | 4 | usage + dispatch |
| `shell/workytree.zsh`, `shell/completions/_workytree`, `lib/cmd/complete.zsh` | 6 | cd contract, completion |
| `README.md` | 6 | Status section |

Run every test file from the repo root: `zsh tests/<name>.test.zsh`. The last line is `N passed, M failed`; exit status is non-zero on any failure.

---

### Task 1: PR/MR lookup (`lib/forge.zsh`)

**Files:**
- Create: `lib/forge.zsh`
- Test: `tests/forge.test.zsh`

**Interfaces:**
- Consumes: nothing new (`git`, optional `gh`/`glab`).
- Produces:
  - `forge_host_path <url>` → `reply=(host path)`, rc 1 if unparseable.
  - `forge_kind <host>` → prints `github|gitlab|none`; caches in global assoc `WT_FORGE_KINDS`.
  - `forge_pr_rows <repo_path>` → stdout rows `branch<TAB>ref<TAB>state<TAB>url` (ref `#N`/`!N`, state `open|draft|merged|closed`), one per branch (latest updated). rc 1 + one reason line on stderr on failure; no origin → no output, rc 0.
  - `WT_FORGE_TIMEOUT` (int seconds, default 15).

- [ ] **Step 1: Write the failing test** — create `tests/forge.test.zsh`:

```zsh
#!/usr/bin/env zsh
# lib/forge.zsh, sourced directly. gh/glab are stubbed as shell functions: bin/workytree puts
# the system dirs first on PATH, so a fake executable on PATH could not shadow a real install.
source "${0:A:h}/helpers.zsh"
source "$WT_TEST_ROOT/lib/forge.zsh"

# repo_with_origin <url>: a repo whose origin points at <url> (never contacted).
repo_with_origin() {
  make_repo "$HOME/r"
  git -C "$HOME/r" remote add origin "$1"
}

unstub() { unfunction gh glab 2>/dev/null; true; }

test_host_path_parses_https_ssh_and_scp_forms() {
  forge_host_path https://github.com/o/r.git;            assert_eq "${reply[*]}" "github.com o/r" https
  forge_host_path https://user:tok@gl.example.com/g/s/r;  assert_eq "${reply[*]}" "gl.example.com g/s/r" https-creds
  forge_host_path ssh://git@gl.example.com:2222/g/r.git;  assert_eq "${reply[*]}" "gl.example.com g/r" ssh-port
  forge_host_path git@github.com:o/r.git;                 assert_eq "${reply[*]}" "github.com o/r" scp
  forge_host_path /srv/git/r.git;                         assert_eq "$?" 1 local-path
  forge_host_path https://github.com;                     assert_eq "$?" 1 no-path
}

test_kind_by_known_host_then_by_logged_in_cli() {
  unstub; WT_FORGE_KINDS=()
  assert_eq "$(forge_kind github.com)" github
  assert_eq "$(forge_kind gitlab.com)" gitlab
  gh()   { return 1; }
  glab() { [[ "$*" == "auth status --hostname gl.example.com" ]]; }
  assert_eq "$(forge_kind gl.example.com)" gitlab self-hosted-gitlab
  gh()   { [[ "$*" == "auth status --hostname ghe.example.com" ]]; }
  WT_FORGE_KINDS=()
  assert_eq "$(forge_kind ghe.example.com)" github self-hosted-github
  assert_eq "$(forge_kind other.example.com)" none
  unstub
}

test_github_rows_are_normalized_and_deduplicated() {
  repo_with_origin https://github.com/o/r.git
  gh() {
    print -r -- "$*" > "$HOME/gh.args"
    print -r -- $'fix/A\t#3\tclosed\thttps://x/3\t2026-01-01T00:00:00Z'
    print -r -- $'fix/A\t#7\tmerged\thttps://x/7\t2026-03-01T00:00:00Z'
    print -r -- $'fix/A\t#5\topen\thttps://x/5\t2026-02-01T00:00:00Z'
    print -r -- $'feat/B\t#9\tdraft\thttps://x/9\t2026-01-05T00:00:00Z'
  }
  local out; out="$(forge_pr_rows "$HOME/r")"
  assert_eq "$?" 0
  assert_eq "$out" $'fix/A\t#7\tmerged\thttps://x/7\nfeat/B\t#9\tdraft\thttps://x/9'
  assert_contains "$(<"$HOME/gh.args")" "pr list -R github.com/o/r --state all"
  unstub
}

test_gitlab_passes_origin_url_to_glab() {
  repo_with_origin git@gitlab.com:g/s/r.git
  glab() { print -r -- "$*" > "$HOME/glab.args"; print -r -- $'fix/A\t!4\topen\thttps://x/4\t2026-01-01T00:00:00.000Z'; }
  assert_eq "$(forge_pr_rows "$HOME/r")" $'fix/A\t!4\topen\thttps://x/4'
  assert_contains "$(<"$HOME/glab.args")" "mr list -R git@gitlab.com:g/s/r.git --all"
  unstub
}

test_failures_return_1_with_one_reason_line() {
  local err
  make_repo "$HOME/r"
  git -C "$HOME/r" remote add origin https://github.com/o/r.git
  gh() { print -u2 "HTTP 401: Bad credentials"; return 4; }
  err="$(forge_pr_rows "$HOME/r" 2>&1 >/dev/null)"
  assert_eq "$?" 1 gh-fails
  assert_eq "$err" "github lookup failed (exit 4): HTTP 401: Bad credentials"
  unstub

  git -C "$HOME/r" remote set-url origin https://other.example.com/o/r.git
  gh() { return 1; }; glab() { return 1; }
  err="$(forge_pr_rows "$HOME/r" 2>&1 >/dev/null)"
  assert_contains "$err" "not a GitHub/GitLab host"
  unstub
}

test_repo_without_origin_yields_nothing_silently() {
  make_repo "$HOME/r"
  local out; out="$(forge_pr_rows "$HOME/r" 2>&1)"
  assert_eq "$?" 0
  assert_eq "$out" ""
}

test_missing_cli_is_reported_not_run() {
  repo_with_origin https://github.com/o/r.git
  unstub
  local err; err="$(path=(/usr/bin /bin); forge_pr_rows "$HOME/r" 2>&1 >/dev/null)"
  assert_eq "$err" "gh is not installed; PR lookup skipped"
}

test_hung_cli_is_killed_after_timeout() {
  repo_with_origin https://github.com/o/r.git
  gh() { sleep 5; print -r -- $'fix/A\t#1\topen\tu\tt'; }
  local err; err="$(WT_FORGE_TIMEOUT=1; forge_pr_rows "$HOME/r" 2>&1 >/dev/null)"
  assert_eq "$err" "github lookup timed out after 1s; PR column left empty"
  unstub
}

test_kind_is_detected_once_per_host() {
  unstub
  WT_FORGE_KINDS=()
  glab() { print -r -- x >> "$HOME/glab.calls"; [[ "$1 $2" == "auth status" ]]; }
  gh() { return 1; }
  forge_kind gl.example.com >/dev/null
  forge_kind gl.example.com >/dev/null
  assert_eq "$(forge_kind gl.example.com)" gitlab
  assert_eq "$(wc -l < "$HOME/glab.calls" | tr -d ' ')" 1
  WT_FORGE_KINDS=()
  unstub
}

run_tests
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zsh tests/forge.test.zsh`
Expected: FAIL — `source: no such file or directory: …/lib/forge.zsh`, then `command not found: forge_host_path`.

- [ ] **Step 3: Implement** — create `lib/forge.zsh`:

```zsh
# PR/MR lookup for `status`: one `gh`/`glab` call per repo, normalized to
# "branch<TAB>ref<TAB>state<TAB>url" rows. Failures print one reason line on stderr and return 1;
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
  if _forge_has gh && gh auth status --hostname "$host" </dev/null >/dev/null 2>&1; then
    print -r -- github; return
  fi
  if _forge_has glab && glab auth status --hostname "$host" </dev/null >/dev/null 2>&1; then
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

# _forge_latest_per_branch: "branch ref state url updated" rows on stdin -> one
# "branch ref state url" row per branch, keeping the most recently updated. ISO-8601 UTC
# timestamps from one forge compare correctly as strings.
_forge_latest_per_branch() {
  local -A best when
  local -a order
  local b ref st u t
  while IFS=$'\t' read -r b ref st u t; do
    [[ -n "$b" ]] || continue
    if (( ! ${+when[$b]} )); then
      order+=("$b")
    elif [[ ! "$t" > "${when[$b]}" ]]; then
      continue
    fi
    when[$b]="$t"; best[$b]="$ref"$'\t'"$st"$'\t'"$u"
  done
  for b in "${order[@]}"; do print -r -- "$b"$'\t'"${best[$b]}"; done
}

# forge_pr_rows <repo_path>: PR/MR rows for origin's repository. state is one of
# open|draft|merged|closed; ref is "#N" (GitHub) or "!N" (GitLab).
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
        --json headRefName,number,state,isDraft,url,updatedAt \
        --jq '.[] | [.headRefName, "#\(.number)", (if .isDraft and .state == "OPEN" then "draft" else (.state | ascii_downcase) end), .url, .updatedAt] | @tsv'
      rc=$? out="$REPLY" ;;
    gitlab)
      _forge_has glab || { print -u2 -r -- "glab is not installed; MR lookup skipped"; return 1; }
      _forge_run glab mr list -R "$url" --all --per-page 100 -F json \
        --jq '.[] | [.source_branch, "!\(.iid)", (if .state == "opened" then (if .draft then "draft" else "open" end) elif .state == "locked" then "closed" else .state end), .web_url, .updated_at] | @tsv'
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
```

`bin/workytree` sources `lib/*.zsh` by glob, so no registration is needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zsh tests/forge.test.zsh && zsh -n lib/forge.zsh`
Expected: `25 passed, 0 failed` (the timeout test takes about a second).

- [ ] **Step 5: Commit**

```bash
git add lib/forge.zsh tests/forge.test.zsh
git commit -F - <<'MSG'
feat(status): look up PR/MR state per repo via gh/glab

One gh/glab call per repo (state=all), normalized to branch/ref/state/url rows and
de-duplicated to the most recently updated PR per branch, so status can join on branch
names locally. glab takes origin's URL as -R, which keeps self-hosted hosts intact.

Forge detection is cached per host: `glab auth status` measured ~0.8s per call against a
self-hosted GitLab, repeated for every repo on that host. macOS has no timeout(1), so the
lookup is polled and killed after WT_FORGE_TIMEOUT seconds.
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CBX99GukqTQY3UUmsQLM3H
MSG
```


---

### Task 2: Read-only orphan scan (`_prune_scan`)

**Files:**
- Modify: `lib/cmd/prune.zsh:16-177` (the `prune_repo` header comment through its closing `}`)
- Test: `tests/prune_internal.test.zsh` (append two tests)

**Interfaces:**
- Consumes: existing `worktree_parent`, `project_worktree_root`, `_prune_candidate_is_contained`.
- Produces: `_prune_scan <project> <repo> <repo_path>` → rc 0 scanned / 1 refused (error printed, unchanged messages) / 2 no worktree dir; sets globals `WT_SCAN_ROOT`, `WT_SCAN_ROOT_CANON`, `WT_SCAN_CFG_ROOT_CANON`, assoc `WT_SCAN_REGISTERED` (canonical path → 1), array `WT_SCAN_ORPHANS` (raw candidate dirs). Never runs `git worktree prune`, never deletes.

- [ ] **Step 1: Write the failing tests** — in `tests/prune_internal.test.zsh`, insert before the final `run_tests` line:

```zsh
# _prune_scan is what `status` calls: it must report orphans without running
# `git worktree prune` and without deleting anything.
test_prune_scan_lists_orphans_without_touching_anything() {
  make_repo "$HOME/src/app"
  set_project "$HOME/src" "$HOME/wts"
  git -C "$HOME/src/app" worktree add -q -b fix/LIVE "$HOME/wts/app/fix/LIVE"
  git -C "$HOME/src/app" worktree add -q -b fix/GONE "$HOME/wts/app/fix/GONE"
  rm -rf "$HOME/wts/app/fix/GONE"
  mkdir -p "$HOME/wts/app/fix/ORPHAN/.idea"
  _prune_scan me app "$HOME/src/app"
  assert_eq "$?" 0
  assert_eq "${WT_SCAN_ORPHANS[*]}" "$HOME/wts/app/fix/ORPHAN"
  assert_dir "$HOME/wts/app/fix/ORPHAN"
  assert_contains "$(git -C "$HOME/src/app" worktree list --porcelain)" "$HOME/wts/app/fix/GONE"
}

test_prune_scan_returns_2_when_repo_has_no_worktree_dir() {
  make_repo "$HOME/src/app"
  set_project "$HOME/src" "$HOME/wts"
  _prune_scan me app "$HOME/src/app"
  assert_eq "$?" 2
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zsh tests/prune_internal.test.zsh`
Expected: FAIL — `command not found: _prune_scan` (the 15 existing assertions still pass).

- [ ] **Step 3: Split the scan out** — in `lib/cmd/prune.zsh`, replace everything from the line `# prune_repo <project> <repo> <repo_path>: clears git's stale worktree registrations for` (line 16) through the closing `}` of `prune_repo` (line 177) with the block below. It moves the safety checks, the registered-worktree set and the depth-2 candidate walk into `_prune_scan` with their comments, and leaves the deletions (and the kind-dir sweep) in `prune_repo`:

```zsh
# _prune_scan <project> <repo> <repo_path>: the read-only half of prune_repo -- the
# worktree_root safety checks, the set of live worktrees, and the unregistered
# <kind>/<ticket> directories under <worktree_root>/<repo>. `status` calls it without prune's
# `git worktree prune` first, so it changes nothing. Sets WT_SCAN_ROOT (raw) and
# WT_SCAN_ROOT_CANON, WT_SCAN_CFG_ROOT_CANON, WT_SCAN_REGISTERED (canonical path -> 1) and
# WT_SCAN_ORPHANS (raw candidate paths). rc 0 scanned, 1 refused (error printed), 2 no
# worktree dir for the repo.
typeset -g WT_SCAN_ROOT='' WT_SCAN_ROOT_CANON='' WT_SCAN_CFG_ROOT_CANON=''
typeset -gA WT_SCAN_REGISTERED
typeset -ga WT_SCAN_ORPHANS
_prune_scan() {
  local project="$1" repo="$2" repo_path="$3"
  local repo_wt_root repo_wt_root_canon repo_path_canon
  local configured_wt_root configured_wt_root_canon
  WT_SCAN_REGISTERED=() WT_SCAN_ORPHANS=()
  repo_wt_root="$(worktree_parent "$project" "$repo")"

  # C-1 layer 2 / I-3: anchor every deletion target to the CONFIGURED worktree_root itself --
  # not merely to repo_wt_root, a value DERIVED from it by concatenating the repo name.
  # require_config (lib/resolve.zsh) already rejects a project with a missing/empty
  # worktree_root (R27, layer 1) for every command that calls it, but that is a config-time
  # check: this scan must not assume its caller ran require_config, and a worktree_root that
  # is non-empty but still dangerous (e.g. configured as "/" outright) passes layer 1 without
  # trouble. Re-derive and re-check the configured root here, independently -- and BEFORE the
  # `-d "$repo_wt_root"` existence check below: canonicalization (`:A`) works on a path that
  # doesn't exist yet, and an unsafe root must be refused unconditionally, not only on the
  # filesystem coincidence that something already happens to exist there.
  repo_wt_root_canon="${repo_wt_root:A}"
  repo_path_canon="${repo_path:A}"
  configured_wt_root="$(project_worktree_root "$project")"
  configured_wt_root_canon="${configured_wt_root:A}"
  if [[ -z "$configured_wt_root_canon" || "$configured_wt_root_canon" == "/" ]]; then
    error "refusing to prune $repo: project '$project' has no safe worktree_root (\"$configured_wt_root_canon\")"
    return 1
  fi
  # A repo name containing ".." (reachable via a hand-edited or, later, `repo add --name`
  # registered alias -- see is_safe_repo_name/R29 in lib/resolve.zsh) can make
  # worktree_parent's "$worktree_root/$repo" concatenation canonicalize OUTSIDE
  # worktree_root entirely, so repo_wt_root_canon must be re-checked against the configured
  # root directly rather than trusted just because it was built from worktree_parent.
  if [[ "$repo_wt_root_canon" != "$configured_wt_root_canon"/* ]]; then
    error "refusing to prune $repo: computed worktree directory ($repo_wt_root_canon) is not inside the configured worktree_root ($configured_wt_root_canon)"
    return 1
  fi
  if [[ "$repo_wt_root_canon" == "$repo_path_canon" ]]; then
    error "refusing to prune $repo: worktree directory equals the repo path itself ($repo_wt_root_canon)"
    return 1
  fi
  WT_SCAN_ROOT="$repo_wt_root" WT_SCAN_ROOT_CANON="$repo_wt_root_canon"
  WT_SCAN_CFG_ROOT_CANON="$configured_wt_root_canon"

  [[ -d "$repo_wt_root" ]] || return 2

  # Build the set of live worktree paths ONCE per repo, canonicalized (:A) on both sides so
  # a symlinked worktree_root/repo_root (macOS's /var -> /private/var, which has already
  # bitten this project twice) can't make a live worktree look unregistered. Read via
  # `<(...)`/`<<<`, never a `cmd | while` pipe -- zsh runs a pipe's right-hand side in a
  # subshell, and this associative array would vanish the instant the loop ends.
  #
  # R24 fail-closed: if `git worktree list --porcelain` itself fails, an EMPTY registered
  # set would make every live worktree look orphaned and eligible for deletion below --
  # refuse to touch anything for this repo rather than risk that.
  local wt_porcelain rc wt_line wtpath
  wt_porcelain="$(git -C "$repo_path" worktree list --porcelain 2>&1)"; rc=$?
  if (( rc != 0 )); then
    error "could not list worktrees for $repo (git exited $rc); refusing to touch its directories:"
    print -r -- "$wt_porcelain" | sed 's/^/  /' >&2
    return 1
  fi
  while IFS= read -r wt_line; do
    [[ "$wt_line" == "worktree "* ]] || continue
    wtpath="${wt_line#worktree }"
    WT_SCAN_REGISTERED[${wtpath:A}]=1
  done <<< "$wt_porcelain"
  # A real git repo always registers at least its main worktree; an empty set here means the
  # porcelain output could not be parsed as expected -- not that no worktrees exist.
  if (( ${#WT_SCAN_REGISTERED} == 0 )); then
    error "could not determine live worktrees for $repo; refusing to touch its directories"
    return 1
  fi

  local dir dir_canon
  while IFS= read -r -d '' dir; do
    [[ -n "$dir" ]] || continue
    dir_canon="${dir:A}"
    # Containment guard: the candidate must actually resolve under BOTH repo_wt_root_canon
    # and the configured root directly. find's -mindepth/-maxdepth already scoped the walk
    # (using default -P behavior -- no -L flag -- so a symlinked <kind>/<ticket> component
    # is never even listed, let alone descended into; verified empirically), but never let
    # the loop's shape alone decide what gets deleted -- see _prune_candidate_is_contained.
    _prune_candidate_is_contained "$dir_canon" "$repo_wt_root_canon" "$configured_wt_root_canon" || continue
    [[ -n "${WT_SCAN_REGISTERED[$dir_canon]:-}" ]] && continue
    WT_SCAN_ORPHANS+=("$dir")
  # M-2: NUL-delimited, matching dir_is_cruft_only's own convention -- a newline-delimited
  # read would split a directory name containing an embedded newline into fragments, so
  # prune_repo's warning/removal would name a nonexistent path and the real orphan would never be
  # inspected at all.
  done < <(find "$repo_wt_root" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
  return 0
}

# prune_repo <project> <repo> <repo_path>: clears git's stale worktree registrations for
# <repo_path>, then sweeps <worktree_root>/<repo>/<kind>/<ticket> (depth 2) for directories
# that are NOT registered as live worktrees, deleting one only when dir_is_cruft_only
# confirms it holds nothing but discardable cruft (R24: unregistered + cruft-only ->
# delete; anything else, including "couldn't tell" -> keep and warn). Finally drops
# <kind> parent dirs left holding no live worktree and only cruft.
#
# Every `rm -rf` target here is guarded explicitly rather than trusted to the shape of the
# `find` calls that produced it (see the containment checks below) -- this function deletes
# real directories on the verdict of dir_is_cruft_only, and Task 6 (`remove`) already showed
# once that a guard which merely LOOKS sufficient can fail open.
prune_repo() {
  local project="$1" repo="$2" repo_path="$3"
  info "pruning worktrees for $repo"

  # M-1: an earlier version merged git's stderr into stdout (`2>&1 | sed`) and discarded the
  # pipeline's exit code entirely (a `cmd | sed` pipeline's $? is sed's, not git's) -- so a
  # genuine git failure here was reported as ordinary stdout chatter, on stdout, with no
  # visible sign anything had gone wrong. Capture stdout/stderr separately, route each to the
  # matching stream, and keep git's own exit code.
  local prune_out_file prune_err_file prune_rc
  prune_out_file="$(mktemp 2>/dev/null)" && prune_err_file="$(mktemp 2>/dev/null)"
  if [[ -n "$prune_out_file" && -n "$prune_err_file" ]]; then
    git -C "$repo_path" worktree prune --verbose >"$prune_out_file" 2>"$prune_err_file"
    prune_rc=$?
    [[ -s "$prune_out_file" ]] && sed 's/^/  /' "$prune_out_file"
    [[ -s "$prune_err_file" ]] && sed 's/^/  /' "$prune_err_file" >&2
    rm -f "$prune_out_file" "$prune_err_file"
  else
    git -C "$repo_path" worktree prune --verbose >/dev/null 2>&1
    prune_rc=$?
  fi
  (( prune_rc == 0 )) || warn "  git worktree prune exited $prune_rc for $repo; continuing"

  _prune_scan "$project" "$repo" "$repo_path"
  case $? in
    1) return 1 ;;
    2) dim "  no worktree dir for $repo"; return 0 ;;
  esac

  # found tracks whether the sweep below ever identified an unregistered candidate -- in
  # EITHER loop (M-4: an earlier version only set this in the depth-2 loop, so a repo whose
  # only orphan was an empty <kind> dir removed by the second loop still printed "no orphan
  # dirs found", contradicting its own "removed" line just above it).
  local dir found=0
  for dir in "${WT_SCAN_ORPHANS[@]}"; do
    found=1
    if dir_is_cruft_only "$dir"; then
      # M-3: report a failed rm instead of leaving the orphan unexplained.
      if rm -rf -- "$dir"; then
        success "  removed orphan: $dir"
      else
        error "  failed to remove orphan (left in place): $dir"
      fi
    else
      warn "  skipped orphan with real files (remove manually if intended): $dir"
    fi
  done

  local kdir kdir_canon keep w
  while IFS= read -r -d '' kdir; do
    [[ -n "$kdir" ]] || continue
    kdir_canon="${kdir:A}"
    _prune_candidate_is_contained "$kdir_canon" "$WT_SCAN_ROOT_CANON" "$WT_SCAN_CFG_ROOT_CANON" || continue
    keep=0
    for w in "${(@k)WT_SCAN_REGISTERED}"; do
      [[ "$w" == "$kdir_canon"/* ]] && { keep=1; break; }
    done
    (( keep )) && continue
    found=1
    if dir_is_cruft_only "$kdir"; then
      if rm -rf -- "$kdir"; then
        success "  removed orphan kind dir: $kdir"
      else
        error "  failed to remove orphan kind dir (left in place): $kdir"
      fi
    else
      # N-4: every path that sets `found` must also say something -- an earlier version
      # left this branch silent, so a <kind> dir holding only a loose real file (never
      # visited by the depth-2 loop above, since a FILE directly under <kind> isn't a
      # depth-2 DIRECTORY) made `wt prune` print no summary line at all: not "removed",
      # not "skipped orphan", not even "no orphan dirs found" (found was already 1).
      warn "  skipped orphan kind dir with real files (remove manually if intended): $kdir"
    fi
  done < <(find "$WT_SCAN_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  (( found )) || dim "  no orphan dirs found"
  return 0
}
```

- [ ] **Step 4: Run the new and the existing prune tests**

Run: `zsh tests/prune_internal.test.zsh && zsh tests/prune.test.zsh && zsh tests/manage.test.zsh`
Expected: `20 passed, 0 failed`, `70 passed, 0 failed`, `80 passed, 0 failed` — `prune`'s behaviour and messages are unchanged.

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/prune.zsh tests/prune_internal.test.zsh
git commit -F - <<'MSG'
refactor(prune): split the read-only orphan scan out of prune_repo

status needs prune's orphan detection without prune's `git worktree prune` and
deletions. _prune_scan holds the worktree_root safety checks, the live-worktree set and
the unregistered <kind>/<ticket> walk; prune_repo runs `git worktree prune`, then the scan,
then deletes as before. Messages and exit codes are unchanged.
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CBX99GukqTQY3UUmsQLM3H
MSG
```


---

### Task 3: Per-repo collection and judgement (`lib/status.zsh`)

**Files:**
- Create: `lib/status.zsh`
- Test: `tests/status_internal.test.zsh` (new; Task 4 extends it)

**Interfaces:**
- Consumes: `_worktree_dirt_kind` (lib/worktree.zsh), `worktree_parent` (lib/resolve.zsh), `_prune_scan` + `WT_SCAN_*` (Task 2).
- Produces:
  - Record layout (26 fields) — documented in the file's header comment; Task 4/5 index into it by number.
  - `status_collect_repo <project> <repo> <repo_path> <stale_days> [pr_file]` → records on stdout, reason lines on stderr, always rc 0 (an unreadable repo becomes one `error` record). `pr_file` holds `forge_pr_rows` output.
  - `status_fmt_age <seconds>` → `REPLY` (`<1h`, `Nh`, `Nd`, `Nw`, `Nmo`, `Ny`, `-`).
  - `status_flag <merged> <gone> <pr_state> <dirty> <ahead> <has_upstream> <base_ahead> <locked> <age_s> <stale_s>` → `REPLY` = `dirty|safe|stale|-`.
  - `status_base_ref <repo_path>` → prints a full ref, rc 1 if none.
  - `status_pool_wait <max>` — blocks until fewer than `<max>` background jobs run.
  - `_status_track <track>` → `reply=(ahead behind)`.

- [ ] **Step 1: Write the failing tests** — create `tests/status_internal.test.zsh`:

```zsh
#!/usr/bin/env zsh
# lib/status.zsh and lib/cmd/status.zsh internals, sourced directly.
source "${0:A:h}/helpers.zsh"
for f in ui config resolve worktree forge status; do source "$WT_TEST_ROOT/lib/$f.zsh"; done
source "$WT_TEST_ROOT/lib/cmd/prune.zsh"

test_fmt_age_boundaries() {
  status_fmt_age 0; assert_eq "$REPLY" "<1h"
  status_fmt_age 3599; assert_eq "$REPLY" "<1h"
  status_fmt_age 3600; assert_eq "$REPLY" "1h"
  status_fmt_age 86399; assert_eq "$REPLY" "23h"
  status_fmt_age 86400; assert_eq "$REPLY" "1d"
  status_fmt_age $(( 14 * 86400 - 1 )); assert_eq "$REPLY" "13d"
  status_fmt_age $(( 14 * 86400 )); assert_eq "$REPLY" "2w"
  status_fmt_age $(( 56 * 86400 )); assert_eq "$REPLY" "1mo"
  status_fmt_age $(( 729 * 86400 )); assert_eq "$REPLY" "24mo"
  status_fmt_age $(( 730 * 86400 )); assert_eq "$REPLY" "2y"
  status_fmt_age -; assert_eq "$REPLY" "-"
}

# status_flag <merged> <gone> <pr_state> <dirty> <ahead> <has_upstream> <base_ahead> <locked> <age_s> <stale_s>
test_flag_table() {
  status_flag 1 0 - clean 0 1 0 0 10 100; assert_eq "$REPLY" safe      merged-clean
  status_flag 1 0 - idea-only 0 1 0 0 10 100; assert_eq "$REPLY" safe  idea-only-is-not-work
  status_flag 0 1 - clean - 1 3 0 10 100; assert_eq "$REPLY" safe      gone
  status_flag 0 0 merged clean 0 1 3 0 10 100; assert_eq "$REPLY" safe squash-merged-pr
  status_flag 0 0 closed clean 0 1 3 0 10 100; assert_eq "$REPLY" safe closed-pr
  status_flag 1 0 - real 0 1 0 0 10 100; assert_eq "$REPLY" dirty      uncommitted
  status_flag 1 0 - unknown 0 1 0 0 10 100; assert_eq "$REPLY" dirty   unknown-is-never-safe
  status_flag 1 0 - clean 2 1 0 0 10 100; assert_eq "$REPLY" dirty     unpushed
  status_flag 0 0 - clean - 0 2 0 10 100; assert_eq "$REPLY" dirty     local-only-commits
  status_flag 0 0 merged clean - 0 2 0 10 100; assert_eq "$REPLY" safe local-only-but-pr-merged
  status_flag 1 0 - clean 0 1 0 1 10 100; assert_eq "$REPLY" -         locked-not-safe
  status_flag 1 0 - clean 0 1 0 1 500 100; assert_eq "$REPLY" stale    locked-but-old
  status_flag 0 0 - clean 0 1 2 0 500 100; assert_eq "$REPLY" stale    old
  status_flag 0 0 - real 0 1 2 0 500 100; assert_eq "$REPLY" dirty     dirty-beats-stale
  status_flag 0 0 open clean 0 1 2 0 10 100; assert_eq "$REPLY" -      active
  status_flag 0 0 - clean 0 1 2 0 - 100; assert_eq "$REPLY" -          unknown-age
}

test_track_parsing() {
  _status_track "ahead 3, behind 12"; assert_eq "${reply[*]}" "3 12"
  _status_track "behind 2";           assert_eq "${reply[*]}" "0 2"
  _status_track "";                   assert_eq "${reply[*]}" "0 0"
}

test_base_ref_prefers_origin_head_then_origin_main_then_local() {
  make_repo "$HOME/app"
  assert_eq "$(status_base_ref "$HOME/app")" refs/heads/main local
  git init -q --bare "$HOME/remote.git"
  git -C "$HOME/app" remote add origin "$HOME/remote.git"
  git -C "$HOME/app" push -q origin main main:trunk
  git -C "$HOME/app" fetch -q origin
  assert_eq "$(status_base_ref "$HOME/app")" refs/remotes/origin/main origin-main
  git -C "$HOME/app" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  assert_eq "$(status_base_ref "$HOME/app")" refs/remotes/origin/trunk origin-head
}

# git < 2.41 rejects %(ahead-behind:...); base counts must still come out, one rev-list each.
test_base_counts_without_ahead_behind_support() {
  make_repo "$HOME/src/app"
  typeset -ga WT_PROJECTS=(me)
  typeset -gA WT_PCFG=(me.repo_root "$HOME/src" me.worktree_root "$HOME/wts") WT_CFG=() WT_RCFG=()
  git -C "$HOME/src/app" checkout -q -b topic
  git -C "$HOME/src/app" commit -q --allow-empty -m one
  git -C "$HOME/src/app" commit -q --allow-empty -m two
  git -C "$HOME/src/app" checkout -q main
  git() { [[ "$*" == *ahead-behind* ]] && { print -u2 "fatal: unknown field name: ahead-behind"; return 128; }; command git "$@"; }
  local line; line="$(status_collect_repo me app "$HOME/src/app" 30 | grep $'^branch\t')"
  unfunction git
  local -a f; f=("${(@ps:\t:)line}")
  assert_eq "${f[8]}" topic
  assert_eq "${f[19]} ${f[20]}" "2 0" base-ahead-behind
  assert_eq "${f[9]}" dirty local-only-commits
}

run_tests
```

- [ ] **Step 2: Run to verify they fail**

Run: `zsh tests/status_internal.test.zsh`
Expected: FAIL — `source: no such file or directory: …/lib/status.zsh`, then `command not found: status_fmt_age`.

- [ ] **Step 3: Implement** — create `lib/status.zsh`:

```zsh
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
# base_behind has_upstream pr_ref pr_state pr_url) for a local branch. Reads
# status_collect_repo's locals (b_ts b_up b_track b_ab b_merged pr_ref pr_state pr_url base
# repo_path) through zsh's dynamic scoping; only status_collect_repo calls it.
_status_branch_fields() {
  local br="$1" commit=- merged=0 gone=0 ahead=- behind=- bahead=- bbehind=- has_up=0 counts
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
         "${pr_ref[$br]:--}" "${pr_state[$br]:--}" "${pr_url[$br]:--}")
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

  local -A pr_ref pr_state pr_url
  local b r s u
  if [[ -n "$pr_file" && -s "$pr_file" ]]; then
    while IFS=$'\t' read -r b r s u; do pr_ref[$b]=$r pr_state[$b]=$s pr_url[$b]=$u; done < "$pr_file"
  fi

  local base base_local=- refs fmt
  base="$(status_base_ref "$repo_path")" || base=-
  [[ "$base" == refs/remotes/origin/* ]] && base_local="${base#refs/remotes/origin/}"
  [[ "$base" == refs/heads/* ]] && base_local="${base#refs/heads/}"

  # Keep this to two for-each-ref calls: a git call per branch multiplies with branch count.
  local -A b_ts b_up b_track b_ab b_merged
  local -a f
  fmt=$'%(refname:short)\t%(committerdate:unix)\t%(upstream)\t%(upstream:track,nobracket)'
  refs=""
  [[ "$base" != - ]] && refs="$(git -C "$repo_path" for-each-ref --format="$fmt"$'\t'"%(ahead-behind:$base)" refs/heads 2>/dev/null)"
  [[ -n "$refs" ]] || refs="$(git -C "$repo_path" for-each-ref --format="$fmt" refs/heads 2>/dev/null)"
  for line in "${(@f)refs}"; do
    [[ -n "$line" ]] || continue
    f=("${(@ps:\t:)line}")
    b_ts[${f[1]}]=${f[2]} b_up[${f[1]}]=${f[3]} b_track[${f[1]}]=${f[4]}
    [[ -n "${f[5]:-}" ]] && b_ab[${f[1]}]=${f[5]}
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
        else reply=(- 0 0 - - - - 0 - - -); fi
        age=-; [[ "$active" != - ]] && age=$(( now - active ))
        if [[ "$type" == main ]]; then
          flag=- tags=(main)
        else
          status_flag ${reply[2]} ${reply[3]} ${reply[10]} $dirt ${reply[4]} ${reply[8]} ${reply[6]} $locked $age $stale_s
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
    status_flag ${reply[2]} ${reply[3]} ${reply[10]} - ${reply[4]} ${reply[8]} ${reply[6]} 0 $age $stale_s
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `zsh tests/status_internal.test.zsh && zsh -n lib/status.zsh`
Expected: `36 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/status.zsh tests/status_internal.test.zsh
git commit -F - <<'MSG'
feat(status): collect and judge worktree/branch state per repo

status_collect_repo turns one repo into 26-field records: worktrees from
`git worktree list --porcelain`, branches no worktree holds, and orphan directories from
_prune_scan. Each row gets dirty/safe/stale per the spec's §4.3 (dirty outranks safe; an
undeterminable probe is dirty).

Measured on a 35-repo workspace: per-branch merge-base/rev-list calls and $(...) helpers
made a 93-branch repo take 5.6s, and sequential `git status` over 23 worktrees took ~7s.
Two for-each-ref calls (%(ahead-behind:) on git 2.41+, --merged), REPLY-returning
helpers and a 4-wide dirt-probe pool bring the whole workspace to ~6s offline.
GIT_OPTIONAL_LOCKS=0 keeps `git status` from rewriting the index, whose mtime is the
"last activity" shown -- without it every run made all worktrees look fresh.
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CBX99GukqTQY3UUmsQLM3H
MSG
```


---

### Task 4: `wt status` with table and JSON output

**Files:**
- Modify: `lib/config.zsh` (add `project_setting` after `config_get`, line ~201), `lib/agent.zsh:27-38` (`ai_setting` delegates), `lib/ui.zsh:4-5` (`ui_init force`), `bin/workytree` (comment line 28, `usage()`, dispatch line ~86)
- Create: `lib/cmd/status.zsh` (non-interactive half; Task 5 adds the fzf half)
- Test: `tests/status.test.zsh` (new), `tests/status_internal.test.zsh` (extend)

**Interfaces:**
- Consumes: Task 1 (`forge_pr_rows`, `forge_host_path`, `forge_kind`), Task 3 (`status_collect_repo`, `status_fmt_age`, `status_pool_wait`), existing `all_repos`, `resolve_repo`, `wt_fetch_origin`, `ui_progress`.
- Produces:
  - `project_setting <project> <key>` (lib/config.zsh) — `[project]` value, else global, rc 1 if neither.
  - `ui_init force` — enable colors even when stdout is not a TTY.
  - Globals: `ST_REPO ST_FETCH ST_OFFLINE ST_STALE_FILTER ST_STALE_DAYS ST_JSON ST_PLAIN ST_PROGRESS`, arrays `ST_RECS ST_LINES`, `ST_HEADER`, `WT_STATUS_MAX_JOBS`, `WT_STATUS_FZF_MIN`.
  - `_status_parse_opts <args>`, `status_stale_days <project>`, `_status_collect <notes_file>`, `_status_sort`, `_status_filter`, `_status_records <notes_file>`, `_status_display <record>` (`reply`: mark repo name active commit state pr tags), `_status_format <records>` (fills `ST_RECS`/`ST_LINES`/`ST_HEADER`), `_status_fzf_input` (prints `record<TAB>display`, field 27 = display), `_status_jstr <value>` (`REPLY`).
  - Commands: `cmd_status`, `cmd___status-rows` (fzf input lines; also what the CLI tests read).

- [ ] **Step 1: Write the failing tests**

Create `tests/status.test.zsh`:

```zsh
#!/usr/bin/env zsh
# `wt status` end to end, offline. Rows are read from `__status-rows --no-color`, whose first
# 26 TAB-separated fields are the raw record (lib/status.zsh lists them).
source "${0:A:h}/helpers.zsh"

OLD=202401010000                      # touch -t stamp, far past any stale_days
OLD_GIT="2024-01-01T00:00:00"

fixture() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

# with_origin: a bare origin for app, main pushed and tracked.
with_origin() {
  git init -q --bare "$HOME/remote.git"
  git -C "$HOME/src/app" remote add origin "$HOME/remote.git"
  git -C "$HOME/src/app" push -q -u origin main
}

# age_worktree <path>: make the worktree look untouched since $OLD.
age_worktree() {
  local gd; gd="$(git -C "$1" rev-parse --absolute-git-dir)"
  touch -t $OLD "$gd/index" "$gd/HEAD" "$gd/logs/HEAD" 2>/dev/null
}

commit_in() { git -C "$1" commit -q --allow-empty -m "${2:-work}"; }

# field <branch-or-path> <n> [rows]: field n of the first record whose branch (8) or path (5)
# is <branch-or-path>; MISSING when there is none.
field() {
  local key="$1" n="$2" rows="${3:-$ROWS}" line
  local -a f
  for line in "${(@f)rows}"; do
    f=("${(@ps:\t:)line}")
    [[ "${f[8]}" == "$key" || "${f[5]}" == "$key" ]] && { print -r -- "${f[n]}"; return; }
  done
  print -r -- MISSING
}

load_rows() { ROWS="$(wt __status-rows --offline --no-color "$@")"; }

test_merged_clean_worktree_is_safe() {
  fixture
  wt create app fix DONE main >/dev/null 2>&1
  commit_in "$HOME/wts/app/fix/DONE"
  git -C "$HOME/src/app" merge -q --ff-only fix/DONE
  load_rows
  assert_eq "$(field fix/DONE 1)" worktree
  assert_eq "$(field fix/DONE 9)" safe
  assert_eq "$(field fix/DONE 14)" 1 merged
}

test_fresh_worktree_without_commits_counts_as_safe() {
  fixture
  wt create app fix NEW main >/dev/null 2>&1
  load_rows
  assert_eq "$(field fix/NEW 9)" safe
}

test_old_pushed_unmerged_worktree_is_stale() {
  fixture; with_origin
  wt create app fix OLD main >/dev/null 2>&1
  GIT_COMMITTER_DATE="$OLD_GIT" commit_in "$HOME/wts/app/fix/OLD"
  git -C "$HOME/wts/app/fix/OLD" push -q -u origin fix/OLD
  age_worktree "$HOME/wts/app/fix/OLD"
  load_rows
  assert_eq "$(field fix/OLD 9)" stale
  # Looking must not count as activity: `git status` would otherwise rewrite the index.
  load_rows
  assert_eq "$(field fix/OLD 9)" stale second-run
}

test_unpushed_local_commits_are_dirty_even_when_old() {
  fixture
  wt create app fix LOCAL main >/dev/null 2>&1
  GIT_COMMITTER_DATE="$OLD_GIT" commit_in "$HOME/wts/app/fix/LOCAL"
  age_worktree "$HOME/wts/app/fix/LOCAL"
  load_rows
  assert_eq "$(field fix/LOCAL 9)" dirty
}

test_untracked_file_is_dirty_but_idea_only_is_not() {
  fixture
  wt create app fix UNTR main >/dev/null 2>&1
  wt create app fix IDEA main >/dev/null 2>&1
  print x > "$HOME/wts/app/fix/UNTR/new.txt"
  mkdir -p "$HOME/wts/app/fix/IDEA/.idea"; print x > "$HOME/wts/app/fix/IDEA/.idea/ws.xml"
  load_rows
  assert_eq "$(field fix/UNTR 9)" dirty
  assert_eq "$(field fix/UNTR 16)" real
  assert_eq "$(field fix/IDEA 9)" safe
  assert_eq "$(field fix/IDEA 16)" idea-only
}

test_gone_upstream_is_safe() {
  fixture; with_origin
  wt create app fix GONE main >/dev/null 2>&1
  commit_in "$HOME/wts/app/fix/GONE"
  git -C "$HOME/wts/app/fix/GONE" push -q -u origin fix/GONE
  git -C "$HOME/src/app" push -q origin --delete fix/GONE
  git -C "$HOME/src/app" fetch -q --prune origin
  load_rows
  assert_eq "$(field fix/GONE 15)" 1 gone
  assert_eq "$(field fix/GONE 9)" safe
}

test_ahead_of_upstream_is_dirty() {
  fixture; with_origin
  wt create app fix AHEAD main >/dev/null 2>&1
  git -C "$HOME/wts/app/fix/AHEAD" push -q -u origin fix/AHEAD
  commit_in "$HOME/wts/app/fix/AHEAD"
  load_rows
  assert_eq "$(field fix/AHEAD 17)" 1 ahead
  assert_eq "$(field fix/AHEAD 9)" dirty
}

test_locked_worktree_is_never_safe() {
  fixture
  wt create app fix LOCK main >/dev/null 2>&1
  git -C "$HOME/src/app" worktree lock "$HOME/wts/app/fix/LOCK"
  load_rows
  assert_eq "$(field fix/LOCK 21)" 1 locked
  assert_eq "$(field fix/LOCK 9)" -
}

test_branch_without_worktree_is_listed_but_base_is_not() {
  fixture
  git -C "$HOME/src/app" branch lonely
  load_rows
  assert_eq "$(field lonely 1)" branch
  local line n=0
  for line in "${(@f)ROWS}"; do [[ "$line" == *$'\tmain\t'* ]] && (( ++n )); done
  assert_eq "$n" 1 "main appears once (as the main checkout)"
  assert_eq "$(field main 1)" main
  assert_eq "$(field main 9)" -
}

test_orphan_dir_is_listed_and_left_alone() {
  fixture
  wt create app fix LIVE main >/dev/null 2>&1
  mkdir -p "$HOME/wts/app/fix/ORPH"; print x > "$HOME/wts/app/fix/ORPH/keep.txt"
  load_rows
  assert_eq "$(field "$HOME/wts/app/fix/ORPH" 1)" orphan
  assert_eq "$(field "$HOME/wts/app/fix/ORPH" 7)" ORPH
  assert_dir "$HOME/wts/app/fix/ORPH"
}

test_detached_worktree_is_shown() {
  fixture
  wt create app fix DET main >/dev/null 2>&1
  git -C "$HOME/wts/app/fix/DET" checkout -q --detach
  load_rows
  assert_eq "$(field "$HOME/wts/app/fix/DET" 8)" -
  assert_contains "$(wt status --offline --plain)" "(detached) DET"
}

test_scope_filters() {
  fixture
  make_repo "$HOME/other/tool"
  wt project add them "$HOME/other" "$HOME/wts2" >/dev/null
  wt create app fix A main >/dev/null 2>&1
  load_rows
  assert_eq "$(field "$HOME/other/tool" 1)" main both-projects
  load_rows --project me
  assert_eq "$(field "$HOME/other/tool" 1)" MISSING project-filter
  load_rows tool
  assert_eq "$(field fix/A 1)" MISSING repo-filter
  assert_eq "$(field "$HOME/other/tool" 1)" main repo-filter
}

test_stale_filter_and_override() {
  fixture
  wt create app fix NEW main >/dev/null 2>&1
  git -C "$HOME/src/app" branch keep-me
  wt create app fix ACTIVE main >/dev/null 2>&1
  commit_in "$HOME/wts/app/fix/ACTIVE"
  git -C "$HOME/wts/app/fix/ACTIVE" config branch.fix/ACTIVE.remote .
  git -C "$HOME/wts/app/fix/ACTIVE" config branch.fix/ACTIVE.merge refs/heads/fix/ACTIVE
  load_rows --stale
  assert_eq "$(field main 1)" MISSING main-hidden
  assert_eq "$(field fix/NEW 9)" safe safe-kept
  assert_eq "$(field fix/ACTIVE 1)" MISSING active-hidden
  sleep 1
  load_rows --stale 0
  assert_eq "$(field fix/ACTIVE 9)" stale zero-days
}

test_fetch_and_offline_conflict() {
  fixture
  assert_exit 2 wt status --fetch --offline
}

test_unreadable_repo_becomes_one_error_row() {
  fixture
  make_repo "$HOME/src/broken"
  print -r -- garbage > "$HOME/src/broken/.git/HEAD"
  wt create app fix A main >/dev/null 2>&1
  load_rows
  assert_eq "$(field "$HOME/src/broken" 1)" MISSING no-worktree-row
  local line errs=0
  for line in "${(@f)ROWS}"; do [[ "$line" == error$'\t'*$'\tbroken\t'* ]] && (( ++errs )); done
  assert_eq "$errs" 1 one-error-row
  assert_eq "$(field fix/A 1)" worktree others-still-listed
  wt status --offline --plain >/dev/null 2>&1
  assert_eq "$?" 0
}

test_plain_table_when_stdout_is_not_a_terminal() {
  fixture
  wt create app fix A main >/dev/null 2>&1
  local out; out="$(wt status --offline 2>/dev/null)"
  assert_contains "$out" "REPO"
  assert_contains "$out" "fix/A"
}

test_json_is_valid_and_escapes_branch_names() {
  fixture
  git -C "$HOME/src/app" branch 'fix/q"x'
  local out; out="$(wt status --offline --json)"
  assert_contains "$out" '"branch":"fix/q\"x"'
  if (( $+commands[python3] )); then
    print -r -- "$out" | python3 -c 'import json,sys; json.load(sys.stdin)'
    assert_eq "$?" 0 valid-json
  fi
}

test_stale_days_config_is_used() {
  fixture; with_origin
  wt config set stale_days 100000 >/dev/null
  wt create app fix OLD main >/dev/null 2>&1
  GIT_COMMITTER_DATE="$OLD_GIT" commit_in "$HOME/wts/app/fix/OLD"
  git -C "$HOME/wts/app/fix/OLD" push -q -u origin fix/OLD
  age_worktree "$HOME/wts/app/fix/OLD"
  load_rows
  assert_eq "$(field fix/OLD 9)" - not-stale-under-huge-threshold
}

run_tests
```

In `tests/status_internal.test.zsh`, add this line right after `source "$WT_TEST_ROOT/lib/cmd/prune.zsh"`:

```zsh
source "$WT_TEST_ROOT/lib/cmd/status.zsh"
```
and insert before the final `run_tests`:

```zsh
test_json_string_escaping() {
  _status_jstr 'a"b\c';     assert_eq "$REPLY" '"a\"b\\c"'
  _status_jstr $'x\ty\nz';  assert_eq "$REPLY" '"x\u0009y\u000az"'
  _status_jstr -;           assert_eq "$REPLY" null
}

# in_subshell <cmd...>: usage_error exits; keep that exit out of the test process.
in_subshell() { ( "$@" ) }

test_parse_opts() {
  _status_parse_opts app --stale 7 --json
  assert_eq "$ST_REPO $ST_STALE_FILTER $ST_STALE_DAYS $ST_JSON" "app 1 7 1"
  _status_parse_opts --stale
  assert_eq "$ST_STALE_FILTER $ST_STALE_DAYS" "1 -1"
  assert_exit 2 in_subshell _status_parse_opts --fetch --offline
  assert_exit 2 in_subshell _status_parse_opts a b
  assert_exit 2 in_subshell _status_parse_opts --bogus
}

test_stale_days_from_config_and_override() {
  typeset -gA WT_CFG=(stale_days 10) WT_PCFG=(me.stale_days 5)
  ST_STALE_DAYS=-1
  assert_eq "$(status_stale_days me)" 5
  assert_eq "$(status_stale_days other)" 10
  WT_CFG[stale_days]=soon
  assert_eq "$(status_stale_days other 2>/dev/null)" 30
  ST_STALE_DAYS=0
  assert_eq "$(status_stale_days me)" 0
  ST_STALE_DAYS=-1
}

# More repos than WT_STATUS_MAX_JOBS run in batches; output stays in config order.
test_collect_keeps_config_order_across_batches() {
  local n
  for n in a b c d e; do make_repo "$HOME/src/$n"; done
  typeset -ga WT_PROJECTS=(me)
  typeset -gA WT_PCFG=(me.repo_root "$HOME/src" me.worktree_root "$HOME/wts") WT_CFG=() WT_RCFG=()
  WT_STATUS_MAX_JOBS=2 ST_OFFLINE=1 ST_FETCH=0 ST_REPO='' ST_PROGRESS=0 ST_STALE_DAYS=-1
  local out; out="$(_status_collect "$HOME/notes" | cut -f3 | tr '\n' ' ')"
  assert_eq "$out" "a b c d e "
  WT_STATUS_MAX_JOBS=8 ST_OFFLINE=0
}

test_sort_groups_types_then_oldest_first_with_main_checkouts_last() {
  local t=$'\t' d='-'
  local rows="branch${t}p${t}r${t}rp${t}-${t}-${t}-${t}b1${t}-${t}-${t}-${t}-${t}200
worktree${t}p${t}r${t}rp${t}/w2${t}-${t}-${t}w2${t}-${t}-${t}50${t}-${t}-
orphan${t}p${t}r${t}rp${t}/o${t}-${t}-${t}-${t}-${t}-${t}10${t}-${t}-
worktree${t}p${t}r${t}rp${t}/w1${t}-${t}-${t}w1${t}-${t}-${t}40${t}-${t}-
branch${t}p${t}r${t}rp${t}-${t}-${t}-${t}b2${t}-${t}-${t}-${t}-${t}100
main${t}p${t}r${t}rp${t}/m${t}-${t}-${t}m${t}-${t}-${t}1${t}-${t}-"
  assert_eq "$(_status_sort <<< "$rows" | cut -f1,8 | tr '\t\n' ': ')" "worktree:w1 worktree:w2 branch:b2 branch:b1 orphan:- main:m "
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zsh tests/status.test.zsh; zsh tests/status_internal.test.zsh`
Expected: FAIL — `workytree: unknown command: __status-rows` / `source: no such file or directory: …/lib/cmd/status.zsh`.

- [ ] **Step 3: Share the config lookup** — in `lib/config.zsh`, insert after the closing `}` of `config_get` (before the `# _config_die_state` comment):

```zsh
# project_setting <project> <key>: project value -> global value. rc 1 if neither is set.
# No repo-level tier: a [repo] section only exists for explicitly registered repos, so a
# repo discovered by scanning could never use that tier -- the rule would apply
# asymmetrically.
project_setting() {
  local project="$1" key="$2"
  if [[ -n "$project" ]] && (( ${+WT_PCFG[$project.$key]} )); then
    print -r -- "${WT_PCFG[$project.$key]}"; return 0
  fi
  (( ${+WT_CFG[$key]} )) || return 1
  print -r -- "${WT_CFG[$key]}"
}
```

In `lib/agent.zsh`, replace the `ai_setting` comment and function (lines 27-38, from `# ai_setting <project> <key>: project value -> global value.` through its closing `}`) with:

```zsh
ai_setting() { project_setting "$@"; }
```

- [ ] **Step 4: Let callers force color** — in `lib/ui.zsh`, replace:

```zsh
ui_init() {
  if (( WT_COLOR )) && [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
```
with:

```zsh
# ui_init [force]: "force" colors output that is not a TTY yet still reaches one -- fzf's input,
# or stdout the shell wrapper captures before printing.
ui_init() {
  if (( WT_COLOR )) && [[ ( -t 1 || "${1:-}" == force ) && -z "${NO_COLOR:-}" ]]; then
```

- [ ] **Step 5: Register the command** — in `bin/workytree`:

1. Replace `# Set by shell/workytree.zsh only when it will cd to the path \`remove\` prints last.` with `# Set by shell/workytree.zsh only when it will cd to the path \`remove\` or \`status\` prints last.`
2. In `usage()`, after the `workytree list [repo]` line, add:

```text
  workytree status [repo] [--fetch|--offline] [--stale [days]] [--json] [--plain]
                                                         worktree/branch overview; fzf list when available
```
3. Replace the dispatch pattern line

```zsh
    init|create|remove|prune|list|repos|path|cd|project|repo|config|__complete|__ai-configured)
```
with

```zsh
    init|create|remove|prune|list|status|repos|path|cd|project|repo|config|__complete|__ai-configured|__status-rows|__status-preview|__status-action)
```
`__status-preview` and `__status-action` are implemented in Task 5; until then the existing `command not implemented yet` guard answers for them.

- [ ] **Step 6: Implement** — create `lib/cmd/status.zsh`:

```zsh
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
  local -i rc
  # The wrapper captures stdout to find a cd target, but it still lands on the terminal.
  (( WT_CAN_CD )) && ui_init force
  [[ -t 2 ]] && ST_PROGRESS=1
  notes_file="$(mktemp 2>/dev/null)" || die "could not create a temp file"
  records="$(_status_records "$notes_file")" || { rc=$?; rm -f "$notes_file"; exit $rc; }
  if (( ST_JSON )); then _status_render_json "$records" "$notes_file"
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
```

- [ ] **Step 7: Run to verify they pass**

Run: `zsh tests/status_internal.test.zsh && zsh tests/status.test.zsh && zsh tests/agent.test.zsh && zsh tests/config.test.zsh && zsh tests/cli.test.zsh`
Expected: `50 passed`, `44 passed`, `75 passed`, `179 passed`, `10 passed` — all `0 failed`.

Smoke check against a real workspace (read-only): `bin/workytree status --offline --plain | head` prints the `REPO BRANCH ACTIVE COMMIT STATE PR TAGS` header and rows.

- [ ] **Step 8: Commit**

```bash
git add lib/config.zsh lib/agent.zsh lib/ui.zsh bin/workytree lib/cmd/status.zsh tests/status.test.zsh tests/status_internal.test.zsh
git commit -F - <<'MSG'
feat(status): add `wt status` with table and JSON output

Collects every repo in scope in a job pool (8 at once; zsh has no `wait -n`, and batch
waits let one slow repo hold up the rest), then sorts worktrees, branches, orphans, main
checkouts and errors, oldest first. --plain/--json/non-TTY render a table or JSON; Task 5
adds the fzf list.

stale_days resolves through project_setting, the lookup ai_setting already used, now
shared from lib/config.zsh. ui_init gains `force` because the shell wrapper captures
stdout before it reaches the terminal.
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CBX99GukqTQY3UUmsQLM3H
MSG
```


---

### Task 5: fzf list, preview and actions

**Files:**
- Modify: `lib/cmd/status.zsh` (replace `cmd_status`; append the fzf half)
- Test: `tests/status_tui.test.zsh` (new)

**Interfaces:**
- Consumes: Task 4's `ST_*` globals, `_status_format`, `_status_fzf_input`, `_status_records`; existing `cmd_remove`, `dir_is_cruft_only`, `hint`, `warn`.
- Produces: `_status_fzf_ok`, `_status_preview_window`, `_status_reload_args` (`reply`), `_status_run_fzf <records> <notes_file>` (prints a cd target or nothing), commands `cmd___status-preview <line>`, `cmd___status-action remove|open <line>`.

- [ ] **Step 1: Write the failing tests** — create `tests/status_tui.test.zsh`:

```zsh
#!/usr/bin/env zsh
# The fzf renderer, with fzf stubbed as a shell function (bin/workytree's PATH would put a real
# install ahead of any fake executable). The stub records its arguments and answers with a
# canned selection.
source "${0:A:h}/helpers.zsh"
for f in ui config resolve prompt worktree forge status; do source "$WT_TEST_ROOT/lib/$f.zsh"; done
for f in prune remove status; do source "$WT_TEST_ROOT/lib/cmd/$f.zsh"; done

fixture() {
  make_repo "$HOME/src/app"
  typeset -ga WT_PROJECTS=(me)
  typeset -gA WT_PCFG=(me.repo_root "$HOME/src" me.worktree_root "$HOME/wts") WT_CFG=() WT_RCFG=()
  git -C "$HOME/src/app" worktree add -q -b fix/A "$HOME/wts/app/fix/A"
  git -C "$HOME/src/app" branch lonely
  WORKYTREE_HOME="$HOME/with space/workytree"
  WT_PROJECT_OPT='' WT_COLOR=0
  _status_parse_opts --offline
  RECORDS="$(status_collect_repo me app "$HOME/src/app" 30)"
  : > "$HOME/notes"
}

# fzf_selecting <type>: stub fzf that saves its argv (one per line) and stdin, then prints the
# first input line whose record type is <type> (nothing for "none", i.e. esc).
fzf_selecting() {
  FZF_PICK="$1"
  fzf() {
    [[ "$1" == --version ]] && { print -r -- "0.55.0 (stub)"; return; }
    print -rl -- "$@" > "$HOME/fzf.args"
    cat > "$HOME/fzf.in"
    local l
    for l in "${(@f)$(<"$HOME/fzf.in")}"; do
      [[ "$l" == "$FZF_PICK"$'\t'* ]] && { print -r -- "$l"; return 0; }
    done
    return 130
  }
}

test_enter_on_worktree_prints_its_path_last() {
  fixture; fzf_selecting worktree
  assert_eq "$(_status_run_fzf "$RECORDS" "$HOME/notes")" "$HOME/wts/app/fix/A"
}

test_enter_on_branch_row_prints_nothing() {
  fixture; fzf_selecting branch
  assert_eq "$(_status_run_fzf "$RECORDS" "$HOME/notes")" ""
}

test_esc_prints_nothing_and_succeeds() {
  fixture; fzf_selecting none
  local out; out="$(_status_run_fzf "$RECORDS" "$HOME/notes")"
  assert_eq "$?" 0
  assert_eq "$out" ""
}

test_fzf_input_is_record_plus_display_field() {
  fixture; fzf_selecting none
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  local -a f; f=("${(@ps:\t:)$(head -1 "$HOME/fzf.in")}")
  assert_eq "${#f}" 27
  assert_contains "$(<"$HOME/fzf.args")" "--with-nth=27"
}

test_bindings_quote_a_bin_path_with_spaces() {
  fixture; fzf_selecting none
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  local args; args="$(<"$HOME/fzf.args")"
  local qbin="${(q)WORKYTREE_HOME}/bin/workytree"
  assert_contains "$args" "ctrl-d:execute($qbin __status-action remove {})+reload($qbin __status-rows --no-color --offline)"
  assert_contains "$args" "ctrl-r:reload($qbin __status-rows --no-color --offline)"
  assert_contains "$args" "--preview=$qbin __status-preview {}"
  # The reload command must split back into the same words a shell would see.
  local cmd="$qbin __status-rows --no-color --offline"
  local -a words; words=("${(Q@)${(z)cmd}}")
  assert_eq "${words[1]}" "$WORKYTREE_HOME/bin/workytree"
}

test_reload_args_carry_scope_and_stale_filter() {
  fixture
  WT_PROJECT_OPT=me
  _status_parse_opts app --stale 7
  _status_reload_args
  assert_eq "${reply[*]}" "--project me --no-color app --stale 7"
  _status_parse_opts
  WT_PROJECT_OPT='' WT_COLOR=1
  _status_reload_args
  assert_eq "${reply[*]}" ""
}

test_refresh_fetches_unless_offline() {
  fixture; fzf_selecting none
  _status_parse_opts
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  assert_contains "$(<"$HOME/fzf.args")" "ctrl-r:reload(${(q)WORKYTREE_HOME}/bin/workytree __status-rows --no-color --fetch)"
}

test_notes_appear_in_the_header() {
  fixture; fzf_selecting none
  print -r -- "app: github lookup failed (exit 4)" > "$HOME/notes"
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  assert_contains "$(<"$HOME/fzf.args")" "note: app: github lookup failed (exit 4)"
}

# ctrl-d removed the worktree this shell stands in: send the shell back to the main checkout.
test_removed_current_worktree_sends_shell_to_main_checkout() {
  fixture; fzf_selecting none
  local out
  out="$(cd "$HOME/wts/app/fix/A" && git -C "$HOME/src/app" worktree remove "$HOME/wts/app/fix/A" && _status_run_fzf "$RECORDS" "$HOME/notes")"
  assert_eq "$out" "$HOME/src/app"
}

test_old_fzf_falls_back() {
  fzf() { print -r -- "0.30.0 (old)"; }
  local err; err="$(_status_fzf_ok 2>&1)"
  assert_eq "$?" 1
  assert_contains "$err" "fzf 0.30.0 is older than 0.38"
  fzf() { print -r -- "0.38.1 (ok)"; }
  _status_fzf_ok 2>/dev/null
  assert_eq "$?" 0
  unfunction fzf
}

test_action_refuses_non_worktree_rows() {
  fixture
  local branch_line; branch_line="$(print -r -- "$RECORDS" | grep '^branch')"
  local err; err="$(cmd___status-action remove "$branch_line" 2>&1 </dev/null)"
  assert_contains "$err" "only worktrees under worktree_root can be removed from here"
  assert_contains "$err" "branch -d lonely"
}

# fzf searches only the displayed field (--with-nth=27), so ctrl-s's "stale" query and typed
# filters like "gone" need the tags on screen.
test_display_field_carries_the_searchable_tags() {
  fixture; fzf_selecting none
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  local line; line="$(grep $'^branch\t' "$HOME/fzf.in")"
  local -a f; f=("${(@ps:\t:)line}")
  assert_contains "${f[27]}" "safe merged"
}

# Without a terminal (CI, a pipe) the width probe must fall back quietly: a shell error about
# /dev/tty would land in fzf's preview or the user's terminal.
test_preview_window_probe_is_quiet() {
  local err out
  err="$(_status_preview_window 2>&1 >/dev/null)"
  out="$(_status_preview_window 2>/dev/null)"
  assert_eq "$err" ""
  [[ "$out" == (right|down),50% ]]; assert_eq "$?" 0 "layout: $out"
}

run_tests
```

- [ ] **Step 2: Run to verify they fail**

Run: `zsh tests/status_tui.test.zsh`
Expected: FAIL — `command not found: _status_run_fzf`.

- [ ] **Step 3: Choose fzf when it can run** — in `lib/cmd/status.zsh`, replace the whole `cmd_status() { … }` function with:

```zsh
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
```

- [ ] **Step 4: Implement the fzf half** — append to `lib/cmd/status.zsh`:

```zsh
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
  sel="$(_status_fzf_input | fzf --ansi --no-sort --layout=reverse \
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
      local changes; changes="$(git -C "$p" status --short 2>&1)"
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
```

- [ ] **Step 5: Run to verify they pass**

Run: `zsh tests/status_tui.test.zsh && zsh tests/status.test.zsh`
Expected: `23 passed, 0 failed`, `44 passed, 0 failed`.

- [ ] **Step 6: Check the bindings against a real fzf** (the stub cannot) — with fzf ≥ 0.38 installed, in a terminal: run `bin/workytree status`, then confirm (a) the details pane fills for each row type, (b) typing `gone` or pressing `ctrl-s` narrows to tagged rows, (c) `ctrl-d` on a branch row shows the refusal and waits for a key, (d) `enter` on a worktree prints its path, (e) `esc` prints nothing. Without fzf installed, record that this step was skipped.

- [ ] **Step 7: Commit**

```bash
git add lib/cmd/status.zsh tests/status_tui.test.zsh
git commit -F - <<'MSG'
feat(status): fzf list with preview, cd, remove and PR actions

With fzf >= 0.38 and a terminal, status opens an fzf list: the 26-field record rides
along hidden (--with-nth=27) so every binding gets it whole through {}, and fzf
searches only the displayed field, which is why tags are on screen. ctrl-d hands the
row to `remove` through __status-action, which refuses non-worktree rows with a hint;
ctrl-r reloads with --fetch; ctrl-s toggles a "stale" query.

Checked against real fzf 0.38.0 and 0.74.4: bindings parse, interactive selection and {}
both yield the original line. If ctrl-d removes the worktree the shell stands in, status
prints the main checkout so the wrapper can move the shell out.
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CBX99GukqTQY3UUmsQLM3H
MSG
```


---

### Task 6: Shell wrapper, completion, README

**Files:**
- Modify: `shell/workytree.zsh:60` and `:119-120`, `shell/completions/_workytree:~66`, `lib/cmd/complete.zsh:14`, `README.md` (Usage block, new section before `## AI sessions (opt-in)`)
- Test: `tests/shell.test.zsh` (append two tests), `tests/complete.test.zsh:17`

**Interfaces:**
- Consumes: `cmd_status`'s stdout contract (last line = cd target or not a directory) and `WT_CAN_CD`.
- Produces: `wt status` cds on enter; completion for `status`.

- [ ] **Step 1: Write the failing tests** — in `tests/shell.test.zsh`, insert before the final `run_tests`:

```zsh
# status uses the same "last stdout line is a directory -> cd" contract as create/cd/remove.
# The real CLI only prints a path after an fzf selection, so a stand-in binary plays that part
# and reports whether the wrapper claimed the cd capability -- which it must not when its own
# stdout is a pipe, as it is here.
test_status_output_last_line_is_a_cd_target() {
  fixture
  mkdir -p "$HOME/fakebin" "$HOME/target"
  cat > "$HOME/fakebin/wt-status" <<EOF
#!/bin/sh
echo "capable=[\${WORKYTREE_CD_CAPABLE:-}]"
echo "$HOME/target"
EOF
  chmod +x "$HOME/fakebin/wt-status"
  local out
  out="$(zsh_i "WORKYTREE_BIN='$HOME/fakebin/wt-status'; wt status; print -r -- \"pwd=\$PWD\"")"
  assert_contains "$out" "capable=[]"
  assert_contains "$out" "pwd=$HOME/target"
}

test_status_table_output_is_printed_without_cd() {
  fixture
  local out
  out="$(zsh_i "cd '$HOME'; wt status --offline --plain; print -r -- \"pwd=\$PWD\"")"
  assert_contains "$out" "REPO"
  assert_contains "$out" "pwd=$HOME"
}
```

In `tests/complete.test.zsh`, after `  assert_contains "$(wt __complete commands)" "create"` add:

```zsh
  assert_contains "$(wt __complete commands)" "status"
```

- [ ] **Step 2: Run to verify they fail**

Run: `zsh tests/shell.test.zsh; zsh tests/complete.test.zsh`
Expected: FAIL — `pwd=…/target` missing (the wrapper passes `status` straight through) and `status` missing from the command list.

- [ ] **Step 3: Wire the wrapper** — in `shell/workytree.zsh`, change `    create|cd|remove) ;;` to `    create|cd|remove|status) ;;`, and after the `remove` branch:

```zsh
  elif [[ "$sub" == remove && -o interactive ]]; then
    output="$(WORKYTREE_CD_CAPABLE=1 "$WORKYTREE_BIN" "${call_args[@]}")"
```
add:

```zsh
  # status opens fzf only when its output reaches a terminal; `wt status | grep` must get the
  # table, so the capability is not claimed when this function's own stdout is a pipe.
  elif [[ "$sub" == status && -o interactive && -t 1 ]]; then
    output="$(WORKYTREE_CD_CAPABLE=1 "$WORKYTREE_BIN" "${call_args[@]}")"
```

- [ ] **Step 4: Completion** — in `lib/cmd/complete.zsh`, change the `commands)` list to `print -l init create remove prune list status repos path cd project repo config help ;;`. In `shell/completions/_workytree`, insert before the `    project) …` case arm:

```zsh
    status)
      (( idx == 1 )) && _workytree_values repo repos
      _values -w flag --fetch --offline --stale --json --plain ;;
```

- [ ] **Step 5: README** — in the Usage block, after `    wt list [repo] · wt repos · wt path [repo [kind [ticket]]]`, add `    wt status [repo] [--fetch|--offline] [--stale [days]] [--json] [--plain]`. Insert this section before `## AI sessions (opt-in)`:

```markdown
## Status

`wt status` lists every worktree, every local branch without a worktree, and every
directory under `worktree_root` that git no longer knows about, across the repos in scope
(`--project`, or one `[repo]`). With `fzf` 0.38+ on your `PATH` and a terminal on both ends it
opens an fzf list with a details pane; otherwise — `--plain`, no or older `fzf`, or output
piped somewhere — it prints a table. `--json` prints the same data for scripts.

Looking changes nothing: `status` never prunes, fetches (unless `--fetch`), or deletes.

| mark | meaning |
| --- | --- |
| `✓` | safe to remove: merged into the base branch, its PR/MR merged or closed, or its upstream deleted — **and** no uncommitted changes, no unpushed commits, not locked |
| `●` | stale: untouched for longer than `stale_days` (default 30) but not provably safe |
| `!` | removing it would lose work: uncommitted changes (or ones git could not check), commits not on its upstream, or — with no upstream — commits not on the base branch |

`ACTIVE` is the last activity in the worktree (its index/HEAD), `COMMIT` the branch's last
commit; creation times are in the details pane. The base branch is `origin/HEAD`, else
`origin/main` or `origin/master`, else the main checkout's branch. A branch with no commits of
its own is "merged" — a worktree you just created and have not committed to shows `✓`.

| key | action |
| --- | --- |
| `enter` | cd into the worktree (shell integration only; `bin/workytree` prints the path) |
| `ctrl-d` | `wt remove` the worktree, with its usual questions, then refresh |
| `ctrl-o` | open the PR/MR in the browser |
| `ctrl-r` | `git fetch` every repo, then refresh |
| `ctrl-s` | show only `stale`/`safe` rows (again to show all) |

PR/MR data comes from `gh` (GitHub) or `glab` (GitLab, including self-hosted hosts `glab` is
logged in to), one call per repo; without them, or with `--offline`, the PR column is empty
and everything else still works. A squash or rebase merge leaves no ancestry for git to find,
so such a branch only shows as merged while its PR/MR can be looked up.

`✓` relies on `git status`, so it shares `remove`'s blind spot below: gitignored files such as
`.env` do not count as work.

    wt config set stale_days 14                  # every project
    wt config set project.work.stale_days 60     # one project

Scripts should call `bin/workytree status --json` directly: through the `wt` function the
output is captured first to look for a cd target.
```

- [ ] **Step 6: Run the touched tests, then everything**

Run: `zsh tests/shell.test.zsh && zsh tests/complete.test.zsh && zsh tests/run.zsh`
Expected: `58 passed`, `14 passed`, then every file `0 failed` (957 assertions in total).

Also run the CI lint loop locally:

```bash
for f in bin/workytree lib/*.zsh lib/cmd/*.zsh shell/workytree.zsh shell/completions/_workytree tests/*.zsh; do zsh -n "$f" || echo "syntax error: $f"; done
```

- [ ] **Step 7: Commit**

```bash
git add shell/workytree.zsh shell/completions/_workytree lib/cmd/complete.zsh README.md tests/shell.test.zsh tests/complete.test.zsh
git commit -F - <<'MSG'
feat(status): wire status into the shell wrapper, completion and README

The wrapper treats status like remove: the last stdout line, when it is a directory,
becomes the cd target. It claims the cd capability only when its own stdout is a
terminal, so `wt status | grep x` gets the table instead of an fzf list.
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CBX99GukqTQY3UUmsQLM3H
MSG
```

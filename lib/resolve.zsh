# Repo/project resolution. Order: registered [repo] alias -> scan of every [project].repo_root -> cwd inference.

require_config() {
  if (( !WT_CONFIG_EXISTS )); then
    error "no config found at $WT_CONFIG_FILE"; error "run 'workytree init' to create one"; exit 3
  fi
  if (( ${#WT_PROJECTS} == 0 )); then
    error "no [project] defined in $WT_CONFIG_FILE"
    error "run 'workytree project add <name> <repo_root> <worktree_root>'"; exit 3
  fi
  # R27/C-1: a [project] section is only meaningful with BOTH repo_root and worktree_root --
  # every path-building helper below (worktree_parent, worktree_path) concatenates
  # worktree_root with a repo/kind/ticket name unconditionally. A project missing (or with an
  # empty) worktree_root collapses that concatenation to "/$repo" at filesystem root; a repo
  # whose name happens to collide with a real top-level directory (etc, tmp, usr, bin, home,
  # Users, private, ...) then makes `prune` walk and delete real system directories -- this
  # was reproduced end-to-end against an instrumented copy. Reject the missing invariant here,
  # for every command that reaches require_config, rather than downstream in each command that
  # happens to build a path from it.
  #
  # N-2: "missing" and "present but unsafe" are different problems and get different
  # wording. The raw config text is checked for presence FIRST, separately from the
  # ~/$VAR-expanded value: `worktree_root = /` is non-empty TEXT, but expand_path's
  # trailing-slash strip collapses it to "" -- reporting that as "missing worktree_root"
  # would misdescribe a value that is actually present, just unusable.
  #
  # R30/N-5: worktree_root == $HOME is legal -- worktrees at ~/<repo>/<kind>/<ticket> is a
  # reasonable, properly-contained layout -- but "/" or any STRICT ANCESTOR of $HOME is
  # refused. R27's emptiness check above cannot catch this: the value is present and
  # resolves to a non-empty path (e.g. "~/.."). Reproduced: worktree_root = ~/.. let
  # prune's <kind> sweep reach real directories (an empty dir and a .DS_Store-only dir)
  # directly under $HOME.
  local p raw_root raw_wt wt_root wt_canon home_canon
  home_canon="${HOME:A}"
  for p in "${WT_PROJECTS[@]}"; do
    raw_root="${WT_PCFG[$p.repo_root]:-}"
    raw_wt="${WT_PCFG[$p.worktree_root]:-}"
    [[ -n "$raw_root" ]] || { error "project '$p' is missing repo_root in $WT_CONFIG_FILE"; exit 3; }
    [[ -n "$raw_wt"   ]] || { error "project '$p' is missing worktree_root in $WT_CONFIG_FILE"; exit 3; }
    [[ -n "$(project_repo_root "$p")" ]] || {
      error "project '$p' has an unusable repo_root (\"$raw_root\") in $WT_CONFIG_FILE"; exit 3; }
    wt_root="$(project_worktree_root "$p")"
    if [[ -z "$wt_root" ]]; then
      error "project '$p' has an unusable worktree_root (\"$raw_wt\") in $WT_CONFIG_FILE"; exit 3
    fi
    wt_canon="${wt_root:A}"
    if ! is_safe_worktree_root "$wt_canon" "$home_canon"; then
      error "project '$p' has an unsafe worktree_root (\"$wt_canon\"): refusing \"/\" or a strict ancestor of the home directory (\"$home_canon\")"
      exit 3
    fi
  done
  if [[ -n "$WT_PROJECT_OPT" ]] && ! project_exists "$WT_PROJECT_OPT"; then
    die "unknown project: $WT_PROJECT_OPT (run 'workytree project list')"
  fi
}

# is_safe_repo_name <name>: false for empty, a bare path separator, or a dot-relative path
# component ("." or ".."). Repo names come straight from config -- an attacker- or
# typo-editable `[repo <name>]` section key today, reachable without hand-editing once `repo
# add --name` exists -- and get concatenated directly into filesystem paths by
# worktree_parent/worktree_path ("$worktree_root/$repo/..."). An unfiltered ".." lets that
# concatenation canonicalize OUTSIDE worktree_root entirely; reproduced with a config
# containing `[repo ..]`, where `prune` deleted a directory outside
# <worktree_root>/<repo>/ despite every containment check that compares against a path
# DERIVED from the repo name passing "by construction" (the escape happens before any of
# those checks run). R29.
is_safe_repo_name() {
  local n="$1"
  [[ -n "$n" && "$n" != "." && "$n" != ".." && "$n" != */* ]]
}

# is_safe_worktree_root <canonicalized-path> [home_canon]: false for "/" or a STRICT
# ancestor of $HOME; worktree_root == $HOME itself is legal (see the R30/N-5 note on
# require_config above -- this is the single source of that rule, shared by require_config
# and by `workytree project add`'s own up-front validation so the two can never drift).
# <canonicalized-path> must already be run through ":A" by the caller; home_canon is
# likewise expected pre-canonicalized and defaults to "${HOME:A}" when omitted.
is_safe_worktree_root() {
  local wt_canon="$1" home_canon="${2:-${HOME:A}}"
  [[ "$wt_canon" != "/" && "$home_canon" != "$wt_canon"/* ]]
}

project_exists()        { (( ${WT_PROJECTS[(Ie)$1]} )); }
project_repo_root()     { expand_path "${WT_PCFG[$1.repo_root]:-}"; }
project_worktree_root() { expand_path "${WT_PCFG[$1.worktree_root]:-}"; }
project_scan_depth()    { print -r -- "${WT_PCFG[$1.scan_depth]:-3}"; }
default_project()       { print -r -- "${WT_CFG[default_project]:-${WT_PROJECTS[1]:-}}"; }
config_kinds()           { print -l -- "${(s:,:)${WT_CFG[kinds]:-feature,fix,chore,hotfix,refactor}}"; }  # R3: one kind per line

# scan_project_repos <project>: "name\tproject\tpath" for every git repo under repo_root (depth-limited)
scan_project_repos() {
  local p="$1" root depth entry r
  root="$(project_repo_root "$p")"; depth="$(project_scan_depth "$p")"
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 2 -maxdepth $(( depth + 1 )) -name .git \( -type d -o -type f \) -print -prune 2>/dev/null \
    | while IFS= read -r entry; do r="${entry:h}"; print -r -- "${r:t}"$'\t'"$p"$'\t'"$r"; done | sort -u
}

registered_repos() {
  local filter="${1:-}" n p
  for n in "${WT_REPOS[@]}"; do
    p="${WT_RCFG[$n.project]:-}"
    [[ -n "$filter" && "$p" != "$filter" ]] && continue
    # R29: never surface a registered repo whose NAME is itself unsafe to concatenate into a
    # filesystem path (see is_safe_repo_name) -- this is the choke point `all_repos` (and
    # therefore bare `workytree prune`'s all-repos sweep) reads registered repos through, so
    # filtering here keeps an unsafe name out of every caller at once.
    if ! is_safe_repo_name "$n"; then
      error "ignoring unsafe repo name in config: $n"
      continue
    fi
    print -r -- "$n"$'\t'"$p"$'\t'"$(expand_path "${WT_RCFG[$n.path]:-}")"
  done
}


# all_repos <filter>: emits one "name\tproject\tpath" row per PHYSICAL repo, never two. A
# registered [repo] alias always wins over anything scanned (matching resolve_repo's own
# precedence); among scanned candidates for the same physical repo (nested/overlapping
# repo_roots), project_of_path's longest-prefix rule picks the winner -- see R18.
all_repos() {
  local filter="${1:-}" p n rp rpath phys winner idx
  local -a out out_phys out_registered
  while IFS=$'\t' read -r n rp rpath; do
    out+=("$n"$'\t'"$rp"$'\t'"$rpath")
    out_phys+=("${rpath:A}")
    out_registered+=(1)
  done < <(registered_repos "$filter")
  for p in "${WT_PROJECTS[@]}"; do
    [[ -n "$filter" && "$p" != "$filter" ]] && continue
    while IFS=$'\t' read -r n rp rpath; do
      phys="${rpath:A}"
      idx=${out_phys[(Ie)$phys]}
      if (( idx )); then
        (( out_registered[idx] )) && continue
        winner="$(project_of_path "$phys")"
        [[ "$winner" == "$rp" ]] && out[idx]="$n"$'\t'"$rp"$'\t'"$rpath"
        continue
      fi
      out+=("$n"$'\t'"$rp"$'\t'"$rpath")
      out_phys+=("$phys")
      out_registered+=(0)
    done < <(scan_project_repos "$p")
  done
  local o
  for o in "${out[@]}"; do print -r -- "$o"; done
}

is_known_repo() { all_repos "$WT_PROJECT_OPT" | cut -f1 | grep -qx -- "$1"; }

# resolve_repo <name> [project] -> "project\tpath"
resolve_repo() {
  local name="$1" filter="${2:-$WT_PROJECT_OPT}" p rn rp rpath line phys winner idx
  local -a matches matches_phys
  if (( ${WT_REPOS[(Ie)$name]} )); then
    # R29: this branch matched because $name IS a registered [repo] section key -- validate
    # that key before trusting it to build a filesystem path anywhere downstream.
    if ! is_safe_repo_name "$name"; then
      error "unsafe repo name: $name"; exit 1
    fi
    p="${WT_RCFG[$name.project]:-}"
    if [[ -z "$filter" || "$p" == "$filter" ]]; then
      print -r -- "$p"$'\t'"$(expand_path "${WT_RCFG[$name.path]:-}")"; return 0
    fi
  fi
  for p in "${WT_PROJECTS[@]}"; do
    [[ -n "$filter" && "$p" != "$filter" ]] && continue
    while IFS=$'\t' read -r rn rp rpath; do
      [[ "$rn" == "$name" ]] || continue
      # Defensive: scan_project_repos derives rn from a real directory basename, which can't
      # structurally be "." or "..", but never trust that structural argument alone this deep
      # into a function that feeds worktree_parent/worktree_path.
      is_safe_repo_name "$rn" || continue
      # Collapse candidates naming the same PHYSICAL repo (nested/overlapping repo_roots):
      # the project whose repo_root is the longest matching prefix wins. Reuse
      # project_of_path's own longest-prefix rule instead of re-deriving it here (R18).
      phys="${rpath:A}"
      idx=${matches_phys[(Ie)$phys]}
      if (( idx )); then
        winner="$(project_of_path "$phys")"
        [[ "$winner" == "$rp" ]] && matches[idx]="$rp"$'\t'"$rpath"
      else
        matches+=("$rp"$'\t'"$rpath")
        matches_phys+=("$phys")
      fi
    done < <(scan_project_repos "$p")
  done
  case ${#matches} in
    0) error "repo not found: $name (run 'workytree repos')"; exit 1 ;;
    1) print -r -- "${matches[1]}" ;;
    *) error "repo name '$name' is ambiguous across projects; narrow it with --project <name>:"
       for line in "${matches[@]}"; do print -u2 -r -- "  ${line%%$'\t'*}"$'\t'"${line#*$'\t'}"; done
       exit 1 ;;
  esac
}

# project_of_path <path>: project whose repo_root or worktree_root contains it (longest match)
project_of_path() {
  local target="${1:A}" p root best="" bestlen=0
  for p in "${WT_PROJECTS[@]}"; do
    for root in "$(project_repo_root "$p")" "$(project_worktree_root "$p")"; do
      [[ -n "$root" ]] || continue
      root="${root:A}"
      [[ "$target" == "$root" || "$target" == "$root"/* ]] || continue
      (( ${#root} > bestlen )) && { best="$p"; bestlen=${#root}; }
    done
  done
  [[ -n "$best" ]] && print -r -- "$best"
}

# infer_current_repo -> "project\tname\trepo_path" for the canonical repo of cwd (works inside worktrees)
infer_current_repo() {
  local common repo_path p n
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  repo_path="${common:A:h}"
  for n in "${WT_REPOS[@]}"; do
    if [[ "$(expand_path "${WT_RCFG[$n.path]:-}"):A" == "$repo_path" ]]; then
      print -r -- "${WT_RCFG[$n.project]:-}"$'\t'"$n"$'\t'"$repo_path"; return 0
    fi
  done
  p="$(project_of_path "$repo_path")" || return 1
  print -r -- "$p"$'\t'"${repo_path:t}"$'\t'"$repo_path"
}

worktree_parent() { local p="$1" repo="$2" kind="${3:-}"; print -r -- "$(project_worktree_root "$p")/$repo${kind:+/$kind}"; }
worktree_path()   { print -r -- "$(project_worktree_root "$1")/$2/$3/$4"; }

default_base_ref() {
  local repo_path="$1" upstream current
  upstream="$(git -C "$repo_path" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" && "$upstream" != "@{upstream}" ]]; then print -r -- "$upstream"; return 0; fi
  current="$(git -C "$repo_path" branch --show-current 2>/dev/null || true)"
  [[ -n "$current" ]] || die "cannot determine base branch from $repo_path"
  print -r -- "$current"
}

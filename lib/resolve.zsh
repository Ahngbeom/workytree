# Repo/project resolution. Order: registered [repo] alias -> scan of every [project].repo_root -> cwd inference.

require_config() {
  if (( !WT_CONFIG_EXISTS )); then
    error "no config found at $WT_CONFIG_FILE"; error "run 'workytree init' to create one"; exit 3
  fi
  if (( ${#WT_PROJECTS} == 0 )); then
    error "no [project] defined in $WT_CONFIG_FILE"
    error "run 'workytree project add <name> <repo_root> <worktree_root>'"; exit 3
  fi
  if [[ -n "$WT_PROJECT_OPT" ]] && ! project_exists "$WT_PROJECT_OPT"; then
    die "unknown project: $WT_PROJECT_OPT (run 'workytree project list')"
  fi
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
    p="${WT_RCFG[$name.project]:-}"
    if [[ -z "$filter" || "$p" == "$filter" ]]; then
      print -r -- "$p"$'\t'"$(expand_path "${WT_RCFG[$name.path]:-}")"; return 0
    fi
  fi
  for p in "${WT_PROJECTS[@]}"; do
    [[ -n "$filter" && "$p" != "$filter" ]] && continue
    while IFS=$'\t' read -r rn rp rpath; do
      [[ "$rn" == "$name" ]] || continue
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

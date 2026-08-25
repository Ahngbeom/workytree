# cmd_repo: manage [repo <name>] sections -- explicit registrations for a clone that lives
# outside any project's repo_root. Each one borrows its worktree_root from the project it
# names, so unlike `project add`, `repo add` NEEDS an existing project to attach to and does
# call require_config (the reverse of cmd_project's asymmetry -- see the note there).
#
# R39: require_loadable_config here (not the full require_config) covers `list`/`remove`,
# which read WT_REPOS/WT_RCFG directly and call neither require_config nor anything else --
# without it, a config that failed to PARSE would silently look like "no repos registered"
# instead of the unreadable-config error it actually is. `add` already calls the full
# require_config a few lines into its own branch below; this call is redundant-but-harmless
# there (same WT_CONFIG_LOAD_ERROR, same exit 3), not a second, divergent check.
cmd_repo() {
  require_loadable_config
  local sub="${1:-list}"; (( $# )) && shift
  case "$sub" in
    list)
      # Reuse registered_repos (lib/resolve.zsh) rather than re-deriving from WT_REPOS/WT_RCFG
      # here: it already applies expand_path and the R29 unsafe-name filter, and is the same
      # choke point `workytree repos`/`prune` read through -- one source of truth for what
      # counts as a registered repo, not a second copy that could drift from it.
      local out; out="$(registered_repos)"
      [[ -n "$out" ]] || { warn "no repos registered (run 'workytree repo add <path>')"; return 0; }
      print -r -- "$out" | while IFS=$'\t' read -r n p repo_path; do
        printf '%-16s project=%-12s path=%s\n' "$n" "$p" "$repo_path"
      done ;;
    add)
      require_config
      # R16: never name a local `path` -- it silently destroys $PATH for the rest of this
      # scope (even `local path`), taking `git`/`find` with it. Use repo_path throughout.
      local repo_path="" name="" project=""
      while (( $# )); do
        case "$1" in
          --name)    shift; name="${1:?--name requires a value}" ;;
          --project) shift; project="${1:?--project requires a value}" ;;
          -*)        usage_error "unknown flag: $1" ;;
          *)         [[ -z "$repo_path" ]] || usage_error "usage: workytree repo add <path> [--name n] [--project p]"; repo_path="$1" ;;
        esac; shift
      done
      [[ -n "$repo_path" ]] || usage_error "usage: workytree repo add <path> [--name n] [--project p]"
      repo_path="$(expand_path "$repo_path")"
      # Captured BEFORE the ":A" canonicalization below, so a symlinked path (e.g.
      # "~/proj-link" pointing at ".../proj") can be compared against what the user actually
      # typed -- see the name-derivation note further down.
      local typed_basename="${repo_path:t}"
      repo_path="${repo_path:A}"

      # Verify the path really is a git repo BEFORE anything else -- registering a
      # non-repo would make every later command that resolves this name (path/create/prune)
      # fail confusingly deep inside `git -C ...` instead of here, with our own wording.
      git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $repo_path"

      # A symlinked path derives its default name from the CANONICALIZED target's basename
      # (repo_path is already ":A"-resolved above), not the symlink name the user typed --
      # "~/proj-link" -> "[repo proj]". The behavior is kept (the physical repo, not the
      # symlink, is what's actually being registered) but is called out in the success
      # message below when it differs and the user didn't pin the name explicitly with
      # --name.
      local name_explicit=0
      [[ -n "$name" ]] && name_explicit=1
      [[ -n "$name" ]] || name="${repo_path:t}"
      # R29: is_safe_repo_name is the authoritative check -- NOT a character-class glob like
      # "[A-Za-z0-9_.-]##". That class would wrongly ACCEPT "..", since both characters it
      # contains ('.') are in the class; only is_safe_repo_name's explicit "." / ".." / "*/*"
      # checks catch it. This is the entry point that makes a hand-edited-only unsafe name
      # (`[repo ..]`) reachable from the CLI, so it must enforce the same rule
      # registered_repos/resolve_repo already defend against at read time.
      is_safe_repo_name "$name" || usage_error "invalid repo name: $name (must not be empty, \".\", \"..\", or contain \"/\")"
      (( ${WT_REPOS[(Ie)$name]} )) && die "repo already registered: $name"

      if [[ -z "$project" ]]; then
        # project_of_path returns rc 1 (and prints nothing) when the path isn't under any
        # project's repo_root/worktree_root -- e.g. this is exactly the "[repo]" case, a
        # clone living OUTSIDE every repo_root. The "||" fallback to default_project only
        # fires because project_of_path's own exit status propagates through the
        # command-substitution assignment.
        project="$(project_of_path "$repo_path")" || project="$(default_project)"
      fi
      project_exists "$project" || die "unknown project: $project"

      config_set "repo.$name.path" "$repo_path"
      config_set "repo.$name.project" "$project"
      local note=""
      if (( ! name_explicit )) && [[ "$name" != "$typed_basename" ]]; then
        note=" (name derived from the resolved target \"$name\", not the symlink \"$typed_basename\" you typed)"
      fi
      success "registered repo $name → $repo_path (project $project)$note" ;;
    remove)
      (( $# == 1 )) || usage_error "usage: workytree repo remove <name>"
      (( ${WT_REPOS[(Ie)$1]} )) || die "repo not registered: $1"
      config_remove_section repo "$1"; success "unregistered repo $1" ;;
    *) usage_error "usage: workytree repo list|add <path> [--name n] [--project p]|remove <name>" ;;
  esac
}

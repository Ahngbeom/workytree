# cmd_init [name repo_root worktree_root]: first-time setup. Delegates ALL path/name
# validation to `cmd_project add` (lib/cmd/project.zsh) -- it already enforces the pair
# invariant, unsafe roots, relative paths, and default-project bookkeeping (R27/R30/R32);
# duplicating any of that here would just create a second copy that can drift.
#
# Bad-answer handling in the interactive wizard (design decision, see task-9 report): a
# rejected answer RE-ASKS rather than aborting the wizard. `cmd_project add` validates BOTH
# repo_root and worktree_root before writing anything (see its own comments), so calling it
# speculatively inside a command substitution to test an answer is safe -- on failure
# nothing was written, and its die()/usage_error() only unwinds the subshell the command
# substitution created, not the whole `workytree init` process. The re-ask loop reuses each
# previously-typed value as the new prompt default, so fixing one bad field costs the user
# one keystroke (Enter) for the two fields that were already right. Every prompt_input call
# still goes through prompt.zsh's own EOF handling (_prompt_read exits 130 on EOF), so
# running out of input mid-retry terminates the process rather than looping forever.
#
# R33 (fix round 1): EVERY answer -- including the alias question -- is collected BEFORE the
# call that writes anything to disk. Originally the alias question was asked once, after a
# successful `cmd_project add`; but that write is REAL (a subshell does not sandbox
# filesystem I/O -- only the command substitution's own exit/die unwinds), so a user who
# cancelled at that last question was left with a half-configured, permanently-written
# project (no alias_wt) and no way to re-run `init` ("config already exists"). Moving the
# alias question inside the retry loop, ahead of the `cmd_project add` call, means every
# cancellation point in the wizard -- `q` or EOF, at any question -- is reached before
# anything is written, the same rule `create` already follows for its own confirmation. The
# accepted tradeoff: a user now answers the alias question before the roots are validated,
# so a validation retry re-asks it too -- harmless, since a retry loses no work either way.
cmd_init() {
  # R41 (Finding 2): a directory (or any other non-regular-file occupant, or a regular
  # file this process cannot read) sitting at the config path used to slip past this check
  # entirely -- WT_CONFIG_EXISTS means "a loadable regular file is there" (unchanged, see
  # lib/config.zsh), which is FALSE for a directory, so `init` proceeded, `_config_write`
  # silently `mv`'d its temp file INTO the directory (valid mv usage, not a bug in mv), and
  # `init` reported "added project x"/"config written" and exited 0 having written nothing.
  # WT_CONFIG_LOAD_ERROR (set by config_load for exactly these "occupied but not a usable
  # config" shapes, R38/R41) is the other half of "is this path safe to write a fresh
  # config into" -- checked first so the user sees the SPECIFIC problem (not a regular
  # file / not readable) rather than the generic "config already exists", which would be
  # misleading here since no config, valid or otherwise, actually exists yet.
  #
  # R44 (fix round 5): this branch exits 3, not die()'s 1. It surfaces the SAME recorded
  # WT_CONFIG_LOAD_ERROR every other consumer exits 3 for, and `init` itself already exits 3
  # when a WRITE cannot proceed (R42's _config_die_state) -- so leaving the read side at 1
  # meant `wt init` reported two different codes for two config-state problems. The sibling
  # branch below ("config already exists") deliberately KEEPS exit 1: it is not a failure to
  # use the config, it is a refusal of an operation that does not apply because a perfectly
  # good config is already there. See the round-5 consumer re-audit in the task report.
  if [[ -n "$WT_CONFIG_LOAD_ERROR" ]]; then
    error "$WT_CONFIG_LOAD_ERROR"; exit 3
  elif (( WT_CONFIG_EXISTS )); then
    die "config already exists: $WT_CONFIG_FILE -- add more with 'workytree project add' or edit with 'workytree config edit'"
  fi
  local name rr wr alias_wt=true
  if (( $# == 3 )); then
    name="$1" rr="$2" wr="$3"
    cmd_project add "$name" "$rr" "$wr"
  elif (( $# == 0 )); then
    prompt_available || usage_error "usage (non-interactive): workytree init <name> <repo_root> <worktree_root>"
    _prompt_say "workytree setup -- a project pairs a repo_root (where your clones live) with a worktree_root."$'\n'
    # Defaults must themselves satisfy cmd_project add's invariants (R32/R30) -- $HOME/src
    # and $HOME/worktrees are absolute and are proper (not equal-to-or-ancestor-of) $HOME, so
    # both pass. The suggested project name is derived from the cwd's basename but sanitized
    # to the same charset `project add` requires ([A-Za-z0-9_-]+): an unsanitized cwd tail
    # (e.g. a mktemp-style "tmp.XXXXXXXXXX" during a real session, or any directory with a
    # space or dot in its name) would otherwise offer a default the tool immediately rejects.
    name="${${PWD:t}//[^A-Za-z0-9_-]/-}"
    [[ -n "$name" ]] || name="project"
    rr="$HOME/src"
    wr="$HOME/worktrees"
    local out rc alias_default=y
    while true; do
      prompt_input "project name" "$name"; name="$REPLY"
      prompt_input "repo_root (directory containing your repos)" "$rr"; rr="$REPLY"
      prompt_input "worktree_root (where worktrees are created)" "$wr"; wr="$REPLY"
      if prompt_confirm "install 'wt' as a short alias for workytree?" "$alias_default"; then
        alias_wt=true; alias_default=y
      else
        alias_wt=false; alias_default=n
      fi
      out="$(cmd_project add "$name" "$rr" "$wr" 2>&1)"; rc=$?
      (( rc == 0 )) && break
      # R45 (fix round 5): a re-ask is only honest when a DIFFERENT ANSWER could succeed.
      # `cmd_project add` exits 3 for exactly one class of failure -- the state of the config
      # file or the directory it lives in (require_loadable_config's recorded load error, or
      # _config_die_state's unwritable/uncreatable target) -- and no value typed at these
      # prompts can change any of that. Looping on it re-asked forever, showing the same
      # message each pass, and terminated only when the user thought to send EOF (exit 130):
      # a first-time user reads that as the tool malfunctioning. Every other non-zero code
      # (1 for a bad root value, 2 for a blank one) IS answer-fixable and still re-asks.
      if (( rc == 3 )); then
        print -u2 -r -- "$out"
        error "'workytree init' cannot fix this from inside the wizard -- resolve it outside workytree, then run 'workytree init' again"
        exit 3
      fi
      _prompt_say "$out"$'\n'"let's fix that -- re-enter the values below (press Enter to keep a value shown)."$'\n'
    done
    _prompt_say "$out"$'\n'
  else
    usage_error "usage: workytree init [<name> <repo_root> <worktree_root>]"
  fi
  config_set alias_wt "$alias_wt"
  success "config written: $WT_CONFIG_FILE"
  dim "next: 'workytree repos' to see discovered repos, 'workytree create' to start"
}

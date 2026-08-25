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
  (( WT_CONFIG_EXISTS )) && die "config already exists: $WT_CONFIG_FILE -- add more with 'workytree project add' or edit with 'workytree config edit'"
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

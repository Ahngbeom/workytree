# AI session launch decisions. This file only decides -- it never execs an agent or cd's
# anywhere. Execution happens in the shell wrapper (shell/workytree.zsh), which reads the
# runfile. bin/workytree's invariant of being a pure CLI stays intact for this feature too.

# Built-in profile. Kept for `claude` only -- baking another CLI's flags in here without
# verifying them is aging debt, and an agent with no profile still works: it just runs
# without an interview.
#
# `teammate_mode` is an undocumented flag not shown in `claude --help`. Its allowed values
# were confirmed by probing (`claude --teammate-mode __bogus__` prints "Allowed choices are
# auto, tmux, iterm2, in-process"). It could disappear without notice, so the list lives
# here, but a user can override it wholesale with one [agent claude] section.
typeset -gA WT_AI_BUILTIN
WT_AI_BUILTIN=(
  'claude.command'         'claude'
  'claude.ask'             'permission_mode,model,teammate_mode'
  'claude.permission_mode' 'plan,acceptEdits,auto,bypassPermissions,dontAsk,manual'
  'claude.model'           'opus,sonnet,fable'
  'claude.effort'          'low,medium,high,xhigh,max'
  'claude.teammate_mode'   'auto,tmux,iterm2,in-process'
)

# When ai_agent is unset, use the first PATH hit in this order.
typeset -ga WT_AI_PROBE_ORDER
WT_AI_PROBE_ORDER=(claude codex gemini cursor-agent aider)

# ai_setting <project> <key>: project value -> global value. rc 1 if neither is set.
# No repo-level tier: a [repo] section only exists for explicitly registered repos, so a
# repo discovered by scanning could never use that tier -- the rule would apply
# asymmetrically.
ai_setting() {
  local project="$1" key="$2"
  if [[ -n "$project" ]] && (( ${+WT_PCFG[$project.$key]} )); then
    print -r -- "${WT_PCFG[$project.$key]}"; return 0
  fi
  (( ${+WT_CFG[$key]} )) || return 1
  print -r -- "${WT_CFG[$key]}"
}

# ai_session_mode <project>: always prints one of off|ask|always. An unrecognized value
# warns on stderr and falls back to off -- a single typo must never make create itself
# unusable (spec §8).
ai_session_mode() {
  local v
  v="$(ai_setting "$1" ai_session)" || v=off
  [[ -z "$v" ]] && v=off
  case "$v" in
    off|ask|always) print -r -- "$v" ;;
    *) warn "ignoring invalid ai_session value: $v (expected off|ask|always)"; print -r -- off ;;
  esac
}

# ai_profile_get <agent> <key>: profile value. rc 1 if unset.
# When a user defines [agent <name>], it replaces the built-in profile wholesale -- not a
# key-by-key merge. A merge cannot express "I want to drop one entry from the built-in
# list."
ai_profile_get() {
  local name="$1" key="$2"
  if (( ${WT_AGENTS[(Ie)$name]} )); then
    (( ${+WT_ACFG[$name.$key]} )) || return 1
    print -r -- "${WT_ACFG[$name.$key]}"; return 0
  fi
  (( ${+WT_AI_BUILTIN[$name.$key]} )) || return 1
  print -r -- "${WT_AI_BUILTIN[$name.$key]}"
}

# ai_agent_command <agent>: the command string to run. The agent's own name if there is no
# `command` key.
ai_agent_command() { ai_profile_get "$1" command || print -r -- "$1"; }

# ai_have_command <name>: is there an executable file on PATH?
# `whence -p` scans PATH directly, skipping aliases/functions/builtins and finding only
# external commands. zsh's `${+commands[$1]}` lookup was measured to behave identically --
# prepending a new directory to PATH takes effect immediately, with no rehash needed (this
# is zsh-specific behavior that differs from bash's `hash -r` requirement, and this comment
# used to say the opposite). The two spellings are equivalent here, so `whence -p` is used
# because its name states the intent directly: "look this name up on PATH."
ai_have_command() { whence -p -- "$1" >/dev/null 2>&1; }

# ai_resolve_agent <project>: the agent name to use. rc 1 if none.
# An explicitly set ai_agent is returned as-is, with no PATH check -- the diagnostic for "it
# doesn't exist" belongs to the caller (ai_maybe_offer), which can give it with the context
# that the user named it explicitly.
ai_resolve_agent() {
  local project="$1" explicit cand
  if explicit="$(ai_setting "$project" ai_agent)" && [[ -n "$explicit" ]]; then
    print -r -- "$explicit"; return 0
  fi
  for cand in "${WT_AI_PROBE_ORDER[@]}"; do
    ai_have_command "$cand" && { print -r -- "$cand"; return 0; }
  done
  return 1
}

# ai_build_argv <agent> <mode>: prints the argv to run, one word per line, on stdout.
# rc 1 if the user declines in ask mode.
#
# The caller MUST wrap this in a command substitution: `out="$(ai_build_argv "$name" "$mode")"`.
# lib/prompt.zsh's cancel path calls `exit 130` directly (:21, :22, :57), and this interview
# runs *after* the worktree already exists -- if that exit reached the whole process, the
# CLI would print the path and still end with 130, and the shell wrapper's
# `(( exit_code == 0 ))` check would then skip the cd -- the worst possible outcome: the
# worktree exists but the user can't get to it. A command substitution runs in a subshell,
# so that exit stops in the subshell and the parent only sees the rc (measured directly).
# This one arrangement satisfies spec §5.2 ("cancelling still leaves the worktree and exits
# 0") without touching a single line of prompt.zsh.
#
# R16: never name a local `argv` -- zsh binds `argv` to the function's own positional
# parameters, so `argv=(...)` silently rebinds $1/$2/$@ for the rest of the call. Harmless
# here only because name/mode are captured into scalars before the rebind and nothing after
# reads a positional; renamed to out_argv so the next edit doesn't inherit the landmine.
ai_build_argv() {
  local name="$1" mode="$2" cmd ask values opt
  local -a out_argv opts
  cmd="$(ai_agent_command "$name")"
  # ${(z)} tokenizes but does NOT strip quote characters -- verified: cmd='claude --sys "be
  # brief"' with only (z) applied leaves the argument as the ten characters `"be brief"`,
  # quotes and all. ${(Q)} is the pass that removes them, turning it into the two words the
  # user meant collapsed into one argument: `be brief`. Without it, a config author who
  # quotes a multi-word value (the only way `command` documents to express one) ships the
  # quote characters straight to the agent.
  out_argv=( ${(Q)${(z)cmd}} )

  if prompt_available; then
    if [[ "$mode" == ask ]]; then
      prompt_confirm "open a $name session here?" y || return 1
    fi
    if ask="$(ai_profile_get "$name" ask)" && [[ -n "$ask" ]]; then
      opts=( ${(s:,:)ask} )
      for opt in "${opts[@]}"; do
        # spec §3.1: when ask names a key the section doesn't have, skip it rather than
        # error. It's worse for a config that partially mimics the built-in profile to make
        # the whole config unusable.
        values="$(ai_profile_get "$name" "$opt")" || continue
        [[ -n "$values" ]] || continue
        # allow_free=1 -- a value outside the list can still be typed. This is what turns a
        # stale upstream CLI flag list into a mild inconvenience instead of a silent
        # failure.
        prompt_choose "${opt//_/-}" 1 "(skip)" ${(s:,:)values}
        [[ "$REPLY" == "(skip)" ]] && continue
        out_argv+=( "--${opt//_/-}" "$REPLY" )
      done
    fi
  fi

  # -r, not just -l: plain `print -l` interprets backslash escapes in each element, and this
  # is the one line that serializes argv into the runfile. Measured: `print -l -- "opus\n--x"`
  # writes an actual newline where the two source characters `\n` were, so the wrapper's
  # ${(f)} read-back on the other end sees it as TWO elements instead of one -- a `\n` typed
  # into a config value or an interview answer injects an extra argument into the command
  # about to run in the user's shell. `-r` disables that interpretation so each line holds
  # exactly the bytes the element contains.
  print -rl -- "${out_argv[@]}"
}

# ai_maybe_offer <project> <forced:0|1>: called after create has already succeeded. If
# every gate passes, writes argv to $WT_AI_RUNFILE (bin/workytree's own copy of the
# $WORKYTREE_AI_RUNFILE the wrapper exported -- see bin/workytree's header for why the CLI
# captures it into this name and unsets the original before touching git).
#
# This function is always rc 0. Failing to launch an AI session is not a failure of create --
# the worktree was created, and that's this command's contract (spec §8). Every diagnostic
# goes out via warn (stderr), so "last stdout line = the path" still holds.
ai_maybe_offer() {
  local project="$1"
  local -i forced=$2
  local mode name cmd first out
  local -a cmd_words

  if (( forced )); then mode=always; else mode="$(ai_session_mode "$project")"; fi
  [[ "$mode" == off ]] && return 0

  if [[ -z "${WT_AI_RUNFILE:-}" ]]; then
    warn "ai session skipped: shell integration required"
    warn "source shell/workytree.zsh from your shell config and use 'wt'/'workytree'"
    return 0
  fi

  name="$(ai_resolve_agent "$project")" || return 0
  cmd="$(ai_agent_command "$name")"
  # NOT `${${(z)cmd}[1]}`: when (z)-splitting yields exactly one word, that nested-subscript
  # form silently indexes the ORIGINAL scalar by character instead of the split array by
  # element (verified: cmd="nosuchagent" -> "n", not "nosuchagent"; cmd="claude --bare" ->
  # "claude" is fine because two words happen to dodge the collapse). Single-word commands are
  # the common case, so this would misdetect nearly every real agent. Building the array first
  # and indexing that avoids the collapse entirely. ${(Q)} strips quote characters the same way
  # ai_build_argv's tokenizing does (see its comment) -- otherwise a quoted first word would
  # fail the PATH lookup below on the literal quote characters.
  cmd_words=( ${(Q)${(z)cmd}} )
  # `:-`, not a bare subscript: bin/workytree runs under `set -u`, and an `[agent x]` section
  # with an empty or whitespace-only `command =` makes ${(z)cmd} split to ZERO words, so
  # `${cmd_words[1]}` alone is a fatal "parameter not set" (verified: `local -a a=(); print
  # "${a[1]}"` under `set -u` aborts the function with rc 1, printing nothing). That took down
  # the whole CLI after the worktree path had already been printed -- the shell wrapper's `((
  # exit_code == 0 ))` guard then skipped the cd, leaving the user outside a worktree that now
  # exists. `:-` supplies "" instead of aborting, and an empty $first fails the PATH lookup
  # below exactly like a nonexistent command name would, landing on the same warn-and-return-0
  # path rather than a new one.
  first="${cmd_words[1]:-}"
  if [[ -z "$first" ]] || ! ai_have_command "$first"; then
    # Auto-detection only ever picks something already on PATH, so reaching here means the
    # user named this agent explicitly, or gave an empty `command`. Either way it must not
    # pass by silently.
    warn "ai session skipped: '$first' not found on PATH"
    return 0
  fi

  out="$(ai_build_argv "$name" "$mode")" || return 0
  [[ -n "$out" ]] || return 0
  print -r -- "$out" > "$WT_AI_RUNFILE" \
    || warn "ai session skipped: could not write $WT_AI_RUNFILE"
  return 0
}

# ai_configured_anywhere: rc 0 if this config turns AI sessions on ANYWHERE -- the global
# ai_session key, or any [project]'s own. The shell wrapper asks this once at startup to
# decide whether to create a runfile at all (shell/workytree.zsh). A user who never enabled
# sessions then has no runfile in $TMPDIR for anything else to write into.
#
# It deliberately does NOT resolve a repo or a project. That would cost a repo_root scan on
# every `wt create`, and the answer only has to be a SUPERSET: one project enabling sessions
# arms the channel for every project, which errs toward the feature working rather than
# toward it silently not working.
#
# Silent by construction. ai_session_mode warns about an unusable value, which is right for a
# command the user typed and wrong for something that runs on every shell startup -- so this
# checks the two valid opt-in values directly rather than calling it. An unusable value is
# simply not an opt-in, which is where ai_session_mode lands for it anyway.
ai_configured_anywhere() {
  local p
  [[ "${WT_CFG[ai_session]:-}" == (ask|always) ]] && return 0
  for p in "${WT_PROJECTS[@]}"; do
    [[ "${WT_PCFG[$p.ai_session]:-}" == (ask|always) ]] && return 0
  done
  return 1
}

# cmd___ai-configured: the hidden query behind ai_configured_anywhere. rc 0 = arm the runfile
# channel, rc 1 = do not. Prints nothing on either stream, ever.
#
# Fail closed, and it costs no special case to do so: config_load reacts to a parse failure by
# resetting every array to empty (lib/config.zsh, R38), so a broken -- or entirely absent --
# config reaches this function looking exactly like one with nothing configured, and falls out
# at rc 1. Arming an execution channel off a config we could not parse would be the worst
# available reading of ambiguous input.
#
# Like cmd___complete, this must never fail loudly: it runs on every shell startup, where a
# stray diagnostic lands in the user's terminal before they have typed anything.
cmd___ai-configured() { ai_configured_anywhere }

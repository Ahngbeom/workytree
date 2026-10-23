#!/usr/bin/env zsh
# The fzf renderer, with fzf stubbed as a shell function (bin/workytree's PATH would put a real
# install ahead of any fake executable). The stub records its arguments and answers with a
# canned selection.
source "${0:A:h}/helpers.zsh"
for f in ui config resolve prompt worktree forge status branches; do source "$WT_TEST_ROOT/lib/$f.zsh"; done
for f in prune remove status status_branches; do source "$WT_TEST_ROOT/lib/cmd/$f.zsh"; done

fixture() {
  make_repo "$HOME/src/app"
  typeset -ga WT_PROJECTS=(me)
  typeset -gA WT_PCFG=(me.repo_root "$HOME/src" me.worktree_root "$HOME/wts") WT_CFG=() WT_RCFG=()
  git -C "$HOME/src/app" worktree add -q -b fix/A "$HOME/wts/app/fix/A"
  git -C "$HOME/src/app" branch lonely
  mkdir -p "$HOME/wts/app/fix/ORPH"
  WORKYTREE_HOME="$HOME/with space/workytree"
  WT_PROJECT_OPT='' WT_COLOR=0
  _status_parse_opts --offline
  RECORDS="$(status_collect_repo me app "$HOME/src/app" 30)"
  : > "$HOME/notes"
}

# fzf_selecting <type> [key...]: stub fzf. Call <n> saves its argv (one per line) to fzf.args
# and fzf.args.<n>, its stdin to fzf.in and fzf.in.<n>, then answers with key <n>: ctrl-b,
# '' (enter) or esc; past the given keys, esc for <type> "none", else enter. esc prints
# nothing (rc 130). Otherwise an --expect call prints the key first, then the first input line
# whose record type is <type> (else the first line); an empty list prints only the key, rc 1,
# as fzf does.
fzf_selecting() {
  FZF_PICK="$1"
  FZF_KEYS=("${@[2,-1]}")
  fzf() {
    [[ "$1" == --version ]] && { print -r -- "0.55.0 (stub)"; return; }
    local -i n=0
    [[ -r "$HOME/fzf.n" ]] && n=$(<"$HOME/fzf.n")
    print -r -- $(( ++n )) > "$HOME/fzf.n"
    print -rl -- "$@" > "$HOME/fzf.args"
    cp "$HOME/fzf.args" "$HOME/fzf.args.$n"
    cat > "$HOME/fzf.in"
    cp "$HOME/fzf.in" "$HOME/fzf.in.$n"
    local key='' l
    if (( n <= ${#FZF_KEYS} )); then key="${FZF_KEYS[n]}"
    elif [[ "$FZF_PICK" == none ]]; then key=esc; fi
    [[ "$key" == esc ]] && return 130
    (( ${@[(I)--expect=*]} )) && print -r -- "$key"
    local -a lines; lines=("${(@f)$(<"$HOME/fzf.in")}"); lines=("${(@)lines:#}")
    (( ${#lines} )) || return 1
    for l in "${lines[@]}"; do
      [[ "$l" == "$FZF_PICK"$'\t'* ]] && { print -r -- "$l"; return 0; }
    done
    print -r -- "${lines[1]}"
  }
}

# count_collections: _status_records appends a line to $HOME/collects per call (it runs in
# $(...), so a counter variable would not survive). uncount_collections restores it.
count_collections() {
  functions[_orig_status_records]="$functions[_status_records]"
  _status_records() { print >> "$HOME/collects"; _orig_status_records "$@"; }
}
uncount_collections() {
  functions[_status_records]="$functions[_orig_status_records]"
  unfunction _orig_status_records
}

test_enter_on_worktree_prints_its_path_last() {
  fixture; fzf_selecting worktree
  assert_eq "$(_status_run_fzf "$RECORDS" "$HOME/notes")" "$HOME/wts/app/fix/A"
}

test_enter_on_orphan_row_prints_nothing() {
  fixture; fzf_selecting orphan
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
  assert_contains "$args" "--expect=ctrl-b"
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
  local args; args="$(<"$HOME/fzf.args")"
  assert_contains "$args" "ctrl-/: layout · ctrl-b: branches"$'\n'
  assert_contains "$args" "note: app: github lookup failed (exit 4)"
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
  local orphan_line; orphan_line="$(print -r -- "$RECORDS" | grep '^orphan')"
  local err; err="$(cmd___status-action remove "$orphan_line" 2>&1 </dev/null)"
  assert_contains "$err" "only worktrees under worktree_root can be removed from here"
  assert_contains "$err" "wt prune app"
}

# ctrl-d runs remove in a child of status; the parent prints the main checkout last and the
# wrapper moves the shell there.
test_action_remove_from_inside_leaves_the_cwd_to_the_parent() {
  fixture
  local rec out err
  rec="$(print -r -- "$RECORDS" | grep '^worktree')"
  out="$(_status_pause() { :; }; WT_CONFIG_EXISTS=1; cd "$HOME/wts/app/fix/A" && cmd___status-action remove "$rec" </dev/null 2>"$HOME/err")"
  err="$(<"$HOME/err")"
  assert_contains "$err" "removed: $HOME/wts/app/fix/A"
  assert_eq "${err#*directory was removed}" "$err" "no stranded-shell warning"
  assert_eq "$out" "" "no destination line"
}

# fzf searches only the displayed field (--with-nth=27), so ctrl-s's "stale" query and typed
# filters like "gone" need the tags on screen.
test_display_field_carries_the_searchable_tags() {
  fixture; fzf_selecting none
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  local line; line="$(grep -F "fix/A" "$HOME/fzf.in" | grep $'^worktree\t')"
  local -a f; f=("${(@ps:\t:)line}")
  assert_contains "${f[27]}" "safe merged"
}

# fzf picks the layout itself and re-picks it on every resize; a width measured once at
# start-up left split panes (narrower than the old 120-column cut-off) stuck top/bottom.
test_layout_follows_the_terminal_width_and_toggles() {
  fixture; fzf_selecting none
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  local args; args="$(<"$HOME/fzf.args")"
  assert_contains "$args" "--preview-window=right,50%,<100(down,50%)"
  assert_contains "$args" "ctrl-/:change-preview-window(down,50%|right,50%)"
  assert_contains "$args" "ctrl-/: layout · ctrl-b: branches"
}


# Moving the cursor must not count as activity: the preview's `git status` would otherwise
# refresh the index, whose mtime is the ACTIVE age.
test_preview_does_not_rewrite_the_index() {
  fixture
  local gd before after line
  gd="$(git -C "$HOME/wts/app/fix/A" rev-parse --absolute-git-dir)"
  touch -t 202401010000 "$gd/index"
  touch "$HOME/wts/app/fix/A/README.md"
  before="$(zstat +mtime "$gd/index")"
  line="$(print -r -- "$RECORDS" | grep $'^worktree\t')"
  cmd___status-preview "$line" >/dev/null
  after="$(zstat +mtime "$gd/index")"
  assert_eq "$after" "$before"
}

# fzf runs every binding through $SHELL -c; the bindings are POSIX sh, so a fish or nushell
# login shell must not be the one that parses them.
test_bindings_run_under_posix_sh() {
  fixture
  fzf() { [[ "$1" == --version ]] && { print -r -- "0.55.0 (stub)"; return; }; print -r -- "$SHELL" > "$HOME/fzf.shell"; cat >/dev/null; return 130; }
  SHELL=/usr/local/bin/fish _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  assert_eq "$(<"$HOME/fzf.shell")" /bin/sh
}

branch_records() { status_collect_branches me app "$HOME/src/app" 30; }

test_ctrl_b_switches_to_branch_mode_and_back() {
  fixture; fzf_selecting none ctrl-b ctrl-b esc
  local out; out="$(_status_run_fzf "$RECORDS" "$HOME/notes")"
  assert_eq "$out" ""
  assert_eq "$(<"$HOME/fzf.n")" 3 "fzf runs once per mode entry"
  assert_contains "$(<"$HOME/fzf.args.1")" "--with-nth=27"
  local a2; a2="$(<"$HOME/fzf.args.2")"
  assert_contains "$a2" "--multi"
  assert_contains "$a2" "--with-nth=18"
  assert_contains "$a2" "--expect=ctrl-b"
  assert_contains "$a2" "--bind=alt-d:"
  assert_contains "$a2" "tab: mark · alt-d: delete marked · ctrl-r: refresh with fetch · ctrl-s: safe only · ctrl-b: worktrees"
  local -a f; f=("${(@ps:\t:)$(grep $'\tlonely\t' "$HOME/fzf.in.2")}")
  assert_eq "${#f}" 18 "branch feed is record + display"
  assert_contains "$(<"$HOME/fzf.args.3")" "--with-nth=27"
  assert_contains "$(<"$HOME/fzf.in.3")" "$HOME/wts/app/fix/A"
}

# An empty branch list must not end the session: fzf prints the --expect key and exits 1.
test_ctrl_b_switches_back_from_an_empty_branch_list() {
  fixture; git -C "$HOME/src/app" branch -qD lonely
  fzf_selecting none ctrl-b ctrl-b esc
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  assert_eq "$(<"$HOME/fzf.n")" 3
  assert_contains "$(<"$HOME/fzf.args.3")" "--with-nth=27"
}

test_switching_back_does_not_recollect() {
  fixture; fzf_selecting none ctrl-b ctrl-b ctrl-b esc
  count_collections
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  uncount_collections
  assert_eq "$(grep -c '' "$HOME/collects")" 1 "only the branch list's first entry collects"
  assert_eq "$(<"$HOME/fzf.n")" 4
}

# A reload (ctrl-d, alt-d, ctrl-r) changed what the other mode's cached rows describe.
test_a_reload_makes_the_next_switch_recollect() {
  fixture; fzf_selecting none ctrl-b ctrl-b esc
  functions[_stub_fzf]="$functions[fzf]"
  fzf() {
    [[ "$1" != --version && ! -e "$HOME/fzf.n" ]] && : > "$WT_STATUS_RELOADED"
    _stub_fzf "$@"
  }
  count_collections
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  uncount_collections; unfunction _stub_fzf
  assert_eq "$(grep -c '' "$HOME/collects")" 2 "branch entry and the worktree list again"
}

test_rows_mark_a_reload() {
  fixture
  ( WT_CONFIG_EXISTS=1 WT_STATUS_RELOADED="$HOME/reloaded"; cmd___status-rows --offline >/dev/null 2>&1 )
  assert_eq "$([[ -e "$HOME/reloaded" ]] && print yes)" yes
}

test_mode_switch_never_fetches() {
  fixture; fzf_selecting none ctrl-b esc
  functions[_orig_fetch]="$functions[wt_fetch_origin]"
  wt_fetch_origin() { print -r -- "$1" >> "$HOME/fetched"; }
  ST_FETCH=1
  _status_run_fzf "$RECORDS" "$HOME/notes" >/dev/null
  functions[wt_fetch_origin]="$functions[_orig_fetch]"; unfunction _orig_fetch
  assert_eq "$([[ -e "$HOME/fetched" ]] && print fetched)" ""
  assert_contains "$(<"$HOME/fzf.args.2")" "--with-nth=18" "branch mode was entered"
}

test_branch_mode_enter_is_ignored() {
  fixture; fzf_selecting branch ctrl-b ''
  local out; out="$(_status_run_fzf "$RECORDS" "$HOME/notes")"
  assert_contains "$(<"$HOME/fzf.args.2")" "--bind=enter:ignore"
  assert_eq "$out" ""
}

test_branches_flag_starts_in_branch_mode() {
  fixture; fzf_selecting none
  ST_BRANCHES=1
  _status_run_fzf "$(branch_records)" "$HOME/notes" >/dev/null
  assert_contains "$(<"$HOME/fzf.args.1")" "--with-nth=18"
  assert_contains "$(<"$HOME/fzf.in.1")" $'\tlonely\t'
}

test_branch_bindings_quote_a_bin_path_with_spaces() {
  fixture; fzf_selecting none
  ST_BRANCHES=1
  _status_run_fzf "$(branch_records)" "$HOME/notes" >/dev/null
  local args; args="$(<"$HOME/fzf.args")"
  local qbin="${(q)WORKYTREE_HOME}/bin/workytree"
  assert_contains "$args" "alt-d:execute($qbin __status-action delete-branches {+f} --no-color --offline)+deselect-all+reload($qbin __status-rows --no-color --offline --branches)"
  assert_contains "$args" "ctrl-r:reload($qbin __status-rows --no-color --offline --branches)"
  assert_contains "$args" "ctrl-s:transform-query(if [ {q} = 'safe\$' ]; then echo; else echo 'safe\$'; fi)"
  assert_contains "$args" "--preview=$qbin __status-branch-preview {}"
}

test_branch_refresh_fetches_unless_offline() {
  fixture; fzf_selecting none
  _status_parse_opts --branches
  _status_run_fzf "$(branch_records)" "$HOME/notes" >/dev/null
  assert_contains "$(<"$HOME/fzf.args")" "ctrl-r:reload(${(q)WORKYTREE_HOME}/bin/workytree __status-rows --no-color --branches --fetch)"
}

# fzf --ansi strips the color codes before matching, so ctrl-s's "safe$" sees the class word
# at the end of the line even though a reset code follows it.
test_safe_query_anchors_on_the_class_word_with_color_on() {
  fixture; fzf_selecting none
  WT_COLOR=1; ui_init force
  ST_BRANCHES=1
  _status_run_fzf "$(branch_records)" "$HOME/notes" >/dev/null
  WT_COLOR=0; ui_init
  assert_contains "$(<"$HOME/fzf.args")" "--ansi"
  local line plain
  line="$(grep $'\tlonely\t' "$HOME/fzf.in")"
  assert_contains "$line" $'\033[' "display is colored"
  plain="$(print -r -- "${${(@ps:\t:)line}[18]}" | sed $'s/\033\\[[0-9;]*m//g')"
  assert_eq "${plain##* }" safe
}

test_branch_header_shows_the_fetch_age() {
  fixture; fzf_selecting none
  print x > "$HOME/src/app/.git/FETCH_HEAD"; touch -t 202401010000 "$HOME/src/app/.git/FETCH_HEAD"
  ST_BRANCHES=1
  _status_run_fzf "$(branch_records)" "$HOME/notes" >/dev/null
  assert_contains "$(<"$HOME/fzf.args")" "refs fetched "
  assert_contains "$(<"$HOME/fzf.args")" " ago (oldest) in 1 repo — ctrl-r before deleting"
}

test_fetch_age_counts_the_main_checkout_and_ignores_empty_files() {
  fixture
  local fh="$HOME/src/app/.git/FETCH_HEAD" wfh
  print x > "$fh"; touch -t 202401010000 "$fh"
  _branches_fetch_age "$HOME/src/app"
  assert_eq "${reply[*]}" "1 0"
  assert_eq "$(( REPLY > 86400 ))" 1 "age of the 2024 fetch: $REPLY"
  # The linked worktree's FETCH_HEAD is newer: the repo counts as fetched then.
  wfh="$(git -C "$HOME/wts/app/fix/A" rev-parse --path-format=absolute --git-path FETCH_HEAD)"
  print x > "$wfh"
  _branches_fetch_age "$HOME/src/app"
  assert_eq "$(( REPLY < 3600 ))" 1 "newest FETCH_HEAD wins: $REPLY"
  : > "$fh"; : > "$wfh"
  _branches_fetch_age "$HOME/src/app"
  assert_eq "$REPLY" -
  assert_eq "${reply[*]}" "1 1"
}

test_fetch_age_is_read_on_old_git() {
  fixture
  local fh="$HOME/src/app/.git/FETCH_HEAD" wfh
  print x > "$fh"; touch -t 202401010000 "$fh"
  git() {
    if [[ "$1" == -C && "$3" == rev-parse && " ${@[4,-1]} " == *" --path-format=absolute "* ]]; then
      print -r -- --path-format=absolute
      command git -C "$2" rev-parse "${(@)${@[4,-1]}:#--path-format=absolute}"; return
    fi
    command git "$@"
  }
  _branches_fetch_age "$HOME/src/app"
  assert_eq "${reply[*]}" "1 0" main-checkout
  assert_eq "$([[ $REPLY == <-> ]] && (( REPLY > 86400 )) && print old)" old "age of the 2024 fetch: $REPLY"
  wfh="$(command git -C "$HOME/wts/app/fix/A" rev-parse --git-path FETCH_HEAD)"
  [[ "$wfh" == /* ]] || wfh="$HOME/wts/app/fix/A/$wfh"
  print x > "$wfh"
  _branches_fetch_age "$HOME/src/app"
  assert_eq "$([[ $REPLY == <-> ]] && (( REPLY < 3600 )) && print new)" new "linked worktree: $REPLY"
  unfunction git
}

test_branch_preview_does_not_touch_the_network() {
  fixture
  git clone -q --bare "$HOME/src/app" "$HOME/origin.git"
  git -C "$HOME/src/app" remote add origin "$HOME/origin.git"
  git -C "$HOME/src/app" fetch -q origin
  git -C "$HOME/src/app" config user.email t@t
  local rec; rec="$(branch_records | grep $'\tlonely\t')"
  local -a f; f=("${(@ps:\t:)rec}")
  git() {
    [[ " $* " == *" "(fetch|ls-remote|push|pull)" "* ]] && print -r -- "$*" >> "$HOME/net"
    command git "$@"
  }
  local out; out="$(cmd___status-branch-preview "$rec"$'\tdisplay')"
  unfunction git
  assert_eq "$([[ -e "$HOME/net" ]] && cat "$HOME/net")" ""
  assert_contains "$out" "${f[17]}"
  assert_contains "$out" "t <t@t>"
  assert_contains "$out" "${f[6]}"
  assert_contains "$out" "${f[7]}"
  assert_contains "$out" "init"
}

# run_in_background_pgrp <zsh code>: run <code> the way fzf runs reload and preview commands --
# in a process group that is NOT the foreground group of its controlling terminal -- and print
# "exited <rc>" or "stopped" (SIGTTOU/SIGTTIN). Needs python3 for the pseudo-terminal.
run_in_background_pgrp() {
  python3 - "$1" <<'PY'
import os, pty, sys, time, signal
code = sys.argv[1]
pid, fd = pty.fork()                       # child: session leader with the pty as its terminal
if pid == 0:
    gc = os.fork()
    if gc == 0:
        os.setpgid(0, 0)                   # own group, never made the terminal's foreground
        os.execv('/bin/zsh', ['zsh', '-c', code])
    end = time.time() + 10
    while time.time() < end:
        done, status = os.waitpid(gc, os.WUNTRACED | os.WNOHANG)
        if done:
            if os.WIFSTOPPED(status):
                os.kill(gc, signal.SIGKILL); print('stopped', flush=True); os._exit(0)
            print('exited', os.WEXITSTATUS(status), flush=True); os._exit(0)
        time.sleep(0.05)
    os.kill(gc, signal.SIGKILL); print('timeout', flush=True); os._exit(0)
out = b''
while True:
    try: chunk = os.read(fd, 1024)
    except OSError: break
    if not chunk: break
    out += chunk
os.waitpid(pid, 0)
print(out.decode().strip().splitlines()[-1])
PY
}

# fzf runs ctrl-d's reload and the details pane in a background process group; zsh's
# `read -d` touches the terminal and gets the whole reload stopped, so the list never refreshed.
test_rows_and_orphan_preview_finish_outside_the_foreground_group() {
  (( $+commands[python3] )) || { print -u2 "  (skipped: python3 not installed)"; return 0; }
  fixture
  mkdir -p "$HOME/wts/app/fix/ORPH/.idea"
  local libs="setopt extendedglob; for f in $WT_TEST_ROOT/lib/*.zsh $WT_TEST_ROOT/lib/cmd/*.zsh; do source \$f; done"
  local pcfg="typeset -ga WT_PROJECTS=(me); typeset -gA WT_PCFG=(me.repo_root $HOME/src me.worktree_root $HOME/wts) WT_CFG=() WT_RCFG=()"
  assert_eq "$(run_in_background_pgrp "$libs; $pcfg; status_collect_repo me app $HOME/src/app 30 >/dev/null")" "exited 0" collect
  assert_eq "$(run_in_background_pgrp "$libs; dir_is_cruft_only $HOME/wts/app/fix/ORPH")" "exited 0" cruft-check
}

run_tests

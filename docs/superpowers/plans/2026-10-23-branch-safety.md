# Branch Safety (T7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the T7 correctness track, which D2 makes top priority and independent of Phase 1:
- `remove` stops losing commits. It uses one merged verdict, shared with `status`. `-b`/`-B` act on the ticket branch. Every deletion prints a restore command.
- `create` stops handing user tokens to git as options. It validates names and the base, and it resolves where the branch comes from before it asks `Create?`.
- `repo add --project` works.
- Key-driven prompts never act on keys typed ahead or on half-read escape sequences.

**Architecture:**
- `lib/status.zsh` gains `status_merged_rule`, the single merged rule, and `branch_verdict`, which returns `merged`, `pushed` or `unmerged` for one branch. `status_collect_repo` and `cmd_remove` both go through the rule.
- `cmd_remove` reads the ticket branch through `wt_branch_name`, which moves to `lib/resolve.zsh`, instead of whatever is checked out. It decides `-b` from the verdict and reports the old sha.
- `cmd_create` parses its flags strictly. It checks the names and the base and resolves the branch source (`reuse`, `local`, `remote` or `new`) before the summary. `create_do` only carries out that decision.
- `cmd_repo add` reads `WT_PROJECT_OPT`.
- `_prompt_raw_on` drains pending input, and `_prompt_key` reads whole CSI/SS3 sequences, waiting up to `KEYTIMEOUT`.
- `tests/helpers.zsh` gains a zpty session helper, shared with Phase 1.

**Tech Stack:** zsh 5.9, with zsh/zpty in tests only. git 2.50, though nothing here needs more than `check-ref-format --branch`, `worktree add --track -b`, `merge-base --is-ancestor` and `for-each-ref %(upstream)`; there is no `--end-of-options`. `gh`/`glab` are optional and only feed the PR part of the verdict.

**Spec:** `docs/superpowers/specs/2026-10-23-noninteractive-ux-design.md`. §3.14 defines merged, pushed, the ticket-branch rule and the recovery invariant; §7.2 holds each unit's acceptance. There is no separate T7 spec. Finding ids are the review's (`<lens>:<id>`).

**Branch:** work on `fix/t7-correctness`, from `main` at 48c022b, with one commit per task. Deliver it as the spec's five PRs (see Delivery), or as one PR from `fix/t7-correctness` if the user asks for one. It is independent of `fix/non-interactive-shell` (Phase 1).

Every code block in this plan was run in a prototype, a clone of 48c022b. Each `diff` block is `git diff` output between two of the prototype's task snapshots, with paths relative to the repo root. Save a block to a file and apply it with `git apply`, or make the same edit by hand. Apply them in task order. The expected test counts come from replaying the blocks on a clean checkout. Each "Step 2" run used the task's tests with the previous task's code.

## Delivery

D2 asks for the track to have its own branch and PR. The spec (§7.1, decision record §9) delivers it as five PRs, one per unit below; they match roadmap ids T7-1 to T7-5. If the user wants a single PR, the same commits go out from `fix/t7-correctness` (spec §7.1). Either way, run the tasks in order on `fix/t7-correctness`. For five PRs, cut each PR branch from `main` and cherry-pick that unit's commits; T7-3's branch starts from T7-2's. The prototype applied each unit alone on `main` (T7-3 together with T7-2) and ran the full suite: T7-1 (Tasks 1–3) 1051 passed, 0 failed; T7-2 (Tasks 4–5) 1041 passed, 0 failed; T7-2 + T7-3 (Tasks 4–6) 1063 passed, 0 failed; T7-4 (Task 7) 1008 passed, 0 failed; T7-5 (Tasks 8–9) 1012 passed, 0 failed.

| Unit (roadmap id) | Tasks | Branch if split | Needs | Findings |
|---|---|---|---|---|
| remove safety (T7-1) | 1–3 | `fix/remove-branch-safety` | — | `journeys:remove-merged-verdict`, `critic:branch-identity-drift` (remove half), `critic:branch-delete-no-recovery-sha`, `output:remove-branch-hint-deadend` |
| create argument safety (T7-2) | 4–5 | `fix/create-arg-safety` | — | `automation:create-unknown-flags-passed-to-git`, `journeys:create-accepts-dash-args`, `output:create-no-arg-validation`, `journeys:create-late-validation` |
| create branch resolution (T7-3) | 6 | `fix/create-branch-resolution` | T7-2 | `journeys:create-ignores-remote-branch`, `journeys:create-existing-branch-summary`, `critic:manual-delete-recovery-dead-end`, `output:create-stale-prune-hint`, `journeys:orphan-target-stale-hint`, `critic:branch-identity-drift` (create half) |
| repo add `--project` (T7-4) | 7 | `fix/repo-add-project` | — | `critic:repo-add-project-flag-ignored`, `automation:repo-add-missing-value-raw-error` |
| prompt input safety (T7-5) | 8–9 | `fix/prompt-input-safety` | — | `prompts:typeahead-leak-autoconfirm`, `prompts:modifier-csi-digit-select`, `prompts:split-escape-timeout`, `prompts:prompt-tests-blind-spots` |

If the track is split, land T7-1 first because it causes the most harm, and before Phase 1 (spec §13.2). T7-3 goes after T7-2, and the rest can land in any order. Applied alone, Task 9's `tests/remove_interactive.test.zsh` hunk does not fit, because its context holds Task 3's test; append the test before `run_tests` instead. Every other hunk applies through `git cherry-pick` (3-way) on `main`.

## Global Constraints

- zsh only. Every touched file must pass `zsh -n`, which the CI lint job (`.github/workflows/ci.yml`) runs on `bin/workytree lib/*.zsh lib/cmd/*.zsh shell/workytree.zsh shell/completions/_workytree tests/*.zsh`. No new required dependency: zsh/zpty ships with zsh and is used in tests only.
- Never name a local `path`, because it is tied to `$PATH`.
- Exit codes keep their meanings (0/1/2/3/130). This plan adds:
  - 2 for `create` names that are not well formed.
  - 1 for a missing base, a branch already checked out elsewhere, a stale registration, or a foreign directory at the target.
  - 1 for `remove -b`/`-B`/`-r` when another branch is checked out.
  - A failed branch step still ends 0 with a ✗ row (README:195).
- Invariant: no commit loses its last local or remote ref unless the user gave `-B` or confirmed a force-delete question. A PR merged at the branch's exact tip counts as merged, because the forge keeps the PR head ref; see Review Focus 3.
- "Could not determine" never means merged. Without forge data the verdict is ancestry only. If a fetch fails, the old refs stay and the verdict is judged from them.
- Tests assert on workytree's own wording, never on text git could also print (R23).
- Tests use `tests/*.test.zsh` with `helpers.zsh`.
  - External CLIs are stubbed as shell functions after sourcing `lib/`. `bin/workytree` puts `/opt/homebrew/bin` first on `PATH`, so a fake `gh` on `PATH` cannot shadow a real one, and the PR cases are lib-level tests.
  - Terminal tests use the zpty helper block from the Phase 1 plan (its Task 1, Step 3: `pty_start`, `pty_wait`, `pty_send`, `pty_finish`, `pty_run`), copied byte for byte to the same place in `helpers.zsh`; see Review Focus 8. `prompt.test.zsh` wraps it in `pty_script`, which runs `zsh -f <file>` with `PATH=/usr/bin:/bin` so fzf is out of the way.
- No Phase 1 code paths: this plan adds no `WT_SHELL` and no `prompt_blocker`, and `prompt_available` is unchanged.
- Comments follow `~/.claude/CLAUDE.md`: only what quietly breaks the next edit. Rationale goes in the commit messages below. The added comment lines of every task were swept.
- Commit messages below are shown without trailers. End each one with the attribution lines the executing session requires.

## Review Focus

1. **`-b` uses the verdict, not `git branch -d`** (Task 1). `git branch -d` compares with the upstream, or with the main checkout's HEAD when the upstream is gone, and both can be stale. It also accepts a branch whose only other copy `-r` is about to delete. Now `-b` deletes with `-D` when the verdict is merged. When `-r` is also given, a branch that is not merged is kept with a ✗ row. Pinned by `test_branch_flag_deletes_a_branch_merged_into_origin_without_force` and `test_branch_and_remote_flags_keep_a_branch_not_merged_into_base`.
2. **`status` changes slightly** (Task 1). Its `merged` tag and JSON field now also count a PR merged at the branch's tip, which README:169 already promised. The flag column is unchanged. Pinned by `test_remove_and_status_share_the_merged_verdict`.
3. **A PR merged at the tip is deletable with plain `-b`.** Its commits stay reachable from the forge's PR ref (`refs/pull/N/head`, `refs/merge-requests/N/head`), not from `origin/main`. If the strict "only ancestry counts for `-b`" reading is wanted instead, change the `verified=1` line to require `-z "$WT_VERDICT_PR"`.
4. **The mismatch refusal runs before anything changes** (Task 2): before the dirt probe, the fetch and every question. Plain `remove` with no branch flags still works. The refusal also covers `-r`.
5. **zsh history modifiers in `$var:`** (Task 3). `"$REPLY:refs/heads/x"` applies the `:r` modifier, so the push hint writes `${REPLY}:`. Pinned by `test_remote_delete_prints_a_restore_command`, which runs the printed command.
6. **`create`'s order** (Tasks 4–6):
   1. flags
   2. config
   3. names
   4. target classification
   5. fetch
   6. branch source
   7. base
   8. checked-out check
   9. summary and `Create?`
   10. `create_do`

   Nothing touches the disk before step 10. If git fails, `create_do` removes the parent directories it made.
7. **The drain needs a real tty** (Task 9). It runs inside `_prompt_raw_on` after the `-t` check, so file-fed tests (`WORKYTREE_PROMPT_INPUT`) keep their scripted keys. All 31 existing prompt assertions still pass.
8. **One pty helper, shared with Phase 1** (Task 8). The zpty block in `helpers.zsh` is the Phase 1 plan's, byte for byte, inserted at the same place (before `wt() {`). Git then merges the two PRs' copies as one identical change, and only the `setup_env` unset line conflicts. Two different copies would merge with no conflict at all, and the later `pty_start`/`pty_send` would silently replace the earlier ones. Appending an earlier draft of this plan's helper to Phase 1's prototype turned its `shell.test.zsh` from all passing into 43 failed. If either plan changes the block, change both. The block's `_pty_drain` comment covers the other trap: `zpty -d … 2>/dev/null` leaves the test shell's stderr on `/dev/null` (zsh 5.9), which hides every later FAIL line.
9. **`remove` may now ask the forge** (Task 1). `branch_verdict` calls `forge_pr_rows` only when the tip is not in the base and a branch decision is needed: interactive, or a non-forced `-b`. That is one `gh`/`glab` list call, bounded by `WT_FORGE_TIMEOUT` (15 s). For an origin host other than github.com or gitlab.com, `forge_kind` first runs `gh auth status` and then `glab auth status`, each with the same bound, so the worst case is about 45 s. If that is too slow for interactive use, an `--offline` switch belongs in P2, which adds `--offline` to `create` and `remove`.

## Plan-level decisions (where the roadmap's acceptance was adjusted)

| Roadmap said | Plan does | Why |
|---|---|---|
| 'my ticket', '..', a kind containing '/' exit 1 | exit 2 | Matches `project add "bad name"` and `repo add --name ..`, which already exit 2, and the exit-code contract in the roadmap and spec §6.2 ("ill-formed name → 2"). A missing base stays 1. |
| Interactively, the same question is asked again | Re-asks values that were typed at a prompt. Values given as arguments fail. | Re-asking an argument would need a new "edit argument" flow. Prompted values are the case the review reproduced. |
| Non-interactive `-b`/`-B` mismatch exits 1 | `-r` too | `-r` targets the ticket branch's remote, which is just as ambiguous. Stopping before any change costs nothing. |
| Labels and defaults only | Interactive "pushed" plus a yes to the remote question asks one more question ("lose its commits?", default No) | The interactive version of the `-b -r` rule. Without it the original commit-loss path stays open interactively. |
| `stty -g` identical before and after | Compares `icanon`/`echo`/`isig` from `stty -a` | macOS adds PENDIN to `stty -g` whenever canonical mode comes back, even with no typeahead. |
| `(not merged)` | `(not merged into origin/main)`, plus `; its upstream was deleted` when gone | Names the base. "Gone" is the usual sign of a squash merge that the forge could not confirm. |
| — | Non-forced `-b` now fetches origin first | The verdict is "after the fetch". `-B` without `-r` still never touches the network. |
| zpty typeahead `1⏎2⏎` through `wt remove` reaching the destination question | Covers the branch question and `Proceed?` | Without the wrapper (`WT_CAN_CD`) there is no destination question. That path belongs to Phase 1. The widget-level test covers a menu followed by a confirm. |
| A fake `gh` on the sandbox PATH | A lib-level `forge_pr_rows` stub | `bin/workytree` prepends `/opt/homebrew/bin`, where the real `gh` lives. |
| A zpty helper in `helpers.zsh`, shared with P1 | Phase 1's helper block, byte for byte, plus `pty_script` in `prompt.test.zsh` | Two different helpers under the same names merge without a conflict, and the later definitions win (Review Focus 8). |

## File Map

| File | Task | Responsibility |
|---|---|---|
| `lib/status.zsh` | 1 | `status_merged_rule`, `branch_verdict`, and the status merged field through the rule |
| `lib/cmd/remove.zsh` | 1, 2, 3 | verdict-driven questions and `-b`; ticket-branch identity; sha and restore hints |
| `lib/resolve.zsh`, `lib/cmd/create.zsh` | 2 | `wt_branch_name` moves next to `worktree_path` |
| `lib/cmd/create.zsh` | 4, 5, 6 | strict flags; name, base and checked-out checks; directory cleanup; branch-source resolution |
| `lib/cmd/repo.zsh` | 7 | `repo add` reads `WT_PROJECT_OPT`; `--name` value check |
| `lib/prompt.zsh` | 8, 9 | whole-sequence key decoding with `KEYTIMEOUT`; typeahead drain |
| `tests/helpers.zsh` | 8 | Phase 1's zpty helper block, byte for byte (`pty_start`, `pty_wait`, `pty_send`, `pty_finish`, `pty_run`); `setup_env` unsets `EDITOR VISUAL` |
| `tests/status_internal.test.zsh` | 1 | table-driven verdict test |
| `tests/remove_interactive.test.zsh` | 1, 2, 3, 9 | push-only, merged-and-gone, `-b -r`, mismatch questions, remote restore, e2e typeahead |
| `tests/remove.test.zsh` | 2, 3 | mismatch refusal, detached HEAD, restore command, runnable hint |
| `tests/create.test.zsh` | 4, 5, 6 | flags, names, base, checked out, cleanup, remote-only, existing branch, reuse, stale target |
| `tests/create_interactive.test.zsh` | 5 | re-ask a prompted ticket or base |
| `tests/manage.test.zsh` | 7 | `--project` both forms, `--name` without a value |
| `tests/prompt.test.zsh` | 8, 9 | `pty_script`; modifier and F keys, SS3, Alt, split Esc, lone Esc, typeahead (pty) |
| `README.md` | 3, 5, 6 | "워크트리 지우기" and "워크트리 만들기" bullets, exit-code row 2 |

Run each test file from the repo root with `zsh tests/<name>.test.zsh`. Its last line is `N passed, M failed`, and it exits non-zero on any failure. While a test fails, M counts lines in the failure file, and multi-line messages inflate it. So Step 2 below lists the failing assertions instead of M.

---

### Task 1: One merged verdict for `remove` and `status`

**Findings:** `journeys:remove-merged-verdict` (high).

**Files:**
- Modify: `lib/status.zsh`. Insert after `status_base_ref`, then change one line in `_status_branch_fields`.
- Modify: `lib/cmd/remove.zsh`, inside `cmd_remove`: the fetch condition, the verdict block that replaces the `merged`/`merged_into` block, the interactive questions, the `-b` decision, and the delete step.
- Test: `tests/status_internal.test.zsh` (append), and `tests/remove_interactive.test.zsh`, which replaces `test_branch_published_to_upstream_counts_as_merged`. That test pinned the bug.

**Interfaces:**
- Consumes `status_base_ref` and `forge_pr_rows`, both existing.
- Produces `status_merged_rule <in_base 0|1> <pr_state> <pr_sha> <tip>`: rc 0 when the branch is merged.
- Produces `branch_verdict <repo_path> <branch>`, which sets:
  - `REPLY` to `merged`, `pushed` or `unmerged`, and rc 1 when the branch does not exist.
  - `WT_VERDICT_BASE`: the base as shown, for example `origin/main`.
  - `WT_VERDICT_PR`: `#N` when only a merged PR shows the merge.
  - `WT_VERDICT_GONE`: `0|1`.

**Behaviour:**

| Verdict | Question label, default | `-b` (no terminal or `-y`) | `-b -r` |
|---|---|---|---|
| merged: tip in base, or PR merged at this tip | `(merged into origin/main)` or `(PR #N merged)`, Yes | deleted with `-D` | deleted with `-D` |
| pushed: tip on its remote upstream | `(pushed, not merged into origin/main)`, No; yes plus remote yes asks "lose its commits?" (No) | `git branch -d` (succeeds) | local kept, ✗ `not merged into origin/main; use -B` |
| unmerged | `(not merged into origin/main[; its upstream was deleted])`, No, then the existing force question | `git branch -d` (fails, ✗) | local kept, ✗ as above |

- [ ] **Step 1: Write the failing tests**

```diff
diff --git a/tests/remove_interactive.test.zsh b/tests/remove_interactive.test.zsh
index 25d78be..d3b271f 100644
--- a/tests/remove_interactive.test.zsh
+++ b/tests/remove_interactive.test.zsh
@@ -279,19 +279,67 @@ test_gone_upstream_with_remote_flag_skips_push() {
   assert_eq "${out//failed to delete remote branch/}" "$out" "no doomed push"
 }
 
-# `git branch -d` judges "merged" against the upstream when one exists: a branch fully pushed
-# to its upstream but not merged into the repo's HEAD is deletable without force.
-test_branch_published_to_upstream_counts_as_merged() {
-  fixture
-  print y > "$WT/f"; git -C "$WT" add -A; git -C "$WT" commit -qm c
+# commit_in_wt <name>: one commit in the worktree; prints its sha.
+commit_in_wt() { print "$1" > "$WT/$1"; git -C "$WT" add -A; git -C "$WT" commit -qm "$1"; git -C "$WT" rev-parse HEAD; }
+
+test_pushed_only_branch_is_not_called_merged() {
+  fixture; commit_in_wt C >/dev/null
   git -C "$WT" push -q -u origin fix/T 2>/dev/null
-  answers "" "n" ""
+  answers "" "n" ""             # local: default, remote: no, proceed
   local out; out="$(wt remove app fix T 2>&1)"
-  assert_contains "$out" "(merged)"
-  assert_eq "${out//unmerged/}" "$out" "no force prompt"
+  assert_contains "$out" "delete local branch 'fix/T'? (pushed, not merged into origin/main)"
+  assert_contains "$(local_branch fix/T)" "fix/T" "default is No"
+}
+
+test_branch_and_remote_flags_keep_a_branch_not_merged_into_base() {
+  fixture; local sha; sha="$(commit_in_wt C)"
+  git -C "$WT" push -q -u origin fix/T 2>/dev/null
+  local out; out="$(wt remove app fix T -b -r 2>&1)"
+  assert_eq "$?" 0
+  assert_eq "$(remote_branch fix/T)" "" "remote branch deleted"
+  assert_contains "$(local_branch fix/T)" "fix/T" "local branch kept"
+  assert_contains "$out" "not merged into origin/main; use -B"
+  assert_contains "$(git -C "$HOME/src/app" rev-list --all)" "$sha" "commit still reachable"
+}
+
+test_pushed_branch_asks_before_deleting_both_copies() {
+  fixture; local sha; sha="$(commit_in_wt C)"
+  git -C "$WT" push -q -u origin fix/T 2>/dev/null
+  answers "y" "y" "" ""         # local: yes, remote: yes, delete both anyway: default, proceed
+  local out; out="$(wt remove app fix T 2>&1)"
+  assert_contains "$out" "its remote branch is being deleted too"
+  assert_contains "$(local_branch fix/T)" "fix/T" "default keeps the local branch"
+  assert_eq "$(remote_branch fix/T)" "" "remote branch deleted"
+}
+
+# merged_and_gone_fixture: someone merged fix/T into origin/main and deleted its remote branch;
+# the local main checkout never pulled.
+merged_and_gone_fixture() {
+  fixture; commit_in_wt G >/dev/null
+  git -C "$WT" push -q -u origin fix/T 2>/dev/null
+  git clone -q "$HOME/remote.git" "$HOME/other"
+  git -C "$HOME/other" merge -q --no-ff -m "Merge PR" origin/fix/T
+  git -C "$HOME/other" push -q origin main
+  git -C "$HOME/other" push -q origin --delete fix/T
+  git -C "$HOME/src/app" fetch -q --prune origin
+}
+
+test_branch_merged_into_origin_after_its_remote_was_deleted_is_merged() {
+  merged_and_gone_fixture
+  answers "" ""                 # local: default, proceed
+  local out; out="$(wt remove app fix T 2>&1)"
+  assert_contains "$out" "delete local branch 'fix/T'? (merged into origin/main)"
+  assert_eq "${out//unmerged/}" "$out" "no force question"
   assert_eq "$(local_branch fix/T)" ""
 }
 
+test_branch_flag_deletes_a_branch_merged_into_origin_without_force() {
+  merged_and_gone_fixture
+  local out; out="$(wt remove app fix T -b 2>&1)"
+  assert_eq "$?" 0
+  assert_eq "$(local_branch fix/T)" "" "deleted although local main is stale"
+}
+
 # create accepts a ticket containing "/", nesting the worktree one level deeper.
 test_picker_finds_ticket_with_slash() {
   fixture
diff --git a/tests/status_internal.test.zsh b/tests/status_internal.test.zsh
index 2181ed1..c4232d6 100644
--- a/tests/status_internal.test.zsh
+++ b/tests/status_internal.test.zsh
@@ -152,4 +152,54 @@ test_pr_state_counts_only_at_the_pr_head() {
   assert_eq "${f[24]}" merged pr-state-still-shown
 }
 
+# verdict_repo: app with a bare origin and one branch per verdict case. Local main stays
+# behind origin/main, as after merging on the forge without pulling.
+verdict_repo() {
+  local a="$HOME/src/app" b
+  make_repo "$a"
+  typeset -ga WT_PROJECTS=(me)
+  typeset -gA WT_PCFG=(me.repo_root "$HOME/src" me.worktree_root "$HOME/wts") WT_CFG=() WT_RCFG=()
+  git init -q --bare -b main "$HOME/remote.git"
+  git -C "$a" remote add origin "$HOME/remote.git"
+  git -C "$a" push -q -u origin main
+  for b in anc gone push prtip prold local; do
+    git -C "$a" checkout -q -b "fix/$b" main
+    git -C "$a" commit -q --allow-empty -m "$b"
+    [[ "$b" == local ]] || git -C "$a" push -q -u origin "fix/$b" 2>/dev/null
+  done
+  printf 'fix/%s\t#%s\tmerged\thttps://x/%s\t%s\n' \
+    prtip 1 1 "$(git -C "$a" rev-parse fix/prtip)" prold 2 2 "$(git -C "$a" rev-parse fix/prold)" > "$HOME/prs"
+  git -C "$a" checkout -q fix/prold
+  git -C "$a" commit -q --allow-empty -m after-the-pr
+  git -C "$a" checkout -q main
+  git clone -q "$HOME/remote.git" "$HOME/other"
+  git -C "$HOME/other" merge -q --no-ff -m "Merge PRs" origin/fix/anc origin/fix/gone >/dev/null
+  git -C "$HOME/other" push -q origin main
+  git -C "$HOME/other" push -q origin --delete fix/gone
+  git -C "$a" fetch -q --prune origin
+}
+
+test_remove_and_status_share_the_merged_verdict() {
+  verdict_repo
+  forge_pr_rows() { cat "$HOME/prs"; }
+  local rows b; local -a f; local -A tagged
+  rows="$(status_collect_repo me app "$HOME/src/app" 30 "$HOME/prs" | grep $'^branch\t')"
+  for b in "${(@f)rows}"; do f=("${(@ps:\t:)b}"); tagged[${f[8]}]=${f[14]}; done
+  for b in anc:merged:1 gone:merged:1 prtip:merged:1 push:pushed:0 prold:unmerged:0 local:unmerged:0; do
+    branch_verdict "$HOME/src/app" "fix/${b%%:*}"
+    assert_eq "$REPLY" "${${b#*:}%:*}" "verdict fix/${b%%:*}"
+    assert_eq "${tagged[fix/${b%%:*}]}" "${b##*:}" "status merged fix/${b%%:*}"
+  done
+  assert_eq "$WT_VERDICT_BASE" origin/main base-name
+  branch_verdict "$HOME/src/app" fix/prtip
+  assert_eq "$WT_VERDICT_PR" "#1" pr-named
+  branch_verdict "$HOME/src/app" fix/gone
+  assert_eq "$WT_VERDICT_PR" "" ancestry-needs-no-pr
+  forge_pr_rows() { return 1; }
+  branch_verdict "$HOME/src/app" fix/prtip
+  assert_eq "$REPLY" pushed without-forge-data-ancestry-only
+  # unfunction would delete the real forge_pr_rows for every later test in this file.
+  source "$WT_TEST_ROOT/lib/forge.zsh"
+}
+
 run_tests
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zsh tests/status_internal.test.zsh; zsh tests/remove_interactive.test.zsh`

Expected: FAIL.
- `status_internal`: `command not found: branch_verdict` (`verdict fix/anc: expected [merged] got [null]`, …), plus `status merged fix/prtip: expected [1] got [0]`. That is 10 failing assertions; 59 pass.
- `remove_interactive` fails:
  - `default is No` (the push-only branch was deleted under "(merged)")
  - `local branch kept` and `commit still reachable` (`-b -r` lost the commit)
  - `deleted although local main is stale`
  - `default keeps the local branch`

- [ ] **Step 3: Implement**

```diff
diff --git a/lib/cmd/remove.zsh b/lib/cmd/remove.zsh
index 2a1b9ab..cd12609 100644
--- a/lib/cmd/remove.zsh
+++ b/lib/cmd/remove.zsh
@@ -259,31 +259,48 @@ cmd_remove() {
   fi
 
   local remote="" rbranch=""
-  if [[ -n "$branch" ]] && (( interactive || delete_remote )); then
+  if [[ -n "$branch" ]] && (( interactive || delete_remote || (delete_branch && ! force_branch) )); then
     wt_fetch_origin "$repo_path"
     _wt_remote_branch "$repo_path" "$branch" && { remote="${reply[1]}" rbranch="${reply[2]}"; }
   fi
-  local -i merged=0
-  local merged_into=HEAD up_ref
-  if [[ -n "$branch" ]]; then
-    # The reference `git branch -d` checks: the upstream when it exists, else HEAD.
-    up_ref="$(git -C "$repo_path" for-each-ref --format='%(upstream)' "refs/heads/$branch" 2>/dev/null)"
-    [[ -n "$up_ref" ]] && git -C "$repo_path" show-ref --verify --quiet "$up_ref" && merged_into="$up_ref"
-    git -C "$repo_path" merge-base --is-ancestor "refs/heads/$branch" "$merged_into" 2>/dev/null && merged=1
+  local verdict="" base_name="" label=""
+  if [[ -n "$branch" ]] && (( interactive || (delete_branch && ! force_branch) )); then
+    branch_verdict "$repo_path" "$branch"; verdict="$REPLY"
+    base_name="${WT_VERDICT_BASE:-the base branch}"
+    case "$verdict" in
+      merged) label="merged into $base_name"; [[ -n "$WT_VERDICT_PR" ]] && label="PR $WT_VERDICT_PR merged" ;;
+      pushed) label="pushed, not merged into $base_name" ;;
+      *)      label="not merged into $base_name"; (( WT_VERDICT_GONE )) && label+="; its upstream was deleted" ;;
+    esac
   fi
 
   if (( interactive )) && [[ -n "$branch" ]]; then
     if (( ! delete_branch )); then
-      if (( merged )); then prompt_confirm "delete local branch '$branch'? (merged)" y && delete_branch=1
-      else prompt_confirm "delete local branch '$branch'? (not merged)" n && delete_branch=1; fi
+      local def=n; [[ "$verdict" == merged ]] && def=y
+      prompt_confirm "delete local branch '$branch'? ($label)" $def && delete_branch=1
     fi
-    if (( delete_branch && ! force_branch && ! merged )); then
+    if (( delete_branch && ! force_branch )) && [[ "$verdict" == unmerged ]]; then
       if prompt_confirm "'$branch' has unmerged commits that would be lost — force-delete it?" n; then force_branch=1
       else delete_branch=0; fi
     fi
     if (( ! delete_remote )) && [[ -n "$remote" ]]; then
       prompt_confirm "delete remote branch '$remote/$rbranch' too? (pushes a delete to $remote)" n && delete_remote=1
     fi
+    if (( delete_branch && delete_remote && ! force_branch )) && [[ "$verdict" == pushed ]]; then
+      if prompt_confirm "'$branch' is not merged into $base_name and its remote branch is being deleted too — force-delete the local branch and lose its commits?" n; then force_branch=1
+      else delete_branch=0; fi
+    fi
+  fi
+  local -i verified=0
+  local branch_row=""
+  if (( delete_branch && ! force_branch )); then
+    if [[ "$verdict" == merged ]]; then verified=1
+    elif (( delete_remote )); then
+      delete_branch=0
+      warn "keeping local branch $branch: it is not merged into $base_name and its remote branch is being deleted"
+      hint "to delete it anyway, and lose its commits: git -C $repo_path branch -D $branch"
+      branch_row="fail"$'\t'"local branch   kept          $branch (not merged into $base_name; use -B)"
+    fi
   fi
   if (( delete_remote )) && [[ -z "$remote" ]]; then
     warn "no remote branch known for '${branch:-(detached HEAD)}'; skipping remote delete"
@@ -328,8 +345,10 @@ cmd_remove() {
 
   if (( delete_branch )); then
     ui_progress $(( ++step )) $total "deleting local branch $branch"
-    if remove_branch "$repo_path" "$branch" "$force_branch"; then results+=("ok"$'\t'"local branch   deleted       $branch")
+    if remove_branch "$repo_path" "$branch" $(( force_branch || verified )); then results+=("ok"$'\t'"local branch   deleted       $branch")
     else results+=("fail"$'\t'"local branch   not deleted   ${branch:-(detached HEAD)}"); fi
+  elif [[ -n "$branch_row" ]]; then
+    results+=("$branch_row")
   else
     results+=("skip"$'\t'"local branch   kept          ${branch:-(detached HEAD)}")
   fi
diff --git a/lib/status.zsh b/lib/status.zsh
index fedb8b4..25646e8 100644
--- a/lib/status.zsh
+++ b/lib/status.zsh
@@ -58,6 +58,44 @@ status_base_ref() {
   return 1
 }
 
+# status_merged_rule <in_base 0|1> <pr_state> <pr_sha> <tip>: rc 0 when the branch's tip is in
+# the base branch, or its PR/MR was merged at exactly this tip.
+status_merged_rule() { (( $1 )) || [[ "$2" == merged && -n "$3" && "$3" == "$4" ]]; }
+
+# branch_verdict <repo_path> <branch>: REPLY = merged (status_merged_rule), pushed (every commit
+# is on its remote upstream) or unmerged; WT_VERDICT_BASE = the base as shown (origin/main),
+# WT_VERDICT_PR = the merged PR (#N) when only the forge shows the merge, WT_VERDICT_GONE = 0|1.
+typeset -g WT_VERDICT_BASE='' WT_VERDICT_PR=''
+typeset -gi WT_VERDICT_GONE=0
+branch_verdict() {
+  local repo_path="$1" br="$2" base tip up line
+  local -i in_base=0
+  local -a pr
+  WT_VERDICT_BASE='' WT_VERDICT_PR='' WT_VERDICT_GONE=0 REPLY=unmerged
+  tip="$(git -C "$repo_path" rev-parse -q --verify "refs/heads/$br^{commit}")" || return 1
+  if base="$(status_base_ref "$repo_path")"; then
+    WT_VERDICT_BASE="${${base#refs/remotes/}#refs/heads/}"
+    git -C "$repo_path" merge-base --is-ancestor "$tip" "$base" 2>/dev/null && in_base=1
+  fi
+  if (( ! in_base )); then
+    for line in ${(f)"$(forge_pr_rows "$repo_path" 2>/dev/null)"}; do
+      [[ "${line%%$'\t'*}" == "$br" ]] && { pr=("${(@ps:\t:)line}"); break; }
+    done
+  fi
+  if status_merged_rule $in_base "${pr[3]:-}" "${pr[5]:-}" "$tip"; then
+    (( in_base )) || WT_VERDICT_PR="${pr[2]}"
+    REPLY=merged; return 0
+  fi
+  up="$(git -C "$repo_path" for-each-ref --format='%(upstream)' "refs/heads/$br" 2>/dev/null)"
+  [[ "$up" == refs/remotes/* ]] || return 0
+  if git -C "$repo_path" show-ref --verify --quiet "$up"; then
+    git -C "$repo_path" merge-base --is-ancestor "$tip" "$up" 2>/dev/null && REPLY=pushed
+  else
+    WT_VERDICT_GONE=1
+  fi
+  return 0
+}
+
 # status_flag <merged> <gone> <pr_state> <dirty> <ahead> <has_upstream> <base_ahead>
 #             <locked> <age_s> <stale_s>
 # REPLY = dirty|safe|stale|-. Losing work outranks everything, so dirty wins over safe and stale.
@@ -132,7 +170,7 @@ _status_branch_fields() {
     if [[ "${b_track[$br]}" == gone ]]; then gone=1
     else _status_track "${b_track[$br]}"; ahead=${reply[1]} behind=${reply[2]}; fi
   fi
-  (( ${+b_merged[$br]} )) && merged=1
+  status_merged_rule $(( ${+b_merged[$br]} )) "${pr_state[$br]:-}" "${pr_sha[$br]:-}" "${b_tip[$br]:-}" && merged=1
   if [[ -n "${b_ab[$br]:-}" ]]; then
     bahead=${b_ab[$br]%% *} bbehind=${b_ab[$br]##* }
   elif [[ "$base" != - ]]; then
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zsh tests/status_internal.test.zsh && zsh tests/remove_interactive.test.zsh && zsh tests/remove.test.zsh && zsh tests/status.test.zsh && zsh tests/status_tui.test.zsh`

Expected: `69 passed`, `103 passed`, `38 passed`, `44 passed`, `28 passed`, all with `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/status.zsh lib/cmd/remove.zsh tests/status_internal.test.zsh tests/remove_interactive.test.zsh
git commit -F - <<'MSG'
fix(remove): judge "merged" against origin's default branch, as status does

remove labelled a branch "(merged)", default Yes, whenever its upstream held every commit.
Pushing alone qualified, so answering yes to the remote question too deleted the only
copies. After a forge merge with the remote branch auto-deleted and local main not pulled,
the same branch came out "(not merged)" and needed a force-delete.

status_merged_rule is now the one rule: the tip is in status_base_ref (origin/HEAD, else
origin/main or origin/master, else the main checkout's branch), or its PR/MR was merged at
exactly this tip. branch_verdict adds "pushed" (on its remote upstream only). status's
merged field goes through the same rule, so a squash-merged PR at the tip is now tagged
merged, as README:169 already said.

-b no longer trusts `git branch -d`, which compares with a stale HEAD when the upstream is
gone and is satisfied by a remote copy that -r is about to delete. A merged verdict
deletes with -D. With -r, a branch that is not merged is kept and reported with a ✗ row.
Interactively, pushed plus "delete remote too" asks before losing the commits. A non-forced
-b now fetches origin first, so the verdict uses current refs.
MSG
```

---

### Task 2: `-b`/`-B` act on the ticket branch

**Findings:** `critic:branch-identity-drift` (remove half).

**Files:**
- Modify: `lib/resolve.zsh`, which gains `wt_branch_name`.
- Modify: `lib/cmd/create.zsh`, which drops its copy of `wt_branch_name`.
- Modify: `lib/cmd/remove.zsh`: `remove_branch`, and in `cmd_remove` the branch capture, the mismatch refusal, the header, the question, the missing-branch guard, the plan and the result rows.
- Test: `tests/remove.test.zsh` and `tests/remove_interactive.test.zsh` (append).

**Interfaces:**
- `wt_branch_name <kind> <ticket>` is unchanged; it is now defined in `lib/resolve.zsh`.
- In `cmd_remove`, `branch` is now the ticket branch when it exists, else empty.
- `other` is the checked-out branch when it differs from the ticket branch.
- `branch_desc` is the display text, for example `fix/T (checked out: spike)` or `fix/T (does not exist)`.

**Behaviour:**
- Another branch is checked out, no terminal, and `-b`, `-B` or `-r` was given: exit 1 before the dirt check, the fetch or any removal. The message names both branches, with two hints.
- Another branch is checked out, interactive: the header, the question and the plan name both branches, and the branch steps act on the ticket branch only.
- Detached HEAD: `-b` deletes the ticket branch if it exists. Before this change it printed "no branch to delete (detached HEAD)".
- The ticket branch is missing: `-b` warns `no local branch fix/T; nothing to delete` and continues.

- [ ] **Step 1: Write the failing tests**

```diff
diff --git a/tests/remove.test.zsh b/tests/remove.test.zsh
index 4fa48d0..e7c7b30 100644
--- a/tests/remove.test.zsh
+++ b/tests/remove.test.zsh
@@ -163,4 +163,26 @@ test_remove_dashdash_ends_options() {
   assert_not_exists "$WT"
 }
 
+test_branch_flags_refuse_when_another_branch_is_checked_out() {
+  fixture
+  git -C "$WT" switch -q -c spike
+  print s > "$WT/s"; git -C "$WT" add -A; git -C "$WT" commit -qm spike
+  local out; out="$(wt remove app fix T -B 2>&1)"
+  assert_eq "$?" 1
+  assert_contains "$out" "'spike' is checked out, not its ticket branch 'fix/T'"
+  assert_dir "$WT"
+  assert_contains "$(git -C "$HOME/src/app" branch --list spike)" spike "spike kept"
+  assert_exit 1 wt remove app fix T -b
+  assert_exit 0 wt remove app fix T
+  assert_contains "$(git -C "$HOME/src/app" branch --list spike fix/T)" spike "plain remove keeps every branch"
+}
+
+test_detached_head_branch_flag_deletes_the_ticket_branch() {
+  fixture
+  git -C "$WT" switch -q --detach
+  local out; out="$(wt remove app fix T -b 2>&1)"
+  assert_eq "$?" 0
+  assert_eq "$(git -C "$HOME/src/app" branch --list fix/T)" ""
+}
+
 run_tests
diff --git a/tests/remove_interactive.test.zsh b/tests/remove_interactive.test.zsh
index d3b271f..a4e03ab 100644
--- a/tests/remove_interactive.test.zsh
+++ b/tests/remove_interactive.test.zsh
@@ -355,4 +355,15 @@ test_picker_finds_ticket_with_slash() {
   assert_eq "${out//T\/sub/}" "$out" "never descends into a worktree"
 }
 
+test_questions_name_the_ticket_branch_when_another_is_checked_out() {
+  fixture; git -C "$WT" switch -q -c spike
+  answers "y" "n" ""            # local fix/T: yes, remote origin/fix/T: no, proceed
+  local out; out="$(wt remove app fix T 2>&1)"
+  assert_eq "$?" 0
+  assert_contains "$out" "delete local branch 'fix/T'?"
+  assert_contains "$out" "checked out: spike"
+  assert_eq "$(local_branch fix/T)" ""
+  assert_contains "$(local_branch spike)" spike
+}
+
 run_tests
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zsh tests/remove.test.zsh; zsh tests/remove_interactive.test.zsh`

Expected: FAIL.
- `remove -B` exited 0, deleted `spike` and removed the worktree, so `spike kept` fails along with the exit-code assertions.
- The detached-HEAD `-b` kept `fix/T`.
- Interactively, the question named `spike`. The answers then ran out at `Proceed?`, which gave `expected [0] got [130]`.

- [ ] **Step 3: Implement**

```diff
diff --git a/lib/cmd/create.zsh b/lib/cmd/create.zsh
index c48d1d0..44da43b 100644
--- a/lib/cmd/create.zsh
+++ b/lib/cmd/create.zsh
@@ -22,12 +22,6 @@ _wt_worktree_is_registered() {
   (( found ))
 }
 
-# wt_branch_name <kind> <ticket>: the one place "$kind/$ticket" is joined into a branch name.
-# Coherence cleanup: this used to be reconstructed independently in three spots below (the
-# show-ref probe, the confirmation summary, and create_do's own copy) -- three separate copies
-# of the same join that could silently drift apart. Every caller now routes through here.
-wt_branch_name() { print -r -- "$1/$2"; }
-
 # create_pick_repo: interactive project -> repo selection. Sets project, repo, repo_path in
 # the CALLER's scope (cmd_create's locals) -- deliberately not `local` here.
 #
diff --git a/lib/cmd/remove.zsh b/lib/cmd/remove.zsh
index cd12609..d438f35 100644
--- a/lib/cmd/remove.zsh
+++ b/lib/cmd/remove.zsh
@@ -3,7 +3,6 @@
 # the worktree — `git branch --show-current` needs the worktree to still exist.
 remove_branch() {
   local repo_path="$1" branch="$2" force="$3" flag='-d' out
-  [[ -n "$branch" ]] || { warn "no branch to delete (detached HEAD); skipping"; return 1; }
   (( force )) && flag='-D'
   if out="$(git -C "$repo_path" branch "$flag" "$branch" 2>&1)"; then success "deleted branch: $branch"; return 0; fi
   if (( force )); then
@@ -186,7 +185,7 @@ cmd_remove() {
     _rm_pick_worktree "$repo" "$kind"   # sets repo kind ticket, and WT_PROJECT_OPT
   fi
 
-  local r project repo_path target branch
+  local r project repo_path target branch=""
   r="$(resolve_repo "$repo")" || exit $?
   project="${r%%$'\t'*}" repo_path="${r#*$'\t'}"
   target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
@@ -198,13 +197,24 @@ cmd_remove() {
     [[ -d "$dest" ]] || die_with_hints "--to: not a directory: $dest" "pass an existing directory, e.g. --to $repo_path"
     _rm_is_inside "$dest" "$target" && die_with_hints "--to: inside the worktree being removed: $dest" "pass a directory outside $target"
   fi
-  # Capture the branch name before the worktree is removed — afterwards there is nothing
-  # left at $target to ask git about.
-  branch="$(git -C "$target" branch --show-current 2>/dev/null || true)"
+  # Read before the worktree is removed: afterwards there is nothing at $target to ask git about.
+  local ticket_branch other branch_desc
+  ticket_branch="$(wt_branch_name "$kind" "$ticket")"
+  other="$(git -C "$target" branch --show-current 2>/dev/null || true)"
+  [[ "$other" == "$ticket_branch" ]] && other=""
+  git -C "$repo_path" show-ref --verify --quiet "refs/heads/$ticket_branch" && branch="$ticket_branch"
+  branch_desc="$ticket_branch"
+  [[ -z "$branch" ]] && branch_desc+=" (does not exist)"
+  [[ -n "$other" ]] && branch_desc+=" (checked out: $other)"
   local -i interactive=0
   prompt_available && interactive=1
+  if [[ -n "$other" ]] && (( ! interactive && (delete_branch || delete_remote) )); then
+    die_with_hints "'$other' is checked out, not its ticket branch '$ticket_branch'; refusing to guess which branch -b/-B/-r mean" \
+      "remove the worktree and keep both branches: workytree remove $repo $kind $ticket" \
+      "then delete the one you mean: git -C $repo_path branch -D <branch>"
+  fi
 
-  info "removing worktree"; print -r -- "  path: $target"; [[ -n "$branch" ]] && print -r -- "  branch: $branch"
+  info "removing worktree"; print -r -- "  path: $target"; print -r -- "  branch: $branch_desc"
   git -C "$target" status --short --branch | sed 's/^/  /'
 
   # A single probe decides everything below (_worktree_dirt_kind). Calling it twice under two
@@ -277,7 +287,7 @@ cmd_remove() {
   if (( interactive )) && [[ -n "$branch" ]]; then
     if (( ! delete_branch )); then
       local def=n; [[ "$verdict" == merged ]] && def=y
-      prompt_confirm "delete local branch '$branch'? ($label)" $def && delete_branch=1
+      prompt_confirm "delete local branch '$branch'? ($label${other:+; checked out: $other})" $def && delete_branch=1
     fi
     if (( delete_branch && ! force_branch )) && [[ "$verdict" == unmerged ]]; then
       if prompt_confirm "'$branch' has unmerged commits that would be lost — force-delete it?" n; then force_branch=1
@@ -302,8 +312,12 @@ cmd_remove() {
       branch_row="fail"$'\t'"local branch   kept          $branch (not merged into $base_name; use -B)"
     fi
   fi
+  if (( delete_branch )) && [[ -z "$branch" ]]; then
+    warn "no local branch $ticket_branch; nothing to delete"
+    delete_branch=0
+  fi
   if (( delete_remote )) && [[ -z "$remote" ]]; then
-    warn "no remote branch known for '${branch:-(detached HEAD)}'; skipping remote delete"
+    warn "no remote branch known for '$ticket_branch'; skipping remote delete"
     hint "if it exists upstream, refresh tracking refs first: git -C $repo_path fetch --all"
     delete_remote=0
   fi
@@ -317,7 +331,7 @@ cmd_remove() {
     (( delete_remote )) && remote_plan="delete"
     ui_rule plan
     printf '  %-14s %-14s %s\n' "worktree" "remove$( (( force_remove )) && print -n ' (force)')" "$target" \
-      "local branch" "$branch_plan" "${branch:-(detached HEAD)}" \
+      "local branch" "$branch_plan" "$branch_desc" \
       "remote branch" "$remote_plan" "${remote:+$remote/$rbranch}"
     [[ -n "$dest" ]] && printf '  %-14s %s\n' "then move to" "$dest"
     prompt_confirm "Proceed?" y || exit 130
@@ -346,11 +360,11 @@ cmd_remove() {
   if (( delete_branch )); then
     ui_progress $(( ++step )) $total "deleting local branch $branch"
     if remove_branch "$repo_path" "$branch" $(( force_branch || verified )); then results+=("ok"$'\t'"local branch   deleted       $branch")
-    else results+=("fail"$'\t'"local branch   not deleted   ${branch:-(detached HEAD)}"); fi
+    else results+=("fail"$'\t'"local branch   not deleted   $branch"); fi
   elif [[ -n "$branch_row" ]]; then
     results+=("$branch_row")
   else
-    results+=("skip"$'\t'"local branch   kept          ${branch:-(detached HEAD)}")
+    results+=("skip"$'\t'"local branch   kept          $branch_desc")
   fi
   if (( delete_remote )); then
     ui_progress $(( ++step )) $total "deleting remote branch $remote/$rbranch"
diff --git a/lib/resolve.zsh b/lib/resolve.zsh
index 1899f86..4ed9eb4 100644
--- a/lib/resolve.zsh
+++ b/lib/resolve.zsh
@@ -307,6 +307,8 @@ infer_current_repo() {
 
 worktree_parent() { local p="$1" repo="$2" kind="${3:-}"; print -r -- "$(project_worktree_root "$p")/$repo${kind:+/$kind}"; }
 worktree_path()   { print -r -- "$(project_worktree_root "$1")/$2/$3/$4"; }
+# wt_branch_name <kind> <ticket>: the worktree's ticket branch.
+wt_branch_name()  { print -r -- "$1/$2"; }
 
 default_base_ref() {
   local repo_path="$1" upstream current
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zsh tests/remove.test.zsh && zsh tests/remove_interactive.test.zsh && zsh tests/create.test.zsh`

Expected: `47 passed`, `108 passed`, `35 passed`, all with `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/resolve.zsh lib/cmd/create.zsh lib/cmd/remove.zsh tests/remove.test.zsh tests/remove_interactive.test.zsh
git commit -F - <<'MSG'
fix(remove): -b/-B delete the ticket branch, never whatever is checked out

remove took the branch to delete from `git branch --show-current` in the worktree. A
worktree switched to an experiment branch lost that branch to `-B -y`, with no trace,
while the ticket branch stayed. A detached HEAD made -b a no-op.

The branch steps now always mean <kind>/<ticket>. The checked-out branch is only
reported. Without a terminal, a different checked-out branch makes -b/-B/-r stop before
anything is removed, because the flag's target is ambiguous. Interactively, the header,
the question and the plan show both names. wt_branch_name moves to lib/resolve.zsh so
remove does not depend on create's module.
MSG
```

---

### Task 3: Every deletion prints its sha and a restore command

**Findings:** `critic:branch-delete-no-recovery-sha`, `output:remove-branch-hint-deadend`.

**Files:**
- Modify: `lib/cmd/remove.zsh`: `remove_branch`, `remove_remote_branch`, and the result rows in `cmd_remove`.
- Modify: `README.md`, section "워크트리 지우기".
- Test: `tests/remove.test.zsh` and `tests/remove_interactive.test.zsh` (append).

**Interfaces:**
- `remove_branch <repo_path> <branch> <force>` sets `REPLY` to the short sha the branch had.
- `remove_remote_branch <repo_path> <remote> <remote_branch>` sets `REPLY` to the short sha of the tracking ref before the push.
- Both print `deleted … (was <sha>)` and a `hint: restore it with: …`.
- A non-forced failure hints `git -C <repo> branch -D <b>`, which is runnable now. "re-run remove" was not, because the worktree is already gone at that point.

- [ ] **Step 1: Write the failing tests**

```diff
diff --git a/tests/remove.test.zsh b/tests/remove.test.zsh
index e7c7b30..9dc7c8f 100644
--- a/tests/remove.test.zsh
+++ b/tests/remove.test.zsh
@@ -185,4 +185,25 @@ test_detached_head_branch_flag_deletes_the_ticket_branch() {
   assert_eq "$(git -C "$HOME/src/app" branch --list fix/T)" ""
 }
 
+test_branch_delete_prints_a_restore_command() {
+  fixture
+  print y > "$WT/f"; git -C "$WT" add -A; git -C "$WT" commit -qm c
+  local sha short out
+  sha="$(git -C "$WT" rev-parse HEAD)" short="$(git -C "$WT" rev-parse --short HEAD)"
+  out="$(wt remove app fix T -B 2>&1)"
+  assert_contains "$out" "deleted branch fix/T (was $short)"
+  assert_contains "$out" "local branch   deleted       fix/T (was $short)"
+  assert_contains "$out" "restore it with: git -C $HOME/src/app branch fix/T $short"
+  git -C "$HOME/src/app" branch fix/T "$short"
+  assert_eq "$(git -C "$HOME/src/app" rev-parse fix/T)" "$sha" "restored at the old tip"
+}
+
+test_unmerged_branch_hint_is_runnable() {
+  fixture
+  print y > "$WT/f"; git -C "$WT" add -A; git -C "$WT" commit -qm c
+  local out; out="$(wt remove app fix T -b 2>&1)"
+  assert_contains "$out" "force-delete it with: git -C $HOME/src/app branch -D fix/T"
+  assert_eq "${out//re-run remove/}" "$out" "no hint that needs the removed worktree"
+}
+
 run_tests
diff --git a/tests/remove_interactive.test.zsh b/tests/remove_interactive.test.zsh
index a4e03ab..a232feb 100644
--- a/tests/remove_interactive.test.zsh
+++ b/tests/remove_interactive.test.zsh
@@ -366,4 +366,14 @@ test_questions_name_the_ticket_branch_when_another_is_checked_out() {
   assert_contains "$(local_branch spike)" spike
 }
 
+test_remote_delete_prints_a_restore_command() {
+  fixture
+  local short out; short="$(git -C "$WT" rev-parse --short HEAD)"
+  out="$(wt remove app fix T -r 2>&1)"
+  assert_contains "$out" "deleted remote branch origin/fix/T (was $short)"
+  assert_contains "$out" "restore it with: git -C $HOME/src/app push origin ${short}:refs/heads/fix/T"
+  git -C "$HOME/src/app" push -q origin "${short}:refs/heads/fix/T"
+  assert_contains "$(remote_branch fix/T)" fix/T "restored"
+}
+
 run_tests
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zsh tests/remove.test.zsh; zsh tests/remove_interactive.test.zsh`

Expected: FAIL.
- The output has `deleted branch: fix/T` with no `(was …)`.
- The hint reads `re-run remove with --branch-force (-B)`, so `no hint that needs the removed worktree` fails.
- The remote output lacks `(was …)`.

- [ ] **Step 3: Implement**

```diff
diff --git a/lib/cmd/remove.zsh b/lib/cmd/remove.zsh
index d438f35..d7588a0 100644
--- a/lib/cmd/remove.zsh
+++ b/lib/cmd/remove.zsh
@@ -1,16 +1,20 @@
 # remove_branch <repo_path> <branch> <force>: best-effort branch delete after the worktree
-# using it is already gone. The branch name must be captured by the caller BEFORE removing
-# the worktree — `git branch --show-current` needs the worktree to still exist.
+# using it is already gone. REPLY = the short sha the branch pointed at.
 remove_branch() {
   local repo_path="$1" branch="$2" force="$3" flag='-d' out
   (( force )) && flag='-D'
-  if out="$(git -C "$repo_path" branch "$flag" "$branch" 2>&1)"; then success "deleted branch: $branch"; return 0; fi
+  REPLY="$(git -C "$repo_path" rev-parse --short "refs/heads/$branch" 2>/dev/null)"
+  if out="$(git -C "$repo_path" branch "$flag" "$branch" 2>&1)"; then
+    success "deleted branch $branch (was $REPLY)"
+    hint "restore it with: git -C $repo_path branch $branch $REPLY"
+    return 0
+  fi
   if (( force )); then
     warn "failed to delete branch: $branch. git said:"; _wt_indent_and_cap "$out" >&2
     hint "inspect it with: git -C $repo_path branch -vv --list $branch"
   else
     warn "branch not deleted (likely unmerged): $branch"
-    hint "re-run remove with --branch-force (-B) to force-delete it"
+    hint "force-delete it with: git -C $repo_path branch -D $branch"
   fi
   return 1
 }
@@ -37,10 +41,15 @@ _wt_remote_branch() {
   return 1
 }
 
+# remove_remote_branch <repo_path> <remote> <remote_branch>: REPLY = the short sha the
+# tracking ref pointed at before the delete.
 remove_remote_branch() {
   local repo_path="$1" remote="$2" rbranch="$3" out
+  REPLY="$(git -C "$repo_path" rev-parse --short "refs/remotes/$remote/$rbranch" 2>/dev/null)"
   if out="$(git -C "$repo_path" push "$remote" --delete "$rbranch" 2>&1)"; then
-    success "deleted remote branch: $remote/$rbranch"; return 0
+    success "deleted remote branch $remote/$rbranch (was $REPLY)"
+    hint "restore it with: git -C $repo_path push $remote ${REPLY}:refs/heads/$rbranch"
+    return 0
   fi
   warn "failed to delete remote branch: $remote/$rbranch. git said:"; _wt_indent_and_cap "$out" >&2
   hint "if it is already gone upstream, drop the stale ref: git -C $repo_path fetch --prune $remote"
@@ -359,7 +368,7 @@ cmd_remove() {
 
   if (( delete_branch )); then
     ui_progress $(( ++step )) $total "deleting local branch $branch"
-    if remove_branch "$repo_path" "$branch" $(( force_branch || verified )); then results+=("ok"$'\t'"local branch   deleted       $branch")
+    if remove_branch "$repo_path" "$branch" $(( force_branch || verified )); then results+=("ok"$'\t'"local branch   deleted       $branch (was $REPLY)")
     else results+=("fail"$'\t'"local branch   not deleted   $branch"); fi
   elif [[ -n "$branch_row" ]]; then
     results+=("$branch_row")
@@ -368,7 +377,7 @@ cmd_remove() {
   fi
   if (( delete_remote )); then
     ui_progress $(( ++step )) $total "deleting remote branch $remote/$rbranch"
-    if remove_remote_branch "$repo_path" "$remote" "$rbranch"; then results+=("ok"$'\t'"remote branch  deleted       $remote/$rbranch")
+    if remove_remote_branch "$repo_path" "$remote" "$rbranch"; then results+=("ok"$'\t'"remote branch  deleted       $remote/$rbranch (was $REPLY)")
     else results+=("fail"$'\t'"remote branch  not deleted   $remote/$rbranch"); fi
   elif [[ -n "$remote" ]]; then
     results+=("skip"$'\t'"remote branch  kept          $remote/$rbranch")
```

- [ ] **Step 4: README**

```diff
diff --git a/README.md b/README.md
index a481584..747af23 100644
--- a/README.md
+++ b/README.md
@@ -183,7 +183,10 @@ wt config set project.work.stale_days 60     # 한 프로젝트
 
 1. 어떤 워크트리를 지울지 (`repo`·`kind`·`ticket`이 빠졌을 때). 주어진 인자로 목록을 좁히고 지금 있는 워크트리를 먼저 제안
 2. 커밋 안 된 변경을 버릴지 (변경이 있을 때만. 거절하면 멈추고 `git stash -u`나 `--force`를 안내한다)
-3. 로컬 브랜치를 지울지. 병합된 브랜치는 기본값 예, 병합 안 된 브랜치는 강제 삭제를 한 번 더 확인
+3. 로컬 브랜치를 지울지. 대상은 언제나 ticket 브랜치(`<kind>/<ticket>`)이고, 워크트리에 다른 브랜치가 체크아웃돼 있으면 질문과 계획에 함께 표시한다. 기본값은 판정에 따라 다르다
+   - `merged into origin/main`: base 브랜치(`status`와 같은 기준)에 들어 있거나 PR/MR이 지금 커밋 그대로 병합됨. 기본값 예
+   - `pushed, not merged into origin/main`: upstream에만 있음. 기본값 아니오. 원격 브랜치까지 지우면 커밋이 어디에도 남지 않으므로 한 번 더 확인
+   - `not merged into origin/main`: 어디에도 없는 커밋이 있음. 기본값 아니오. 지우려면 강제 삭제를 한 번 더 확인
 4. 원격 브랜치를 지울지 (upstream이나 같은 이름의 `refs/remotes/<remote>/` ref가 있을 때). `git fetch --prune origin` 직후 확인. 원격에 삭제를 push하므로 기본값 아니오
 5. 지운 뒤 어디로 이동할지 (셸 통합으로 실행했을 때만)
 6. 계획 요약과 `Proceed?`
@@ -191,6 +194,9 @@ wt config set project.work.stale_days 60     # 한 프로젝트
 단계마다 진행 표시줄이 나오고, 실패하면 `hint:` 줄로 해결 방법을 알려 주며, 마지막 요약에 지운 것·남긴 것·실패한 것을 정리한다.
 
 - `-y`를 주거나 터미널이 없으면 묻지 않고 옵션대로 처리한다: `-b`/`-B` 로컬 브랜치, `-r` 원격 브랜치, `--to <dir>` 이동할 곳
+- `-b`는 위 판정이 병합됨인 브랜치를 지운다. 병합되지 않은 브랜치는 `git branch -d` 규칙을 따르고, `-r`과 함께 쓰면 로컬 브랜치를 남긴 채 요약에 ✗로 표시한다. 커밋을 버리고 지우려면 `-B`
+- 워크트리에 ticket 브랜치가 아닌 브랜치가 체크아웃돼 있으면 `-b`/`-B`/`-r`은 아무것도 지우지 않고 종료 코드 1로 멈춘다
+- 브랜치를 지우면 지우기 전 커밋을 `(was <sha>)`로 보여 주고, 되살리는 명령을 `hint:`로 알려 준다
 - 지금 있는 워크트리를 지우면 `--to`가 없는 한 원본 repo로 이동
 - 브랜치 삭제가 실패해도 종료 코드는 유지. 그 시점에 워크트리는 이미 지워진 상태
 
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zsh tests/remove.test.zsh && zsh tests/remove_interactive.test.zsh`

Expected: `53 passed`, `111 passed`, all with `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add lib/cmd/remove.zsh README.md tests/remove.test.zsh tests/remove_interactive.test.zsh
git commit -F - <<'MSG'
fix(remove): print the deleted sha and a restore command for every branch delete

`git branch -D` reports "(was <sha>)", and remove threw that output away. The worktree
and its HEAD reflog are gone by then, so a wrongly deleted branch could only be found
again with `git fsck --lost-found`. Local and remote deletes now print the old sha in the
step line and the summary row, with a hint that recreates the branch. The non-forced
failure hint was "re-run remove with -B", which fails because the worktree no longer
exists; it is now `git branch -D`.

README: "워크트리 지우기" documents the verdict labels, the ticket-branch rule, -b with
-r, and the restore hints.
MSG
```

---

### Task 4: `create` rejects unknown flags

**Findings:** `automation:create-unknown-flags-passed-to-git`, `journeys:create-accepts-dash-args`.

**Files:**
- Modify: `lib/cmd/create.zsh`, in `cmd_create`'s argument loop. `require_config` moves after it.
- Test: `tests/create.test.zsh` (append).

**Interfaces:** `cmd_create` accepts `--ai` and `--`. Any other `-*` token before `--` is `usage_error "unknown flag: …"` (exit 2), raised before config, fetch or mkdir. If Phase 1 has merged first, keep its `--no-ai` arm.

- [ ] **Step 1: Write the failing tests**

```diff
diff --git a/tests/create.test.zsh b/tests/create.test.zsh
index 8d52685..a470c5c 100644
--- a/tests/create.test.zsh
+++ b/tests/create.test.zsh
@@ -162,4 +162,25 @@ test_create_last_stdout_line_is_still_the_path_after_fetch() {
   assert_eq "$(wt create app fix F -y 2>/dev/null | tail -1)" "$HOME/wts/app/fix/F"
 }
 
+test_create_rejects_unknown_flags_before_doing_anything() {
+  origin_fixture
+  local flag out
+  for flag in --force --dry-run --ia; do
+    out="$(wt create app fix X "$flag" -y 2>&1)"
+    assert_eq "$?" 2 "$flag"
+    assert_contains "$out" "unknown flag: $flag"
+    assert_eq "${out//fetching/}" "$out" "$flag: no fetch"
+  done
+  out="$(wt create app fix -T2 -y 2>&1)"
+  assert_eq "$?" 2 -T2
+  assert_contains "$out" "unknown flag: -T2"
+  assert_not_exists "$HOME/wts"
+}
+
+test_create_dashdash_still_passes_a_literal_dash_ticket() {
+  fixture
+  assert_exit 0 wt create -- app fix -T2 main
+  assert_eq "$(git -C "$HOME/wts/app/fix/-T2" branch --show-current)" "fix/-T2"
+}
+
 run_tests
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zsh tests/create.test.zsh`

Expected: FAIL.
- `--force: expected [2] got [0]`: git took it as its own `--force` and built the worktree.
- `--dry-run` and `--ia` returned 0, because the worktree already existed and was "reused".
- `-T2: expected [2] got [0]`.
- `exists $HOME/wts`.
- The `--` test already passes; it pins the escape hatch.

- [ ] **Step 3: Implement**

```diff
diff --git a/lib/cmd/create.zsh b/lib/cmd/create.zsh
index 44da43b..67be3dd 100644
--- a/lib/cmd/create.zsh
+++ b/lib/cmd/create.zsh
@@ -88,22 +88,19 @@ create_do() {
 }
 
 cmd_create() {
-  require_config
   local -a pos
   local -i want_ai=0 saw_dashdash=0
   local arg
-  # Only `--ai` is filtered out; every other dash-prefixed token still stays positional, as
-  # it always has. Making every `-*` a usage error the way remove does would break input
-  # that passes today -- that's out of scope for this task. `--` is the escape hatch for
-  # passing a literal `--ai` as a repo name.
   for arg in "$@"; do
     if (( saw_dashdash )); then pos+=("$arg"); continue; fi
     case "$arg" in
       --)   saw_dashdash=1 ;;
       --ai) want_ai=1 ;;
+      -*)   usage_error "unknown flag: $arg (put a value that starts with '-' after --)" ;;
       *)    pos+=("$arg") ;;
     esac
   done
+  require_config
   (( ${#pos} <= 4 )) || usage_error "usage: workytree create [repo] [kind] [ticket] [base] [--ai]"
   local repo="" kind="" ticket="" base="" project="" repo_path="" r inferred=""
   inferred="$(infer_current_repo 2>/dev/null)" || inferred=""
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zsh tests/create.test.zsh && zsh tests/create_interactive.test.zsh && zsh tests/shell.test.zsh && zsh tests/agent.test.zsh`

Expected: `49 passed`, `18 passed`, `58 passed`, `75 passed`, all with `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/create.zsh tests/create.test.zsh
git commit -F - <<'MSG'
fix(create): reject unknown dash arguments instead of passing them to git

Every dash token except --ai stayed positional and reached `git worktree add` as an
option. `create app fix X --force` printed "base ref: --force" and built the worktree
from HEAD. --no-checkout made an empty one. Typos dumped git's usage after a fetch.
create now treats any -* before `--` as a usage error (exit 2), as remove already does.
A literal value that starts with '-' goes after `--`. Flags are parsed before
require_config, so a usage error never depends on config state.
MSG
```

---

### Task 5: `create` checks names, base and checkout before it asks

**Findings:** `output:create-no-arg-validation`, `journeys:create-late-validation`.

**Files:**
- Modify: `lib/cmd/create.zsh`. Add the helpers `_create_name_ok`, `_create_base_ok`, `_create_checked_out_at` and `_create_failed`. In `create_do`, record the directories it makes and remove them on failure. In `cmd_create`, add the kind/ticket loops, the dash-base check, and the base and checked-out checks after the fetch.
- Modify: `README.md`, the "워크트리 만들기" bullets and exit-code row 2.
- Test: `tests/create.test.zsh` and `tests/create_interactive.test.zsh` (append).

**Interfaces:**
- `_create_name_ok <repo_path> <kind> [ticket]` returns rc 0 or 1 and prints `invalid kind: …` or `invalid ticket: …` with a hint. It uses `git check-ref-format --branch`, and a kind must not contain `/`.
- `_create_base_ok <repo_path> <base>` returns rc 0 when `rev-parse --verify --quiet <base>^{commit}` succeeds; otherwise it prints `base not found: …` with a hint.
- `_create_checked_out_at <repo_path> <branch>` sets `REPLY` to the existing checkout that has the branch. Checkouts whose directory is missing are skipped; Task 6 handles them.
- `_create_failed <dir> <top>` runs `rmdir` up the tree while directories are empty, then dies with `failed to create worktree`.

**Behaviour:**
- Names given as arguments exit 2; names typed at a prompt are asked again.
- An explicit base that starts with `-` exits 2.
- A missing explicit base exits 1, after the fetch.
- A missing typed base is asked again.
- A local branch checked out in another existing checkout exits 1 with `cd` and `switch` hints.

- [ ] **Step 1: Write the failing tests**

```diff
diff --git a/tests/create.test.zsh b/tests/create.test.zsh
index a470c5c..e080454 100644
--- a/tests/create.test.zsh
+++ b/tests/create.test.zsh
@@ -183,4 +183,48 @@ test_create_dashdash_still_passes_a_literal_dash_ticket() {
   assert_eq "$(git -C "$HOME/wts/app/fix/-T2" branch --show-current)" "fix/-T2"
 }
 
+test_create_rejects_ill_formed_names_before_creating_anything() {
+  origin_fixture
+  local out; out="$(wt create app fix 'my ticket' -y 2>&1)"
+  assert_eq "$?" 2 space
+  assert_contains "$out" "invalid ticket: my ticket"
+  assert_contains "$out" "hint:"
+  assert_eq "${out//fetching/}" "$out" "no fetch"
+  assert_exit 2 wt create app fix .. -y
+  assert_exit 2 wt create app fix/sub T -y
+  assert_exit 2 wt create -- app -x T -y
+  assert_not_exists "$HOME/wts"
+}
+
+test_create_rejects_a_bad_base_before_creating_anything() {
+  origin_fixture
+  local out; out="$(wt create app fix T nonexistent-base 2>&1)"
+  assert_eq "$?" 1
+  assert_contains "$out" "base not found: nonexistent-base"
+  assert_not_exists "$HOME/wts"
+  out="$(wt create -- app fix T -x 2>&1)"
+  assert_eq "$?" 2 dash-base
+  assert_contains "$out" "invalid base: -x"
+  assert_not_exists "$HOME/wts"
+}
+
+test_create_reports_a_branch_checked_out_elsewhere_before_creating_anything() {
+  fixture
+  git -C "$HOME/src/app" checkout -q -b fix/HERE
+  local out; out="$(wt create app fix HERE 2>&1)"
+  assert_eq "$?" 1
+  assert_contains "$out" "fix/HERE is already checked out at $HOME/src/app"
+  assert_contains "$out" "hint:"
+  assert_not_exists "$HOME/wts"
+}
+
+test_create_removes_the_directories_it_made_when_git_fails() {
+  fixture
+  mkdir -p "$HOME/src/app/.git/refs/heads/fix"; : > "$HOME/src/app/.git/refs/heads/fix/L.lock"
+  local out; out="$(wt create app fix L main 2>&1)"
+  assert_eq "$?" 1
+  assert_contains "$out" "failed to create worktree"
+  assert_not_exists "$HOME/wts"
+}
+
 run_tests
diff --git a/tests/create_interactive.test.zsh b/tests/create_interactive.test.zsh
index 96f8a77..0b07971 100644
--- a/tests/create_interactive.test.zsh
+++ b/tests/create_interactive.test.zsh
@@ -97,4 +97,20 @@ test_eof_cancels_without_side_effects() {
   assert_not_exists "$HOME/wts"
 }
 
+test_invalid_typed_ticket_is_asked_again() {
+  fixture; answers "1" "my ticket" "T9" "" ""   # kind feature, bad ticket, ticket, base auto, confirm
+  local err; err="$(wt create app 2>&1 >/dev/null)"
+  assert_eq "$?" 0
+  assert_contains "$err" "invalid ticket: my ticket"
+  assert_dir "$HOME/wts/app/feature/T9"
+}
+
+test_invalid_typed_base_is_asked_again() {
+  fixture; answers "nope" "" ""                  # bad base, base auto, confirm
+  local err; err="$(wt create app fix B1 2>&1 >/dev/null)"
+  assert_eq "$?" 0
+  assert_contains "$err" "base not found: nope"
+  assert_dir "$HOME/wts/app/fix/B1"
+}
+
 run_tests
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zsh tests/create.test.zsh; zsh tests/create_interactive.test.zsh`

Expected: FAIL.
- `space: expected [2] got [1]`, after a fetch.
- `fix/sub T` returned 0, creating a nested worktree.
- `dash-base: expected [2] got [1]`.
- `exists $HOME/wts` four times, from leftover parent directories.
- The ref lock case printed git's raw error and left `wts/`.
- Interactively, the typed bad ticket and base reached git after `Create?` and exited 1.

- [ ] **Step 3: Implement**

```diff
diff --git a/lib/cmd/create.zsh b/lib/cmd/create.zsh
index 67be3dd..2531cd0 100644
--- a/lib/cmd/create.zsh
+++ b/lib/cmd/create.zsh
@@ -55,6 +55,53 @@ create_pick_repo() {
   repo_path="${row##*$'\t'}"
 }
 
+# _create_name_ok <repo_path> <kind> [ticket]: rc 0 when <kind>, and <kind>/<ticket> when a
+# ticket is given, can name a worktree branch; otherwise prints why on stderr.
+_create_name_ok() {
+  local repo_path="$1" kind="$2"
+  if [[ "$kind" == */* ]] || ! git -C "$repo_path" check-ref-format --branch "$kind" >/dev/null 2>&1; then
+    error "invalid kind: $kind"
+    hint "a kind is one branch-name segment without '/', e.g. fix"
+    return 1
+  fi
+  (( $# < 3 )) && return 0
+  git -C "$repo_path" check-ref-format --branch "$kind/$3" >/dev/null 2>&1 && return 0
+  error "invalid ticket: $3 ('$kind/$3' is not a valid git branch name)"
+  hint "no spaces, '..', '~', '^', ':', '?', '*', '[' or '\\'; see: git check-ref-format --help"
+  return 1
+}
+
+# _create_base_ok <repo_path> <base>: rc 0 when <base> names a commit; otherwise prints why.
+_create_base_ok() {
+  git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null && return 0
+  error "base not found: $2"
+  hint "list branches with: git -C $1 branch -a"
+  return 1
+}
+
+# _create_checked_out_at <repo_path> <branch>: REPLY = the existing checkout that has <branch>
+# checked out; rc 1 when none has.
+_create_checked_out_at() {
+  local line wt=""
+  while IFS= read -r line; do
+    case "$line" in
+      "worktree "*) wt="${line#worktree }" ;;
+      "branch refs/heads/$2") [[ -d "$wt" ]] && { REPLY="$wt"; return 0; } ;;
+    esac
+  done < <(git -C "$1" worktree list --porcelain 2>/dev/null)
+  return 1
+}
+
+# _create_failed <dir> <top>: removes <dir> and its parents up to <top> -- the directories
+# create made for the target -- while they are empty, then dies.
+_create_failed() {
+  local d="$1"
+  if [[ -n "$2" ]]; then
+    while rmdir -- "$d" 2>/dev/null && [[ "$d" != "$2" ]]; do d="${d:h}"; done
+  fi
+  die "failed to create worktree"
+}
+
 # create_do <project> <repo> <repo_path> <kind> <ticket> <base_ref> [base_label]
 # Prints the summary, adds the worktree, and prints the path as the LAST line. base_ref is
 # the raw ref handed to git; base_label is the human-facing display text (may carry the
@@ -75,13 +122,15 @@ create_do() {
     fi
     die "target path exists but is not a worktree of $repo_path: $target (remove it, or run 'workytree prune' once available)"
   fi
+  local made="" d="${target:h}"
+  while [[ ! -e "$d" ]]; do made="$d"; d="${d:h}"; done
   mkdir -p "${target:h}" || die "failed to create parent directory for $target"
   if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
     info "base ref: n/a (existing branch)"
-    git -C "$repo_path" worktree add "$target" "$branch" || die "failed to create worktree"
+    git -C "$repo_path" worktree add "$target" "$branch" || _create_failed "${target:h}" "$made"
   else
     info "base ref: $base_label"
-    git -C "$repo_path" worktree add --no-track -b "$branch" "$target" "$base_ref" || die "failed to create worktree"
+    git -C "$repo_path" worktree add --no-track -b "$branch" "$target" "$base_ref" || _create_failed "${target:h}" "$made"
   fi
   success "result: created"
   print -r -- "$target"
@@ -127,29 +176,58 @@ cmd_create() {
 
   if [[ -z "$kind" ]]; then
     prompt_available || usage_error "kind is required: workytree create [repo] <kind> <ticket> [base]"
-    prompt_choose "kind" 1 ${(f)"$(config_kinds)"}; kind="$REPLY"
+    while true; do
+      prompt_choose "kind" 1 ${(f)"$(config_kinds)"}; kind="$REPLY"
+      _create_name_ok "$repo_path" "$kind" && break
+    done
+  elif ! _create_name_ok "$repo_path" "$kind"; then
+    exit 2
   fi
   if [[ -z "$ticket" ]]; then
     prompt_available || usage_error "ticket is required: workytree create [repo] <kind> <ticket> [base]"
-    prompt_input "ticket" ""; ticket="$REPLY"
+    while true; do
+      prompt_input "ticket" ""; ticket="$REPLY"
+      _create_name_ok "$repo_path" "$kind" "$ticket" && break
+    done
+  elif ! _create_name_ok "$repo_path" "$kind" "$ticket"; then
+    exit 2
+  fi
+  if [[ "$base" == -* ]]; then
+    error "invalid base: $base"; hint "a base is a branch, tag or commit; none starts with '-'"; exit 2
   fi
 
-  local target; target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
+  local target branch
+  target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
+  branch="$(wt_branch_name "$kind" "$ticket")"
   [[ -e "$target" ]] || wt_fetch_origin "$repo_path"
   # base_ref/base_label split: see the note on create_do (R22).
   local base_ref="$base" base_label="$base"
-  if [[ -z "$base_ref" && ! -e "$target" ]] && ! git -C "$repo_path" show-ref --verify --quiet "refs/heads/$(wt_branch_name "$kind" "$ticket")"; then
-    local auto; auto="$(default_base_ref "$repo_path")" || exit $?
-    if prompt_available; then prompt_input "base branch" "$auto"; base_ref="$REPLY"; else base_ref="$auto"; fi
-    base_label="$base_ref"
-    [[ "$base_ref" == "$auto" ]] && base_label="$auto (auto-detected)"
+  if [[ ! -e "$target" ]] && ! git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
+    if [[ -n "$base_ref" ]]; then
+      _create_base_ok "$repo_path" "$base_ref" || exit 1
+    else
+      local auto; auto="$(default_base_ref "$repo_path")" || exit $?
+      base_ref="$auto"
+      if prompt_available; then
+        while true; do
+          prompt_input "base branch" "$auto"; base_ref="$REPLY"
+          _create_base_ok "$repo_path" "$base_ref" && break
+        done
+      fi
+      base_label="$base_ref"
+      [[ "$base_ref" == "$auto" ]] && base_label="$auto (auto-detected)"
+    fi
+  elif [[ ! -e "$target" ]] && _create_checked_out_at "$repo_path" "$branch"; then
+    die_with_hints "$branch is already checked out at $REPLY" \
+      "work there instead: cd $REPLY" \
+      "or free the branch first: git -C $REPLY switch <another branch>"
   fi
 
   if prompt_available && [[ ! -e "$target" ]]; then
     dim "──────────────────────────────" >&2
     print -u2 -r -- "repo:    $repo → $repo_path"
     print -u2 -r -- "target:  $target"
-    print -u2 -r -- "branch:  $(wt_branch_name "$kind" "$ticket")${base_label:+  (base: $base_label)}"
+    print -u2 -r -- "branch:  $branch${base_label:+  (base: $base_label)}"
     prompt_confirm "Create?" y || exit 130
   fi
   create_do "$project" "$repo" "$repo_path" "$kind" "$ticket" "$base_ref" "$base_label"
```

- [ ] **Step 4: README**

```diff
diff --git a/README.md b/README.md
index 747af23..02d9f15 100644
--- a/README.md
+++ b/README.md
@@ -132,6 +132,8 @@ wt config get|set|edit|path
 - 브랜치를 만들기 전에 `origin`을 fetch하므로 자동으로 고른 base(`origin/main` 등)가 항상 최신
 - `origin`이 없으면 fetch를 건너뛰고, fetch가 실패하면 경고 후 로컬 ref로 계속 진행
 - 같은 워크트리가 이미 있으면 새로 만들지 않고 재사용
+- `Create?`를 묻거나 디렉터리를 만들기 전에 값을 검사한다. kind·ticket을 git 브랜치 이름으로 쓸 수 없으면(kind에 `/`, 공백, `..` 등) 종료 코드 2, base가 없거나 브랜치가 이미 다른 곳에 체크아웃돼 있으면 1로 멈춘다. 대화형으로 입력한 값이면 다시 묻는다
+- `-`로 시작하는 값은 `--` 뒤에 쓴다: `wt create -- app fix -T2`. 그 밖의 `-`로 시작하는 인자는 모르는 플래그(종료 코드 2)
 
 ## 상태 보기
 
@@ -287,7 +289,7 @@ wt config set project.work.worktree_root ~/work/worktrees
 |---|---|
 | 0 | 성공 |
 | 1 | 일반 오류: 잘못된 인자 값(모르는 repo·프로젝트, `-B` 없이 병합 안 된 브랜치 등), 또는 유효한 설정이 이미 있어 `init`이 거부함 |
-| 2 | 사용법 오류: 인자 개수가 틀림, 모르는 플래그 |
+| 2 | 사용법 오류: 인자 개수가 틀림, 모르는 플래그, 형식이 틀린 이름(`create`의 kind·ticket·base) |
 | 3 | 설정 **파일 상태** 문제: 설정 파일 없음, 파싱 실패(중복 섹션·키, 읽을 수 없는 줄), 읽을 수 없거나 일반 파일이 아님, `[project]`에 `repo_root`·`worktree_root` 누락, `repo_root`·`worktree_root`가 상대 경로·`/`·`$HOME`의 상위 디렉터리, 설정 디렉터리에 쓸 수 없음 |
 | 130 | 대화형 질문 취소 (`q`, Esc, Ctrl-C, EOF). AI 세션 질문 취소는 제외 |
 
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zsh tests/create.test.zsh && zsh tests/create_interactive.test.zsh`

Expected: `70 passed`, `24 passed`, all with `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add lib/cmd/create.zsh README.md tests/create.test.zsh tests/create_interactive.test.zsh
git commit -F - <<'MSG'
fix(create): validate names, base and checkout before Create? and before mkdir

A ticket with a space, a ticket of "..", a kind with "/" or a missing base got through
every question and the confirmation. Then git failed with its own message and left
<worktree_root>/<repo>/<kind> behind. A branch checked out in the main checkout failed
the same way, with no hint.

Kind and ticket are checked with `git check-ref-format --branch` as soon as they are
known. A bad value is a usage error (2) when it came from the command line, and is asked
again when it was typed at a prompt. The base is verified after the fetch: exit 1, or
ask again. A branch already checked out elsewhere stops with `cd` and `switch` hints.
create_do records the parent directories it creates and removes the empty ones when
`git worktree add` fails. --end-of-options is not used, so git < 2.24 keeps working.
MSG
```

---

### Task 6: `create` resolves the branch source before the summary

**Findings:** `journeys:create-ignores-remote-branch`, `journeys:create-existing-branch-summary`, `critic:manual-delete-recovery-dead-end`, `output:create-stale-prune-hint`, `journeys:orphan-target-stale-hint`, `critic:branch-identity-drift` (create half).

**Files:**
- Modify: `lib/cmd/create.zsh`. `_wt_worktree_is_registered` is replaced by `_wt_registered_branch`. `create_do` executes a resolved `<source>`. The middle of `cmd_create` is replaced: target classification, fetch, source, base and summary.
- Modify: `README.md`, the "워크트리 만들기" bullets.
- Test: `tests/create.test.zsh`. Three tests are rewritten to the new messages: the stale directory, the stale file and the missing-but-registered worktree. Five tests are appended.

**Interfaces:**
- `_wt_registered_branch <repo_path> <target>` returns rc 0 when the target is registered, even if its directory is gone. It sets `REPLY` to the branch checked out there, or empty when detached. Paths are compared after `:A`, which on macOS also folds a case-variant ticket to the on-disk name.
- `create_do <project> <repo> <repo_path> <kind> <ticket> <source> <base_ref> [base_label]`, where `<source>` is `reuse`, `local`, `remote` or `new`. It has one caller.

**Resolution, in order:**

| Target state | Source | Summary `branch:` line | Notes |
|---|---|---|---|
| registered, dir exists | reuse | (no summary) | prints `checked out: <b>`; warns if not the ticket branch |
| registered, dir gone | — | — | exit 1, hint `workytree prune <repo>` |
| exists, not registered | — | — | exit 1, "move or delete it", or a prune hint when it holds only IDE/OS files |
| free, local branch exists | local | `(existing branch[; base ignored])` | checked-out check; a given base warns |
| free, only `origin/<b>` | remote | `(existing remote branch origin/<b>)` | no base question; `--track -b`; a given base warns |
| free, neither | new | `(base: <label>)` | base asked or verified |

- [ ] **Step 1: Write the failing tests**

```diff
diff --git a/tests/create.test.zsh b/tests/create.test.zsh
index e080454..aeabbea 100644
--- a/tests/create.test.zsh
+++ b/tests/create.test.zsh
@@ -67,38 +67,39 @@ test_create_unknown_repo_outside_project() {
   assert_exit 1 wt create ghost fix T
 }
 
-# R21: a stale plain directory sitting at the target path is not a worktree and must not be
-# reported as "reused" -- create_do has to verify the path is actually registered against
-# $repo_path via `git worktree list`, not just check -e.
 test_create_stale_plain_dir_at_target_is_not_reused() {
   fixture
-  mkdir -p "$HOME/wts/app/fix/STALE1"
-  local out; out="$(wt create app fix STALE1 main 2>&1)"
+  mkdir -p "$HOME/wts/app/fix/ORPH"; print n > "$HOME/wts/app/fix/ORPH/n.txt"
+  local out; out="$(wt create app fix ORPH main 2>&1)"
   assert_eq "$?" 1
-  assert_contains "$out" "workytree: target path exists but is not a worktree of"
-  assert_contains "$out" "STALE1"
+  assert_contains "$out" "workytree: target path already exists and is not a worktree: $HOME/wts/app/fix/ORPH"
+  assert_contains "$out" "move or delete it, then retry"
+  assert_eq "${out//once available/}" "$out" "no stale wording"
+  mkdir -p "$HOME/wts/app/fix/IDE/.idea"; : > "$HOME/wts/app/fix/IDE/.idea/ws.xml"
+  out="$(wt create app fix IDE main 2>&1)"
+  assert_eq "$?" 1 cruft-only
+  assert_contains "$out" "workytree prune app"
 }
 
-# R21, inverse-of-above: a plain FILE at the target is the same bug, not just a directory.
 test_create_stale_plain_file_at_target_is_not_reused() {
   fixture
   mkdir -p "$HOME/wts/app/fix"
   print "junk" > "$HOME/wts/app/fix/STALE2"
   local out; out="$(wt create app fix STALE2 main 2>&1)"
   assert_eq "$?" 1
-  assert_contains "$out" "workytree: target path exists but is not a worktree of"
+  assert_contains "$out" "already exists and is not a worktree"
+  assert_eq "${out//workytree prune/}" "$out" "prune does not remove files"
 }
 
-# R21: pins the CURRENT behavior for the inverse case (a worktree git still has registered,
-# but whose directory was deleted from disk) so a later change cannot silently regress it into
-# something worse than a clearly-diagnosed, workytree-prefixed failure.
-test_create_missing_but_registered_worktree_fails_loudly() {
+test_create_after_a_manual_delete_points_to_prune() {
   fixture
   wt create app fix GONE main >/dev/null
   rm -rf "$HOME/wts/app/fix/GONE"
   local out; out="$(wt create app fix GONE main 2>&1)"
   assert_eq "$?" 1
-  assert_contains "$out" "workytree: failed to create worktree"
+  assert_contains "$out" "still registered at $HOME/wts/app/fix/GONE"
+  assert_contains "$out" "workytree prune app"
+  assert_eq "${out//missing but already registered/}" "$out" "no raw git error"
 }
 
 # R22: a base ref containing a space must never be silently truncated by splitting a display
@@ -227,4 +228,62 @@ test_create_removes_the_directories_it_made_when_git_fails() {
   assert_not_exists "$HOME/wts"
 }
 
+# remote_branch_fixture <branch>: <branch> exists on origin only, one commit ahead of main.
+remote_branch_fixture() {
+  origin_fixture
+  git -C "$HOME/other" switch -q -c "$1"
+  print w > "$HOME/other/w.txt"; git -C "$HOME/other" add -A; git -C "$HOME/other" commit -qm teammate
+  git -C "$HOME/other" push -q origin "$1"
+}
+
+test_create_tracks_a_branch_that_exists_only_on_origin() {
+  remote_branch_fixture fix/PROJ-9
+  local out w="$HOME/wts/app/fix/PROJ-9"
+  out="$(wt create app fix PROJ-9 -y 2>&1)"
+  assert_eq "$?" 0
+  assert_contains "$out" "existing remote branch origin/fix/PROJ-9"
+  assert_eq "$(git -C "$w" rev-parse HEAD)" "$(git -C "$HOME/other" rev-parse HEAD)" "teammate's commit"
+  assert_eq "$(git -C "$w" rev-parse --abbrev-ref '@{upstream}')" origin/fix/PROJ-9 tracking
+}
+
+test_create_remote_branch_asks_no_base_and_ignores_one_given() {
+  remote_branch_fixture fix/PROJ-9
+  print > "$TMP_ROOT/answers"                     # Create?: Enter
+  local out; out="$(WORKYTREE_PROMPT_INPUT="$TMP_ROOT/answers" wt create app fix PROJ-9 main 2>&1)"
+  assert_eq "$?" 0 "the one answer went to Create?"
+  assert_contains "$out" "branch:  fix/PROJ-9  (existing remote branch origin/fix/PROJ-9)"
+  assert_contains "$out" "base main ignored"
+}
+
+test_create_summary_says_an_existing_branch_ignores_the_base() {
+  fixture
+  git -C "$HOME/src/app" branch fix/EX3
+  print > "$TMP_ROOT/answers"
+  local out; out="$(WORKYTREE_PROMPT_INPUT="$TMP_ROOT/answers" wt create app fix EX3 origin/does-not-matter 2>&1)"
+  assert_eq "$?" 0
+  assert_contains "$out" "branch:  fix/EX3  (existing branch; base ignored)"
+  assert_contains "$out" "base origin/does-not-matter ignored"
+}
+
+test_create_reuse_reports_the_checked_out_branch() {
+  fixture
+  wt create app fix RU main >/dev/null
+  git -C "$HOME/wts/app/fix/RU" switch -q -c experiment
+  local out; out="$(wt create app fix RU 2>&1)"
+  assert_eq "$?" 0
+  assert_contains "$out" "checked out: experiment"
+  assert_contains "$out" "not on its ticket branch fix/RU"
+  assert_eq "${out##*$'\n'}" "$HOME/wts/app/fix/RU"
+}
+
+# Asserts nothing on a case-sensitive filesystem, where proj-1 is a different, missing worktree.
+test_create_reuse_names_the_registered_branch_for_a_case_variant_ticket() {
+  fixture
+  wt create app fix PROJ-1 main >/dev/null
+  [[ -d "$HOME/wts/app/fix/proj-1" ]] || return 0
+  local out; out="$(wt create app fix proj-1 2>&1)"
+  assert_contains "$out" "checked out: fix/PROJ-1"
+  assert_contains "$out" "not on its ticket branch fix/proj-1"
+}
+
 run_tests
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zsh tests/create.test.zsh`

Expected: FAIL.
- The remote-only branch was created from `origin/main`: `teammate's commit` and `tracking: expected [origin/fix/PROJ-9] got []`.
- The summary had `(base: …)`.
- The stale-directory messages still say "once available".
- The manual delete printed git's "missing but already registered".
- Reuse printed nothing about `experiment`.

- [ ] **Step 3: Implement**

```diff
diff --git a/lib/cmd/create.zsh b/lib/cmd/create.zsh
index 2531cd0..7f1bf7c 100644
--- a/lib/cmd/create.zsh
+++ b/lib/cmd/create.zsh
@@ -1,24 +1,16 @@
-# _wt_worktree_is_registered <repo_path> <target>: true if <target> is registered as a
-# worktree of <repo_path> in `git worktree list`. Scoping the check to $repo_path (rather
-# than e.g. `git -C "$target" rev-parse --git-dir`) directly answers "is this a worktree of
-# THIS repo", which is what the reuse decision needs (R21). Both sides are canonicalized
-# with :A, matching the comparison convention already used in lib/resolve.zsh.
-#
-# The loop reads via process substitution rather than piping into the while (`cmd | while
-# ...; done`), and tracks the match in an explicit flag rather than the loop's own exit
-# status: a pipe's while runs in a subshell, and `git worktree list --porcelain` always ends
-# each entry (and the whole listing) with non-matching lines (HEAD/branch/blank) that fall
-# through to `continue` -- and `continue` resets $? to 0, so the seemingly-natural "trust the
-# loop's exit status" version reports a match even when none occurred.
-_wt_worktree_is_registered() {
-  local repo_path="$1" target="$2" want line wtpath
+# _wt_registered_branch <repo_path> <target>: rc 0 when <target> is registered as a worktree of
+# <repo_path>, even if its directory is gone; REPLY = the branch it has checked out, empty when
+# detached.
+_wt_registered_branch() {
+  local want="${2:A}" line wt
   local -i found=0
-  want="${target:A}"
+  REPLY=""
   while IFS= read -r line; do
-    [[ "$line" == worktree\ * ]] || continue
-    wtpath="${line#worktree }"
-    [[ "${wtpath:A}" == "$want" ]] && { found=1; break; }
-  done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null)
+    case "$line" in
+      "worktree "*) (( found )) && break; wt="${line#worktree }"; [[ "${wt:A}" == "$want" ]] && found=1 ;;
+      "branch refs/heads/"*) (( found )) && REPLY="${line#branch refs/heads/}" ;;
+    esac
+  done < <(git -C "$1" worktree list --porcelain 2>/dev/null)
   (( found ))
 }
 
@@ -102,36 +94,40 @@ _create_failed() {
   die "failed to create worktree"
 }
 
-# create_do <project> <repo> <repo_path> <kind> <ticket> <base_ref> [base_label]
-# Prints the summary, adds the worktree, and prints the path as the LAST line. base_ref is
-# the raw ref handed to git; base_label is the human-facing display text (may carry the
-# "(auto-detected)" suffix) -- kept apart so a ref is never reconstructed by splitting a
+# create_do <project> <repo> <repo_path> <kind> <ticket> <source> <base_ref> [base_label]
+# <source> is cmd_create's resolution: reuse|local|remote|new. Prints the path as the LAST line.
+# base_ref is the raw ref handed to git; base_label is the human-facing display text (may carry
+# the "(auto-detected)" suffix) -- kept apart so a ref is never reconstructed by splitting a
 # label string (R22).
 create_do() {
-  local project="$1" repo="$2" repo_path="$3" kind="$4" ticket="$5" base_ref="$6" base_label="${7:-$6}"
+  local project="$1" repo="$2" repo_path="$3" kind="$4" ticket="$5" source="$6" base_ref="$7" base_label="${8:-$7}"
   local target branch
   target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
   branch="$(wt_branch_name "$kind" "$ticket")"
   info "source repo: $repo_path"
   info "target path: $target"
   info "branch name: $branch"
-  if [[ -e "$target" ]]; then
-    if _wt_worktree_is_registered "$repo_path" "$target"; then
-      info "base ref: n/a (existing worktree)"
-      success "result: reused"; print -r -- "$target"; return 0
-    fi
-    die "target path exists but is not a worktree of $repo_path: $target (remove it, or run 'workytree prune' once available)"
+  if [[ "$source" == reuse ]]; then
+    _wt_registered_branch "$repo_path" "$target"
+    info "checked out: ${REPLY:-(detached HEAD)}"
+    [[ "$REPLY" == "$branch" ]] || warn "the worktree is not on its ticket branch $branch"
+    info "base ref: n/a (existing worktree)"
+    success "result: reused"; print -r -- "$target"; return 0
   fi
   local made="" d="${target:h}"
   while [[ ! -e "$d" ]]; do made="$d"; d="${d:h}"; done
   mkdir -p "${target:h}" || die "failed to create parent directory for $target"
-  if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
-    info "base ref: n/a (existing branch)"
-    git -C "$repo_path" worktree add "$target" "$branch" || _create_failed "${target:h}" "$made"
-  else
-    info "base ref: $base_label"
-    git -C "$repo_path" worktree add --no-track -b "$branch" "$target" "$base_ref" || _create_failed "${target:h}" "$made"
-  fi
+  case "$source" in
+    local)
+      info "base ref: n/a (existing branch)"
+      git -C "$repo_path" worktree add "$target" "$branch" || _create_failed "${target:h}" "$made" ;;
+    remote)
+      info "base ref: n/a (existing remote branch origin/$branch)"
+      git -C "$repo_path" worktree add --track -b "$branch" "$target" "origin/$branch" || _create_failed "${target:h}" "$made" ;;
+    *)
+      info "base ref: $base_label"
+      git -C "$repo_path" worktree add --no-track -b "$branch" "$target" "$base_ref" || _create_failed "${target:h}" "$made" ;;
+  esac
   success "result: created"
   print -r -- "$target"
 }
@@ -196,40 +192,59 @@ cmd_create() {
     error "invalid base: $base"; hint "a base is a branch, tag or commit; none starts with '-'"; exit 2
   fi
 
-  local target branch
+  local target branch source=new
   target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
   branch="$(wt_branch_name "$kind" "$ticket")"
-  [[ -e "$target" ]] || wt_fetch_origin "$repo_path"
+  if _wt_registered_branch "$repo_path" "$target"; then
+    [[ -e "$target" ]] || die_with_hints "a worktree is still registered at $target, but its directory is gone" \
+      "clean up git's record, then retry: workytree prune $repo"
+    source=reuse
+  elif [[ -e "$target" ]]; then
+    local stale_hint="move or delete it, then retry"
+    [[ -d "$target" ]] && dir_is_cruft_only "$target" && stale_hint="it holds only IDE/OS files; remove it with: workytree prune $repo"
+    die_with_hints "target path already exists and is not a worktree: $target" "$stale_hint"
+  else
+    wt_fetch_origin "$repo_path"
+    if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then source=local
+    elif git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/$branch"; then source=remote; fi
+  fi
   # base_ref/base_label split: see the note on create_do (R22).
-  local base_ref="$base" base_label="$base"
-  if [[ ! -e "$target" ]] && ! git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
-    if [[ -n "$base_ref" ]]; then
-      _create_base_ok "$repo_path" "$base_ref" || exit 1
-    else
-      local auto; auto="$(default_base_ref "$repo_path")" || exit $?
-      base_ref="$auto"
-      if prompt_available; then
-        while true; do
-          prompt_input "base branch" "$auto"; base_ref="$REPLY"
-          _create_base_ok "$repo_path" "$base_ref" && break
-        done
+  local base_ref="$base" base_label="$base" plan
+  case "$source" in
+    local)
+      _create_checked_out_at "$repo_path" "$branch" && die_with_hints "$branch is already checked out at $REPLY" \
+        "work there instead: cd $REPLY" \
+        "or free the branch first: git -C $REPLY switch <another branch>"
+      [[ -n "$base" ]] && warn "base $base ignored: branch $branch already exists"
+      plan="existing branch${base:+; base ignored}" ;;
+    remote)
+      [[ -n "$base" ]] && warn "base $base ignored: branch $branch already exists on origin"
+      plan="existing remote branch origin/$branch" ;;
+    new)
+      if [[ -n "$base_ref" ]]; then
+        _create_base_ok "$repo_path" "$base_ref" || exit 1
+      else
+        local auto; auto="$(default_base_ref "$repo_path")" || exit $?
+        base_ref="$auto"
+        if prompt_available; then
+          while true; do
+            prompt_input "base branch" "$auto"; base_ref="$REPLY"
+            _create_base_ok "$repo_path" "$base_ref" && break
+          done
+        fi
+        base_label="$base_ref"
+        [[ "$base_ref" == "$auto" ]] && base_label="$auto (auto-detected)"
       fi
-      base_label="$base_ref"
-      [[ "$base_ref" == "$auto" ]] && base_label="$auto (auto-detected)"
-    fi
-  elif [[ ! -e "$target" ]] && _create_checked_out_at "$repo_path" "$branch"; then
-    die_with_hints "$branch is already checked out at $REPLY" \
-      "work there instead: cd $REPLY" \
-      "or free the branch first: git -C $REPLY switch <another branch>"
-  fi
+      plan="base: $base_label" ;;
+  esac
 
-  if prompt_available && [[ ! -e "$target" ]]; then
+  if prompt_available && [[ "$source" != reuse ]]; then
     dim "──────────────────────────────" >&2
     print -u2 -r -- "repo:    $repo → $repo_path"
     print -u2 -r -- "target:  $target"
-    print -u2 -r -- "branch:  $branch${base_label:+  (base: $base_label)}"
+    print -u2 -r -- "branch:  $branch  ($plan)"
     prompt_confirm "Create?" y || exit 130
   fi
-  create_do "$project" "$repo" "$repo_path" "$kind" "$ticket" "$base_ref" "$base_label"
+  create_do "$project" "$repo" "$repo_path" "$kind" "$ticket" "$source" "$base_ref" "$base_label"
   ai_maybe_offer "$project" "$want_ai"
 }
```

- [ ] **Step 4: README**

```diff
diff --git a/README.md b/README.md
index 02d9f15..45423a4 100644
--- a/README.md
+++ b/README.md
@@ -131,7 +131,9 @@ wt config get|set|edit|path
 
 - 브랜치를 만들기 전에 `origin`을 fetch하므로 자동으로 고른 base(`origin/main` 등)가 항상 최신
 - `origin`이 없으면 fetch를 건너뛰고, fetch가 실패하면 경고 후 로컬 ref로 계속 진행
-- 같은 워크트리가 이미 있으면 새로 만들지 않고 재사용
+- 같은 워크트리가 이미 있으면 새로 만들지 않고 재사용. ticket 브랜치가 아닌 브랜치가 체크아웃돼 있으면 실제 브랜치를 보여 주고 경고한다
+- 브랜치를 어디서 가져올지 요약에 보여 준다: 로컬에 있으면 그 브랜치(base는 무시), `origin`에만 있으면 그 브랜치를 추적하는 로컬 브랜치(base를 묻지 않음), 둘 다 없으면 base에서 새 브랜치
+- 워크트리 디렉터리를 손으로 지웠다면 git 기록이 남아 있으므로 `workytree prune <repo>`를 먼저 실행하라고 안내하고 멈춘다
 - `Create?`를 묻거나 디렉터리를 만들기 전에 값을 검사한다. kind·ticket을 git 브랜치 이름으로 쓸 수 없으면(kind에 `/`, 공백, `..` 등) 종료 코드 2, base가 없거나 브랜치가 이미 다른 곳에 체크아웃돼 있으면 1로 멈춘다. 대화형으로 입력한 값이면 다시 묻는다
 - `-`로 시작하는 값은 `--` 뒤에 쓴다: `wt create -- app fix -T2`. 그 밖의 `-`로 시작하는 인자는 모르는 플래그(종료 코드 2)
 
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zsh tests/create.test.zsh && zsh tests/create_interactive.test.zsh && zsh tests/shell.test.zsh && zsh tests/agent.test.zsh`

Expected: `92 passed`, `24 passed`, `58 passed`, `75 passed`, all with `0 failed`. On a case-sensitive filesystem the case-variant test returns early, so `create.test.zsh` reports 2 fewer passes there (90).

- [ ] **Step 6: Commit**

```bash
git add lib/cmd/create.zsh README.md tests/create.test.zsh
git commit -F - <<'MSG'
fix(create): decide reuse/local/remote/new before asking, and show it

create ignored a branch that existed only on origin. It made a new branch from the base
that had diverged from the teammate's work, and later pushes were rejected. An existing
local branch showed "(base: X)" in the summary and then ignored X. A worktree deleted by
hand failed after Create? with git's "missing but already registered". A foreign
directory got "run 'workytree prune' once available", which prune did not fix. Reuse
reported the ticket branch even when another branch was checked out.

cmd_create now resolves the source before the summary:
- reuse prints the checked-out branch and warns on a mismatch;
- a registered but missing target stops with a prune hint;
- a foreign target stops with "move or delete it", or a prune hint when it holds only
  cruft;
- a local branch says "existing branch";
- origin/<b> alone is checked out with --track and no base question;
- otherwise a new branch is made from the base.
A base given for an existing branch warns that it is ignored. create_do only carries out
the resolved source.
MSG
```

---

### Task 7: `repo add --project` takes effect

**Findings:** `critic:repo-add-project-flag-ignored`, `automation:repo-add-missing-value-raw-error`.

**Files:**
- Modify: `lib/cmd/repo.zsh`, the `add` branch of `cmd_repo`.
- Test: `tests/manage.test.zsh` (append).

**Interfaces:** `repo add` starts from `project="$WT_PROJECT_OPT"`. `parse_global_opts` (bin/workytree:68-69) has always consumed `--project` first, so the local `--project` arm could never run and is removed. A missing or empty `--name` value is `usage_error "--name requires a value"` (exit 2).

- [ ] **Step 1: Write the failing tests**

```diff
diff --git a/tests/manage.test.zsh b/tests/manage.test.zsh
index a020fbb..126a3af 100644
--- a/tests/manage.test.zsh
+++ b/tests/manage.test.zsh
@@ -248,4 +248,23 @@ test_repo_add_notes_symlink_derived_name() {
   assert_eq "${out//derived from the resolved target/}" "$out" "explicit --name must not trigger the symlink note"
 }
 
+test_repo_add_registers_under_the_given_project() {
+  make_repo "$HOME/elsewhere/lib1"; make_repo "$HOME/elsewhere/lib2"
+  wt project add me ~/src ~/wts >/dev/null; wt project add second ~/src2 ~/wts2 >/dev/null
+  assert_exit 0 wt repo add ~/elsewhere/lib1 --project second
+  assert_eq "$(wt config get repo.lib1.project)" second space-form
+  assert_exit 0 wt repo add ~/elsewhere/lib2 --project=second
+  assert_eq "$(wt config get repo.lib2.project)" second equals-form
+  local out; out="$(wt repo add ~/elsewhere/lib1 --name lib3 --project ghost 2>&1)"
+  assert_eq "$?" 1
+  assert_contains "$out" "unknown project: ghost"
+}
+
+test_repo_add_name_without_a_value_is_a_usage_error() {
+  make_repo "$HOME/elsewhere/lib1"; wt project add me ~/src ~/wts >/dev/null
+  local out; out="$(wt repo add ~/elsewhere/lib1 --name 2>&1)"
+  assert_eq "$?" 2
+  assert_eq "$out" "workytree: --name requires a value"
+}
+
 run_tests
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zsh tests/manage.test.zsh`

Expected: FAIL.
- `space-form: expected [second] got [me]` and the same for `equals-form`.
- `expected [2] got [1]`.
- `got [cmd_repo:21: 1: --name requires a value]`.
- The `--project ghost` assertion already passes, through the global check in resolve.zsh:90.

- [ ] **Step 3: Implement**

```diff
diff --git a/lib/cmd/repo.zsh b/lib/cmd/repo.zsh
index c95b95e..073a8f1 100644
--- a/lib/cmd/repo.zsh
+++ b/lib/cmd/repo.zsh
@@ -27,11 +27,10 @@ cmd_repo() {
       require_config
       # R16: never name a local `path` -- it silently destroys $PATH for the rest of this
       # scope (even `local path`), taking `git`/`find` with it. Use repo_path throughout.
-      local repo_path="" name="" project=""
+      local repo_path="" name="" project="$WT_PROJECT_OPT"
       while (( $# )); do
         case "$1" in
-          --name)    shift; name="${1:?--name requires a value}" ;;
-          --project) shift; project="${1:?--project requires a value}" ;;
+          --name)    shift; [[ -n "${1:-}" ]] || usage_error "--name requires a value"; name="$1" ;;
           -*)        usage_error "unknown flag: $1" ;;
           *)         [[ -z "$repo_path" ]] || usage_error "usage: workytree repo add <path> [--name n] [--project p]"; repo_path="$1" ;;
         esac; shift
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zsh tests/manage.test.zsh`

Expected: `88 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/repo.zsh tests/manage.test.zsh
git commit -F - <<'MSG'
fix(repo): register `repo add --project p` under p

parse_global_opts consumes --project before cmd_repo sees its arguments, and cmd_repo
never read WT_PROJECT_OPT. The documented `repo add <path> --project second` registered
the repo under the default project with exit 0. The existing test passed only because
--project ghost is rejected globally, and --project me is the default anyway. add now
starts from WT_PROJECT_OPT, and the unreachable local arm is gone. A missing --name value
is a workytree usage error (2), not zsh's raw ${1:?} message (1).
MSG
```

---

### Task 8: Read whole escape sequences; pty test helper

**Findings:** `prompts:modifier-csi-digit-select`, `prompts:split-escape-timeout`, `prompts:prompt-tests-blind-spots`.

**Files:**
- Modify: `lib/prompt.zsh`, `_prompt_key`.
- Modify: `tests/helpers.zsh`. It gains the zpty helper block of the Phase 1 plan (its Task 1, Step 3), copied byte for byte and inserted where Phase 1 puts it, before `wt() {` (Review Focus 8). `setup_env` now unsets `EDITOR VISUAL`.
- Test: `tests/prompt.test.zsh`. `pty_script` is added, `tty_input` is rebuilt on it, file-fed decoder tests are added, and pty tests are added.

**Interfaces:**
- Phase 1's helpers (tests only):
  - `pty_start [code]`: `zsh -d -i -c <code>` on a pty; `$HOME/.zshrc` sources the wrapper.
  - `pty_wait <text> [tenths=100]`: rc 1 if `<text>` has not appeared by then.
  - `pty_send <bytes>`: raw bytes. Callers expand escapes with `printf '%b'` or `$'…'`.
  - `pty_finish [tenths=200]`: waits for the shell to exit, then closes the pty. On timeout it kills the process tree.
  - `pty_run <code>`: not used here.
- `pty_script <file>`, in `prompt.test.zsh`: `pty_start "stty cols 80 rows 24; PATH=/usr/bin:/bin exec zsh -f <file>"`. ZLE draws no prompt at width 0, and the PATH keeps fzf out.
- `_prompt_key` now sets `KEY=''` for any recognised sequence that is not an arrow:
  - CSI, read up to its final byte: `\e[1;2B`, `\e[1;5B` and `\e[1;2C` are arrows; `\e[15~` (F5) and the like are ignored.
  - SS3 (`\eO<x>`).
  - Alt+key (`\eb`).
- A lone Esc is whatever has nothing following it within `KEYTIMEOUT`, default 40, that is 0.4 s. The old wait was 0.05 s.

- [ ] **Step 1: Write the failing tests**

```diff
diff --git a/tests/helpers.zsh b/tests/helpers.zsh
index ac02b07..ba0d28a 100644
--- a/tests/helpers.zsh
+++ b/tests/helpers.zsh
@@ -23,7 +23,7 @@ setup_env() {
   mkdir -p "$HOME" "$XDG_CONFIG_HOME"
   export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
   export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
-  unset WORKYTREE_PROMPT_INPUT WORKYTREE_PROMPT_KEYS WORKYTREE_CONFIG WORKYTREE_ALIAS ZDOTDIR
+  unset WORKYTREE_PROMPT_INPUT WORKYTREE_PROMPT_KEYS WORKYTREE_CONFIG WORKYTREE_ALIAS ZDOTDIR EDITOR VISUAL
   cd "$TMP_ROOT"
 }
 teardown_env() { cd /; [[ -n "$TMP_ROOT" ]] && rm -rf "$TMP_ROOT"; }
@@ -38,6 +38,58 @@ make_repo() {
 
 write_config() { mkdir -p "$XDG_CONFIG_HOME/workytree"; cat > "$XDG_CONFIG_HOME/workytree/config"; }
 
+# pty_start [code]: an interactive zsh on a pseudo-terminal, so stdin, stdout and /dev/tty are
+# all a terminal, with $HOME/.zshrc sourcing the wrapper. With <code> it runs `zsh -i -c <code>`;
+# without, a line-mode shell (no ZLE) that runs whatever pty_send types.
+typeset -g WT_PTY_OUT=''
+pty_start() {
+  zmodload zsh/zpty
+  print -r -- "print -r -- \$\$ > '$HOME/.pty.pid'; export TMPDIR='$TMP_ROOT'; source '$WT_TEST_ROOT/shell/workytree.zsh'" > "$HOME/.zshrc"
+  WT_PTY_OUT=''
+  if (( $# )); then
+    zpty -b WT_PTY "ZDOTDIR=${(q)HOME} TERM=xterm-256color zsh -d -i -c ${(q)1}"
+  else
+    zpty -b WT_PTY "ZDOTDIR=${(q)HOME} TERM=xterm-256color zsh -d -i +Z"
+  fi
+}
+# No 2>/dev/null on zpty builtins: zpty -d then closes the saved stderr, and every later
+# FAIL line of the test file goes nowhere.
+_pty_drain() { local chunk; while zpty -r -t WT_PTY chunk; do WT_PTY_OUT+="$chunk"; done; }
+# pty_wait <text> [tenths=100]: rc 1 if <text> has not appeared by then.
+pty_wait() {
+  local -i i
+  for (( i = 0; i < ${2:-100}; i++ )); do
+    _pty_drain
+    [[ "$WT_PTY_OUT" == *"$1"* ]] && return 0
+    sleep 0.1
+  done
+  return 1
+}
+pty_send() { zpty -w -n WT_PTY "$1"; }
+_pty_kill_tree() { local c; for c in $(pgrep -P "$1"); do _pty_kill_tree "$c"; done; kill -9 "$1" 2>/dev/null; }
+# pty_finish [tenths=200]: waits for the shell to exit and leaves the transcript, CRs removed,
+# in WT_PTY_OUT. Call it in the shell that ran pty_start, not in a $(...): zpty cannot watch a
+# child of another process. A shell still running at the deadline is killed with everything it
+# started (zpty -d alone waits on an fzf that ignores SIGHUP), and the transcript ends in
+# "[pty timed out]".
+pty_finish() {
+  local -i i
+  for (( i = 0; i < ${1:-200}; i++ )); do
+    _pty_drain
+    zpty -t WT_PTY || break
+    sleep 0.1
+  done
+  if zpty -t WT_PTY; then
+    WT_PTY_OUT+=$'\n[pty timed out]'
+    [[ -s "$HOME/.pty.pid" ]] && _pty_kill_tree "$(<"$HOME/.pty.pid")"
+  fi
+  _pty_drain
+  zpty -d WT_PTY
+  WT_PTY_OUT="${WT_PTY_OUT//$'\r'/}"
+}
+# pty_run <code>: pty_start <code>, then pty_finish; prints the transcript.
+pty_run() { pty_start "$1"; pty_finish; print -r -- "$WT_PTY_OUT"; }
+
 wt() { "$WT_BIN" "$@" < /dev/null; }
 
 assert_eq() {
diff --git a/tests/prompt.test.zsh b/tests/prompt.test.zsh
index 3dc8ca9..e6b7887 100644
--- a/tests/prompt.test.zsh
+++ b/tests/prompt.test.zsh
@@ -79,21 +79,20 @@ test_line_mode_is_unchanged_without_keys() {
   assert_eq "$(choose 0 a b c)" "b"
 }
 
+# pty_script <file>: `zsh -f <file>` under pty_start. A zpty starts 0 columns wide, and ZLE draws
+# no prompt at width 0. PATH=/usr/bin:/bin keeps fzf out, so the built-in menus run.
+pty_script() { pty_start "stty cols 80 rows 24; PATH=/usr/bin:/bin exec ${(q)commands[zsh]} -f ${(q)1}"; }
+
 # tty_input <keys> [default] [setup]: prompt_input on a real pseudo-terminal, fed <keys>; prints REPLY.
 tty_input() {
-  zmodload zsh/zpty
-  local out="$TMP_ROOT/tty.out" script="$TMP_ROOT/tty.zsh" screen s=''
-  local -i i
+  local out="$TMP_ROOT/tty.out"
   rm -f "$out"
-  # A zpty starts 0 columns wide, and ZLE draws no prompt at width 0.
-  print -r -- "stty cols 80; ${3:-}; source ${(q)WT_TEST_ROOT}/lib/ui.zsh; source ${(q)WT_TEST_ROOT}/lib/prompt.zsh
-    prompt_input ticket ${(q)2:-}; print -r -- \"\$REPLY\" > ${(q)out}" > "$script"
-  zpty wt zsh -f "${(q)script}"
-  for (( i = 0; i < 50; i++ )); do zpty -r -t wt screen && s+="$screen"; [[ "$s" == *ticket* ]] && break; sleep 0.1; done
-  zpty -w -n wt "$(printf '%b' "$1")"
-  # Without draining the pty here, the child never writes $out.
-  for (( i = 0; i < 50; i++ )); do [[ -s $out ]] && break; zpty -r -t wt screen; sleep 0.1; done
-  zpty -d wt
+  print -r -- "${3:-}; source ${(q)WT_TEST_ROOT}/lib/ui.zsh; source ${(q)WT_TEST_ROOT}/lib/prompt.zsh
+    prompt_input ticket ${(q)2:-}; print -r -- \"\$REPLY\" > ${(q)out}" > "$TMP_ROOT/tty.zsh"
+  pty_script "$TMP_ROOT/tty.zsh"
+  pty_wait ticket 50
+  pty_send "$(printf '%b' "$1")"
+  pty_finish 50
   [[ -s $out ]] && print -r -- "$(<$out)"
 }
 
@@ -119,4 +118,44 @@ test_input_prompt_text_is_never_expanded() {
   assert_not_exists "$TMP_ROOT/pwned"
 }
 
+test_choose_ignores_modified_arrows_and_function_keys() {
+  keys '\e[1;2B\e[1;5B\n'; assert_eq "$(choose 0 a b c)" "c" "shift/ctrl+down move like down"
+  keys '\e[15~\n';         assert_eq "$(choose 0 a b c d e)" "a" "F5 neither selects nor moves"
+  keys '\eb\n';            assert_eq "$(choose 0 a b c)" "a" "Option+Left (Esc b) neither cancels nor moves"
+  keys '\eOB\n';           assert_eq "$(choose 0 a b c)" "b" "SS3 down"
+}
+
+test_confirm_ignores_function_keys() {
+  keys '\e[15~\e[1;2C\n'; assert_eq "$(confirm_rc n)" 0 "F5 does not answer; shift+right toggles"
+}
+
+# tty_widgets <choose keys> [confirm keys]: prompt_choose a b c, then prompt_confirm (default
+# Yes), on a real terminal; "|" in <choose keys> pauses 0.15 s. Prints "<choice> <confirm rc>
+# <modes restored 0|1>", or "- <rc>" when the menu exited. Only icanon/echo/isig are compared:
+# macOS adds PENDIN to `stty -g` whenever canonical mode comes back.
+tty_widgets() {
+  local out="$TMP_ROOT/w.out" part
+  rm -f "$out"
+  print -r -- "source ${(q)WT_TEST_ROOT}/lib/ui.zsh; source ${(q)WT_TEST_ROOT}/lib/prompt.zsh
+    modes() { stty -a | tr ' ' '\\n' | grep -E '^-?(icanon|echo|isig)\$' | sort; }
+    before=\$(modes)
+    choice=\$( prompt_choose pick 0 a b c; print -r -- \$REPLY ) || { print -r -- \"- \$?\" > ${(q)out}; exit; }
+    ( prompt_confirm proceed y ); rc=\$?
+    [[ \$before == \$(modes) ]]; print -r -- \"\$choice \$rc \$?\" > ${(q)out}" > "$TMP_ROOT/w.zsh"
+  pty_script "$TMP_ROOT/w.zsh"
+  pty_wait pick 50
+  for part in "${(@s:|:)1}"; do pty_send "$(printf '%b' "$part")"; sleep 0.15; done
+  pty_wait proceed 50 && sleep 0.3 && pty_send "${2:-n}"
+  pty_finish 50
+  [[ -s $out ]] && print -r -- "$(<$out)"
+}
+
+test_split_escape_sequence_is_still_an_arrow() {
+  assert_eq "$(tty_widgets '\e|[B\r' y)" "b 0 0" "Esc, a pause, then [B is Down"
+}
+
+test_lone_escape_still_cancels_on_a_terminal() {
+  assert_eq "$(tty_widgets '\e')" "- 130"
+}
+
 run_tests
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zsh tests/prompt.test.zsh`

Expected: FAIL.
- `shift/ctrl+down move like down: expected [c] got [b]`: the `2` of `1;2B` selected item 2.
- `F5 neither selects nor moves: expected [a] got [e]`.
- `Option+Left (Esc b) neither cancels nor moves: expected [a] got []`.
- `F5 does not answer; shift+right toggles: expected [0] got [1]`.
- `Esc, a pause, then [B is Down: expected [b 0 0] got [- 130]`.

That is 5 failing assertions; 33 pass. The existing `tty_input` tests still pass on the new helper.

- [ ] **Step 3: Implement**

```diff
diff --git a/lib/prompt.zsh b/lib/prompt.zsh
index d37a8a3..d77a94b 100644
--- a/lib/prompt.zsh
+++ b/lib/prompt.zsh
@@ -115,22 +115,27 @@ _prompt_raw_off() {
 }
 _prompt_cancel() { _prompt_raw_off; _prompt_say $'\n'; exit 130; }
 
-# _prompt_key -> KEY: up|down|left|right|enter|tab|cancel, or the literal character typed.
+# _prompt_key -> KEY: up|down|left|right|enter|tab|cancel, empty for a key with no meaning
+# here, or the literal character typed.
 _prompt_key() {
-  local c d e
+  local c d
+  local -F wait=$(( ${KEYTIMEOUT:-40} / 100.0 ))
   read -u $WT_PROMPT_FD -k 1 -r c || _prompt_cancel
   case "$c" in
     $'\n'|$'\r') KEY=enter ;;
     $'\t')       KEY=tab ;;
     $'\x03'|q)   KEY=cancel ;;
     $'\e')
-      # A lone Esc has nothing following it; an arrow key is Esc + [ (or O) + letter.
-      if read -u $WT_PROMPT_FD -t 0.05 -k 1 -r d && [[ "$d" == [\[O] ]] \
-          && read -u $WT_PROMPT_FD -t 0.05 -k 1 -r e; then
-        case "$e" in A) KEY=up ;; B) KEY=down ;; C) KEY=right ;; D) KEY=left ;; *) KEY='' ;; esac
-      else
-        KEY=cancel
-      fi ;;
+      # Nothing within KEYTIMEOUT is a lone Esc. A sequence is read to its end so none of its
+      # bytes becomes a later key: CSI takes bytes 0x20-0x3F up to one final byte, SS3 one byte.
+      read -u $WT_PROMPT_FD -t $wait -k 1 -r d || { KEY=cancel; return; }
+      KEY=''
+      case "$d" in
+        \[) while read -u $WT_PROMPT_FD -t $wait -k 1 -r d && (( #d >= 0x20 && #d <= 0x3F )); do :; done ;;
+        O)  read -u $WT_PROMPT_FD -t $wait -k 1 -r d ;;
+        *)  return ;;
+      esac
+      case "$d" in A) KEY=up ;; B) KEY=down ;; C) KEY=right ;; D) KEY=left ;; esac ;;
     *) KEY="$c" ;;
   esac
 }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zsh tests/prompt.test.zsh`

Expected: `38 passed, 0 failed`, in about 10 s because the pty tests wait.

- [ ] **Step 5: Commit**

```bash
git add lib/prompt.zsh tests/helpers.zsh tests/prompt.test.zsh
git commit -F - <<'MSG'
fix(prompt): read whole escape sequences so no byte becomes a later key

_prompt_key read Esc plus two bytes. Shift/Ctrl+arrows (\e[1;2B) and F5-F12 (\e[15~)
left "2B" or "5~" behind, so a digit selected a menu row and the rest leaked into the
next prompt or the shell. An arrow split across reads by more than 50 ms (ssh, mosh)
cancelled the menu and left "[B" on the command line. Option+Left (\eb) cancelled.

CSI is now read through its parameter bytes (0x20-0x3F) to the final byte. SS3 and
Alt+key take one more byte. Modified arrows act as arrows, and every other sequence is
ignored. A lone Esc is decided after KEYTIMEOUT (default 0.4 s, the zle setting) instead
of 50 ms.

tests: the zpty helper block from the Phase 1 plan, byte for byte and at the same place,
so the two PRs merge it as one identical change. Two different copies would merge without
a conflict, and the later pty_start/pty_send would silently replace the earlier ones. The
pty tests compare icanon/echo/isig, not `stty -g`: macOS sets PENDIN whenever canonical
mode returns. setup_env unsets EDITOR and VISUAL, because a vi EDITOR changes zle's default
keymap in the vared tests.
MSG
```

---

### Task 9: Typed-ahead keys never answer a later prompt

**Findings:** `prompts:typeahead-leak-autoconfirm` (high in review, confirmed medium).

**Files:**
- Modify: `lib/prompt.zsh`, `_prompt_raw_on`.
- Test: `tests/prompt.test.zsh` (widget level) and `tests/remove_interactive.test.zsh` (end to end through `bin/workytree remove`).

**Interfaces:** after switching to raw mode, `_prompt_raw_on` drains the input that is already pending: `read -t 0 -k 1` until nothing is left. This happens only when the prompt input is a terminal (the existing `-t` check). Keys typed before a prompt was drawn are dropped, and the user types them again.

- [ ] **Step 1: Write the failing tests**

```diff
diff --git a/tests/prompt.test.zsh b/tests/prompt.test.zsh
index e6b7887..0485847 100644
--- a/tests/prompt.test.zsh
+++ b/tests/prompt.test.zsh
@@ -150,6 +150,10 @@ tty_widgets() {
   [[ -s $out ]] && print -r -- "$(<$out)"
 }
 
+test_typeahead_does_not_answer_the_next_prompt() {
+  assert_eq "$(tty_widgets '2\r' n)" "b 1 0" "the Enter typed with 2 is dropped; the confirm waits for n"
+}
+
 test_split_escape_sequence_is_still_an_arrow() {
   assert_eq "$(tty_widgets '\e|[B\r' y)" "b 0 0" "Esc, a pause, then [B is Down"
 }
diff --git a/tests/remove_interactive.test.zsh b/tests/remove_interactive.test.zsh
index a232feb..7451adf 100644
--- a/tests/remove_interactive.test.zsh
+++ b/tests/remove_interactive.test.zsh
@@ -376,4 +376,26 @@ test_remote_delete_prints_a_restore_command() {
   assert_contains "$(remote_branch fix/T)" fix/T "restored"
 }
 
+test_typed_ahead_keys_do_not_confirm_the_removal() {
+  make_repo "$HOME/src/app"
+  write_config <<EOF2
+[project me]
+repo_root = ~/src
+worktree_root = ~/wts
+EOF2
+  wt create app fix T main >/dev/null 2>&1
+  pty_start "WORKYTREE_PROMPT_INPUT=/dev/tty WORKYTREE_PROMPT_KEYS=1 ${(q)WT_BIN} remove; print -r -- \$? > ${(q)TMP_ROOT}/rc"
+  pty_wait "worktree to remove" 50
+  pty_send $'1\r2\r'
+  pty_wait "delete local branch" 50; sleep 0.5
+  assert_dir "$HOME/wts/app/fix/T" "nothing removed while the branch question waits"
+  pty_send n
+  pty_wait "Proceed?" 50; sleep 0.3
+  pty_send n
+  pty_finish 50
+  assert_eq "$(<$TMP_ROOT/rc)" 130
+  assert_dir "$HOME/wts/app/fix/T"
+  assert_contains "$(git -C "$HOME/src/app" branch --list fix/T)" fix/T
+}
+
 run_tests
```

- [ ] **Step 2: Run them to verify they fail**

Run: `zsh tests/prompt.test.zsh; zsh tests/remove_interactive.test.zsh`

Expected: FAIL.
- `the Enter typed with 2 is dropped; the confirm waits for n: expected [b 1 0] got [b 0 0]`.
- In the remove flow, `1⏎2⏎` picked the worktree. The leaked `⏎` answered the branch question and `Proceed?`, so the worktree and `fix/T` were deleted with no key pressed for either question: `dir missing …/fix/T` and `expected [130] got [0]`.

- [ ] **Step 3: Implement**

```diff
diff --git a/lib/prompt.zsh b/lib/prompt.zsh
index d77a94b..ae4958a 100644
--- a/lib/prompt.zsh
+++ b/lib/prompt.zsh
@@ -108,6 +108,8 @@ _prompt_raw_on() {
   WT_PROMPT_STTY="$(stty -g <&$WT_PROMPT_FD)"
   # -isig: Ctrl-C arrives as a key, so the cancel path restores the terminal before exiting.
   stty -icanon -echo -isig <&$WT_PROMPT_FD
+  local junk
+  while read -u $WT_PROMPT_FD -t 0 -k 1 -r junk; do :; done
 }
 _prompt_raw_off() {
   [[ -n "$WT_PROMPT_STTY" ]] || return 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zsh tests/prompt.test.zsh && zsh tests/remove_interactive.test.zsh`

Expected: `39 passed`, `115 passed`, all with `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/prompt.zsh tests/prompt.test.zsh tests/remove_interactive.test.zsh
git commit -F - <<'MSG'
fix(prompt): drop keys typed before a prompt is drawn

Menus act on a digit without Enter, so the habitual "1⏎" left the ⏎ pending. The next
question, often remove's "(merged)" branch question or Proceed?, both defaulting to Yes,
took it as an answer the user never gave. Reproduced in a pty: "1⏎2⏎" in `wt remove`
removed the worktree and its branch. Each raw-mode prompt now drains pending input
after switching modes, so a key only answers a question that was on screen.
MSG
```

---

## Final verification

- [ ] **Lint** (CI's loop):

```bash
for f in bin/workytree lib/*.zsh lib/cmd/*.zsh shell/workytree.zsh shell/completions/_workytree tests/*.zsh; do zsh -n "$f" || echo "syntax error: $f"; done
```

Expected: no output.

- [ ] **Full suite:** `zsh tests/run.zsh`. Expected: every file `0 failed`, 1134 assertions in total, against 1000 on `main` at 48c022b. That takes about 2.5 min on an M-series Mac.

| File | `main` (48c022b) | after Task 9 |
|---|---|---|
| `tests/agent.test.zsh` | 75 passed, 0 failed | 75 passed, 0 failed |
| `tests/cli.test.zsh` | 10 passed, 0 failed | 10 passed, 0 failed |
| `tests/complete.test.zsh` | 14 passed, 0 failed | 14 passed, 0 failed |
| `tests/config.test.zsh` | 179 passed, 0 failed | 179 passed, 0 failed |
| `tests/create.test.zsh` | 35 passed, 0 failed | 92 passed, 0 failed (changed) |
| `tests/create_interactive.test.zsh` | 18 passed, 0 failed | 24 passed, 0 failed (changed) |
| `tests/forge.test.zsh` | 27 passed, 0 failed | 27 passed, 0 failed |
| `tests/init.test.zsh` | 41 passed, 0 failed | 41 passed, 0 failed |
| `tests/install.test.zsh` | 23 passed, 0 failed | 23 passed, 0 failed |
| `tests/manage.test.zsh` | 80 passed, 0 failed | 88 passed, 0 failed (changed) |
| `tests/prompt.test.zsh` | 31 passed, 0 failed | 39 passed, 0 failed (changed) |
| `tests/prune.test.zsh` | 70 passed, 0 failed | 70 passed, 0 failed |
| `tests/prune_internal.test.zsh` | 22 passed, 0 failed | 22 passed, 0 failed |
| `tests/remove.test.zsh` | 38 passed, 0 failed | 53 passed, 0 failed (changed) |
| `tests/remove_interactive.test.zsh` | 91 passed, 0 failed | 115 passed, 0 failed (changed) |
| `tests/resolve.test.zsh` | 56 passed, 0 failed | 56 passed, 0 failed |
| `tests/shell.test.zsh` | 58 passed, 0 failed | 58 passed, 0 failed |
| `tests/status.test.zsh` | 44 passed, 0 failed | 44 passed, 0 failed |
| `tests/status_internal.test.zsh` | 53 passed, 0 failed | 69 passed, 0 failed (changed) |
| `tests/status_tui.test.zsh` | 28 passed, 0 failed | 28 passed, 0 failed |
| `tests/worktree.test.zsh` | 7 passed, 0 failed | 7 passed, 0 failed |
| **total** | **1000 passed, 0 failed** | **1134 passed, 0 failed** |

- [ ] **Comment sweep:** `git diff main -- lib bin | grep -E '^\+\s*#'` lists only function signatures and the three "quietly breaks" notes: the KEYTIMEOUT/CSI rule in `_prompt_key`, "read before the worktree is removed", and the R22 base_ref/base_label note that was kept. `git diff main -- tests | grep -E '^\+\s*#'` lists Phase 1's helper comments (verbatim), helper and fixture signatures, `pty_script`'s width and fzf note (moved out of `tty_input`), the case-insensitive early return, the PENDIN note, and the note on restoring `forge_pr_rows` in `status_internal.test.zsh`.

## Merge notes with Phase 1 (`fix/non-interactive-shell`)

Phase 1's plan is `docs/superpowers/plans/2026-10-23-noninteractive-shell.md`. The spec (§13.2) lands T7-1 first, so Phase 1 normally rebases onto this track. Both prototypes were merged (this plan's nine commits into Phase 1's at `645f767`) and resolved as the table says. Lint was clean, and `tests/run.zsh` gave 1279 passed, 0 failed, once Phase 1's replay test was changed as the last row says.

| File | This plan touches | Phase 1 touches | Resolution |
|---|---|---|---|
| `lib/cmd/remove.zsh` | `remove_branch` (:1-17), `remove_remote_branch` (:41-50), branch capture (:201-207), the merged block and questions (:261-292), result rows (:329-342); line numbers are on `main` | the push line inside `remove_remote_branch` (:43), the K4 message (:185), `WT_CAN_CD` (:293-294, :346) | One hunk, in `remove_remote_branch`: keep this branch's `REPLY` capture (from `<sha>`), success line and restore hint, and send the push through Phase 1's `wt_git_remote` without dropping the lease: `wt_git_remote "$repo_path" push --force-with-lease="refs/heads/${rbranch}:${sha}" "$remote" --delete "$rbranch"`. Without `--force-with-lease=…` the push deletes a remote branch that moved since the fetch. |
| `lib/cmd/create.zsh` | the argument loop (Task 4); the kind and ticket loops (Task 5); the middle of `cmd_create` and the `create_do` call (Task 6) | `--no-ai` in the loop and the usage string; `(not asking: $(prompt_blocker))` in the kind and ticket "is required" messages (K4); `ai_maybe_offer … "$no_ai"` | Three hunks. Loop: this plan's arms plus `--no-ai) no_ai=1 ;;` before `-*)`, the usage string `[--ai\|--no-ai]`, and drop the `# TODO(T7-2): …` comment that Phase 1's Task 8 puts above the loop, because Task 4 resolves it. Kind and ticket: this plan's loops with Phase 1's messages. Last lines: `create_do … "$source" …`, then `ai_maybe_offer "$project" "$want_ai" "$no_ai"`. |
| `lib/prompt.zsh` | `_prompt_raw_on`, `_prompt_key` | `prompt_available`, `prompt_tty`, `prompt_blocker`, `prompt_screen` | Different functions; no conflict. |
| `tests/helpers.zsh` | Phase 1's zpty block (identical); `setup_env` adds `EDITOR VISUAL` | the same block; `setup_env` adds the protocol variables and `EDITOR VISUAL NO_COLOR` | The block merges as one identical change (Review Focus 8). Take Phase 1's unset line, a superset. |
| `tests/prompt.test.zsh` | appends key-decoding and pty tests before `run_tests` | appends `test_yes_beats_the_prompt_hook_and_names_itself` at the same place | Keep both. |
| `README.md` | "워크트리 만들기", "워크트리 지우기", exit-code row 2 | "비대화 실행", "AI 세션", the `-y` line of "워크트리 지우기", exit-code rows 1 and 2 | Two hunks. Remove section: Phase 1's `-y` line, then this plan's three bullets. Exit codes: Phase 1's rows plus this plan's cases. Row 1 gains create's missing base, a branch checked out elsewhere, a hand-deleted worktree and a foreign directory at the target, and `remove -b/-B/-r` with another branch checked out. Row 2 gains create's kind, ticket and dash-prefixed base. |
| `tests/shell.test.zsh` | — | `test_failure_replays_every_line_and_keeps_the_exit_code` | No conflict. The Phase 1 plan already makes `git worktree add` fail with a ref lock instead of a directory at the target, which Task 6 would now reject before `create_do` prints anything. That version passes with and without this plan. |

## Out of scope

- Picker safety marks (P7)
- `GIT_TERMINAL_PROMPT=0` on push (P1)
- Network time bounds (P2)
- `create --help` (P5)
- New exit codes for partial failure (deferred)
- Ctrl-D/Ctrl-C exit codes in text input (P4)
- The README exit-code table beyond row 2 (P1)
- Status `ctrl-d` on prunable rows (P7)

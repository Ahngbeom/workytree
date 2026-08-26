#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

fixture() {
  make_repo "$HOME/src/app"; make_repo "$HOME/src/lib"
  make_repo "$HOME/other/tool"
  write_config <<EOF
default_project = me
kinds = feature,fix
[project me]
repo_root = ~/src
worktree_root = ~/wts
[project other]
repo_root = ~/other
worktree_root = ~/owts
EOF
}
# answers <lines...>: feed prompt answers from a file
answers() { printf '%s\n' "$@" > "$TMP_ROOT/answers"; export WORKYTREE_PROMPT_INPUT="$TMP_ROOT/answers"; }

test_all_args_still_confirms() {
  fixture; answers ""            # Enter = default Y
  wt create app fix T1 main >/dev/null 2>&1
  assert_dir "$HOME/wts/app/fix/T1"
  answers "n"
  assert_exit 130 wt create app fix T2 main
  assert_not_exists "$HOME/wts/app/fix/T2"
}

test_yes_skips_confirmation() {
  fixture
  assert_exit 0 wt create app fix T3 main -y
  assert_dir "$HOME/wts/app/fix/T3"
}

test_wizard_from_outside_any_repo() {
  fixture
  # project 2 (other) -> repo 1 (tool) -> kind 2 (fix) -> ticket -> base(Enter=auto) -> confirm
  answers "2" "1" "2" "W1" "" ""
  local err; err="$(wt create 2>&1 >/dev/null)"
  assert_eq "$?" 0
  assert_dir "$HOME/owts/tool/fix/W1"
  assert_contains "$err" "1) feature"
}

test_wizard_inside_repo_confirms_then_asks_rest() {
  fixture; cd "$HOME/src/lib"
  answers "" "hotfix" "H1" "" ""     # repo Y, kind free text, ticket, base auto, confirm
  wt create >/dev/null 2>&1
  assert_eq "$?" 0
  assert_dir "$HOME/wts/lib/hotfix/H1"
  assert_eq "$(git -C "$HOME/wts/lib/hotfix/H1" branch --show-current)" "hotfix/H1"
}

test_declining_inferred_repo_opens_picker() {
  fixture; cd "$HOME/src/lib"
  # no -> project 1 (me) -> repo 1 (app) -> kind 1 (feature) -> ticket -> base -> confirm
  #
  # NOTE: deviates from task-5-brief.md's 6-answer version ("n" "1" "1" "P1" "" ""). Declining
  # the inferred repo only clears `repo`/`repo_path` in cmd_create -- it does NOT clear
  # `project`, and create_pick_repo (per the task's design points, which enumerate exactly two
  # skip conditions: --project given, or a single configured project) still asks the project
  # question here since neither condition holds (2 projects, no --project). That is a real,
  # separately-answered question, so the wizard asks 7 questions along this path (repo-confirm,
  # project, repo, kind, ticket, base, confirm), not 6. The brief's 6-answer list silently drops
  # the kind selection, which would leave "P1" mis-consumed as the kind and the ticket question
  # unanswered (running off the end of the input -> EOF -> spurious 130). Added the missing "1".
  answers "n" "1" "1" "1" "P1" "" ""
  wt create >/dev/null 2>&1
  assert_dir "$HOME/wts/app/feature/P1"
}

# R53: two repos sharing a basename within the SAME project used to appear as two IDENTICAL
# "api" entries in the picker -- indistinguishable, and picking either re-resolved by name and
# failed with the same intra-project ambiguity error either way. Now each is labeled with its
# path and the choice is honored directly (no re-resolution by name): picking the SECOND "api"
# entry must create the worktree against the SECOND repo (beta), not silently fall back to the
# first (alpha) or fail.
test_picker_disambiguates_duplicate_basenames() {
  fixture
  make_repo "$HOME/src/alpha/api"
  make_repo "$HOME/src/beta/api"
  # --project me skips the project-selection question; the repo picker then lists (sorted)
  # "api" (alpha), "api" (beta), "app", "lib" -- answer "2" to pick the beta one.
  answers "2" "1" "T1" "" ""
  wt create --project me >/dev/null 2>&1
  assert_eq "$?" 0
  assert_dir "$HOME/wts/api/feature/T1"
  local common; common="$(git -C "$HOME/wts/api/feature/T1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  assert_contains "$common" "/src/beta/api/"
  assert_eq "${common//\/src\/alpha\/api\//}" "$common" "must not have resolved to the alpha repo"
}

test_eof_cancels_without_side_effects() {
  fixture; answers "1"
  assert_exit 130 wt create
  assert_not_exists "$HOME/wts"
}

run_tests

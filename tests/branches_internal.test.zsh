#!/usr/bin/env zsh
# lib/branches.zsh pure classification functions, sourced directly.
source "${0:A:h}/helpers.zsh"
source "$WT_TEST_ROOT/lib/branches.zsh"

test_ticket_key_extraction() {
  local -A want=(
    backup/mpt-9167-pre-amend2 mpt-9167
    backup/MPT-9777-local-a8dae-20261006 MPT-9777
    backup/mr5-pre-squash3-0902-1637 -
    jeje-preview-backup-20260825 -
    mpt-9641-before-squash mpt-9641
    fix/ABC-12x -
    fix/AB-1 AB-1
  )
  local n
  for n in ${(k)want}; do
    if branch_ticket_key "$n"; then assert_eq "$REPLY" "${want[$n]}" "$n"
    else assert_eq - "${want[$n]}" "$n"; fi
  done
}

test_ticket_key_skips_excluded_prefix_candidate() {
  branch_ticket_key x/before-5/MPT-7; assert_eq "$REPLY" MPT-7
}

test_key_matching_respects_boundaries() {
  branch_name_has_key fix/mpt-9167 MPT-9167; assert_eq $? 0 case-insensitive
  branch_name_has_key fix/mpt-9167 mpt-916; assert_eq $? 1 prefix-is-not-a-match
  branch_name_has_key fix/xmpt-9167 mpt-9167; assert_eq $? 1 needs-left-boundary
  branch_name_has_key fix/mpt-9167_v2 mpt-9167; assert_eq $? 0 underscore-is-a-boundary
  branch_name_has_key mpt-12 mpt-12; assert_eq $? 0 whole-name
  branch_name_has_key fix/mpt-12-x mpt-12; assert_eq $? 0 hyphen-after
}

test_backup_and_protected_names() {
  local n
  for n in backup/x a-backup a-backup-1 mpt-1-before-squash BACKUP/Y; do
    branch_backup_name "$n"; assert_eq $? 0 "$n"; done
  for n in backupx fix/before; do branch_backup_name "$n"; assert_eq $? 1 "$n"; done
  for n in main master develop release/1.2; do branch_protected "$n"; assert_eq $? 0 "$n"; done
  for n in feature/main releases/1; do branch_protected "$n"; assert_eq $? 1 "$n"; done
}

test_ticket_pr_state() {
  print -r -- $'fix/mpt-1\t!1\tmerged\tu\ts1\nfix/mpt-2\t!2\tmerged\tu\ts2\nfix/mpt-2-b\t!3\topen\tu\ts3' > "$HOME/prs"
  branch_ticket_pr mpt-1 "$HOME/prs"; assert_eq "$REPLY ${reply[1]}" "merged !1"
  branch_ticket_pr mpt-2 "$HOME/prs"; assert_eq "$REPLY ${reply[1]}" "open !3" open-pr-wins
  print -r -- $'fix/mpt-4\t!4\tdraft\tu\ts4' >> "$HOME/prs"
  branch_ticket_pr mpt-4 "$HOME/prs"; assert_eq "$REPLY ${reply[1]}" "open !4" draft-counts-as-open
  branch_ticket_pr mpt-3 "$HOME/prs"; assert_eq "$REPLY" none
  branch_ticket_pr mpt-1 "$HOME/missing"; assert_eq $? 1 lookup-skipped
}

test_owner_and_pushed() {
  branch_owner '<T@t>' t@t; assert_eq "$REPLY" me
  branch_owner '<x@y>' t@t; assert_eq "$REPLY" teammate
  branch_owner '<t@t>' ''; assert_eq "$REPLY" teammate empty-user-email
  branch_pushed fix/a s1 s1 - ''; assert_eq $? 0 same-sha
  branch_pushed fix/a s1 s2 refs/remotes/origin/fix/a 'behind 2'; assert_eq $? 0 behind-only
  branch_pushed fix/a s1 s2 refs/remotes/origin/fix/a 'ahead 1'; assert_eq $? 1 ahead
  branch_pushed fix/a s1 s2 refs/remotes/origin/develop ''; assert_eq $? 1 other-upstream
}

test_side_and_row_why() {
  branch_side_why 1 1 0 0 0 10 100; assert_eq "$REPLY" protected
  branch_side_why 0 1 0 0 1 500 100; assert_eq "$REPLY" merged merged-beats-gone
  branch_side_why 0 0 1 0 0 500 100; assert_eq "$REPLY" pushed
  branch_side_why 0 0 0 1 0 500 100; assert_eq "$REPLY" backup
  branch_side_why 0 0 0 0 1 10 100; assert_eq "$REPLY" gone
  branch_side_why 0 0 0 0 0 500 100; assert_eq "$REPLY" stale
  branch_side_why 0 0 0 0 0 100 100; assert_eq "$REPLY" unmerged age-equal-to-threshold
  branch_side_why 0 0 0 0 0 101 100; assert_eq "$REPLY" stale
  branch_side_why 0 0 0 0 0 - 100; assert_eq "$REPLY" unmerged
  branch_row_why merged stale me; assert_eq "$REPLY" stale riskier-side
  branch_row_why pushed unmerged teammate; assert_eq "$REPLY" pushed teammate-side-ignored
  branch_row_why - merged teammate; assert_eq "$REPLY" read-only
  branch_row_why merged protected me; assert_eq "$REPLY" protected
  branch_why_class backup; assert_eq "$REPLY" safe
  branch_why_class gone; assert_eq "$REPLY" force
  branch_why_class read-only; assert_eq "$REPLY" none
}

run_tests

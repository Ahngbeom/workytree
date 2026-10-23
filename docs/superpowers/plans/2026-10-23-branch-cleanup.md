# wt status 브랜치 모드 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `wt status`에 `ctrl-b`로 들어가는 브랜치 모드를 더해, repo별 로컬·`origin` 브랜치를 한 행씩 보여 주고 표시한 행을 계획 → 확인 → 삭제 → 결과 순서로 지운다.

**Architecture:** 분류 순수 함수와 수집기 `status_collect_branches`는 새 파일 `lib/branches.zsh`, 브랜치 모드의 포매터·렌더러·미리보기·삭제 흐름은 새 파일 `lib/cmd/status_branches.zsh`에 둔다(`bin/workytree`가 `lib/*.zsh`, `lib/cmd/*.zsh`를 glob으로 source하므로 등록 불필요). 워크트리 목록의 26필드 레코드에서 `branch` 행을 없애고, 브랜치 모드는 17필드 브랜치 레코드를 쓴다. 두 레코드를 고르는 기준은 언제나 `ST_BRANCHES`이고 레코드의 type 필드나 필드 수로 분기하지 않는다. 모드 전환은 fzf `--expect=ctrl-b`로 fzf를 끝내고 `_status_run_fzf`의 바깥 루프가 다른 모드로 fzf를 다시 띄운다.

**Tech Stack:** zsh 5.9, git(2.41 미만 fallback 유지), fzf ≥ 0.38, `gh`/`glab`(선택)

**Spec:** `docs/superpowers/specs/2026-10-23-branch-cleanup-design.md`

**시작 전:** 스펙과 이 계획을 기능 커밋과 섞지 않도록 따로 커밋한다(`docs: design and plan for status branch mode`).

## Global Constraints

- fzf 최소 버전 `WT_STATUS_FZF_MIN=0.38`을 올리지 않는다. `transform`(0.45), `change-header`(0.40)를 쓰지 않는다. `--expect`, `--multi`, `{+f}`, `ignore`, `deselect-all`, `transform-query`(0.36)는 쓸 수 있다
- fzf 바인딩은 `SHELL=/bin/sh`에서 돈다. 경로·인자는 `${(q)}`로 인용한다
- 조회(수집, `__status-rows`, 미리보기, 모드 전환)는 fetch·ref 변경·index 재작성을 하지 않는다. 쓰기는 `ctrl-r`, `alt-d`, `ctrl-d`뿐
- 원격은 `origin`만 다룬다
- 보호 브랜치: `main`, `master`, `develop`, `release/*`
- 백업 패턴(대소문자 무시): `backup/*`, `*-backup`, `*-backup-*`, `*-before-*`
- 티켓 키: `[A-Za-z]{2,}-[0-9]+`의 첫 후보. 이름 처음 또는 `/`·`-`·`_` 뒤에서 시작하고, 이름 끝 또는 `/`·`-`·`_` 앞에서 끝남. `backup`·`before`·`pre`로 시작하면 제외. 키 포함 검사(`branch_name_has_key`)도 같은 경계, 대소문자 무시
- 패턴을 쓰는 함수는 `setopt localoptions extendedglob`으로 시작한다(테스트 파일은 extendedglob을 켜지 않음)
- 삭제 로그: `${XDG_STATE_HOME:-$HOME/.local/state}/workytree/deleted.log`, 탭 구분 5열(`2026-10-23T17:30:12+09:00` 형식 시각, repo 절대 경로, ref 전체 이름, 전체 sha, 복구 명령), 성공한 삭제만
- 질문은 `prompt_confirm "<msg>" n`(기본 No). 계획·결과·헬퍼 메시지는 stderr
- 새 필수 의존성(jq, timeout 등) 없음. git 2.31 미만에서 `--path-format=absolute`가 실패해도 기능이 깨지지 않게 fallback
- CI: `zsh tests/run.zsh`, `zsh -n bin/workytree lib/*.zsh lib/cmd/*.zsh shell/workytree.zsh shell/completions/_workytree tests/*.zsh`
- 테스트 fixture: 작성자 이메일 `t@t`, `user.email` 비어 있음(`GIT_CONFIG_GLOBAL=/dev/null`). 소유 판정 테스트는 `git -C <repo> config user.email t@t`. 동료 커밋은 `GIT_AUTHOR_EMAIL=x@y GIT_COMMITTER_EMAIL=x@y git commit`
- 브랜치 이름에 공백은 git이 거부한다. 특수 문자 테스트는 `fix/q"x`, `fix/a$b'c`를 쓴다

## Review Focus

1. 따옴표·`$`가 든 브랜치 이름과 공백이 든 repo 경로가 브랜치 레코드, `{+f}` 파일, JSON, 계획 출력, 복구 명령에서 깨지지 않아야 한다 → Task 5b(JSON), Task 8a(계획) 테스트
2. `origin`이 없는 repo는 로컬 행만 보이고 삭제 시 fetch·원격 단계를 건너뛴다 → Task 5a, Task 8b 테스트
3. 원격 ref·동료 원격 사본이 많은 repo에서 수집이 브랜치마다 git을 부르지 않는다 → Task 5a git 호출 횟수 테스트
4. 수집 뒤 브랜치가 사라지거나 움직이거나 체크아웃되면 지우지 않는다 → Task 8a, 8b 테스트
5. `origin` fetch 실패 시 그 repo의 원격 삭제만 빠지고 로컬 삭제는 진행되며, `pushed`는 force로 내려간다 → Task 8a 테스트

---

### Task 1: 워크트리 목록의 ✓에서 gone·closed 제외

**Files:**
- Modify: `lib/status.zsh:101-118` (`status_flag`)
- Modify: `README.md:155-157` (`✓`, `!` 정의)
- Test: `tests/status_internal.test.zsh:23-40`, `tests/status.test.zsh:100-110`

**Interfaces:**
- Produces: `status_flag` 시그니처 그대로. safe = `! locked && merged`. dirty의 "upstream 없음"은 `(! has_up || gone)`

- [ ] **Step 1: 판정표 테스트를 새 기대값으로 바꾼다**

`test_flag_table`의 `gone`, `closed-pr` 줄을 지우고 넣는다.

```zsh
  status_flag 0 1 - clean - 1 3 0 10 100; assert_eq "$REPLY" dirty     gone-unmerged-is-the-only-copy
  status_flag 0 1 - clean - 1 0 0 10 100; assert_eq "$REPLY" -         gone-without-own-commits
  status_flag 0 0 closed clean 0 1 3 0 10 100; assert_eq "$REPLY" -    closed-pr-is-not-safe
  status_flag 0 0 closed clean 0 1 3 0 500 100; assert_eq "$REPLY" stale closed-pr-old
```

`tests/status.test.zsh`의 `test_gone_upstream_is_safe`를 `test_gone_upstream_unmerged_is_dirty`로 바꾸고 마지막 단언을 `assert_eq "$(field fix/GONE 9)" dirty`로 바꾼다.

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/status_internal.test.zsh; zsh tests/status.test.zsh`
Expected: `gone-unmerged-is-the-only-copy`, `closed-pr-is-not-safe`, `test_gone_upstream_unmerged_is_dirty` FAIL

- [ ] **Step 3: `status_flag` 수정**

safe 조건을 `(( ! locked && merged ))`, dirty 조건의 `(( ! has_up && ! merged ))`를 `(( (! has_up || gone) && ! merged ))`로 바꾼다.

- [ ] **Step 4: 통과 확인**

Run: `zsh tests/run.zsh`
Expected: 모든 파일 PASS

- [ ] **Step 5: README**

`README.md:155` `✓`에서 "PR/MR 병합·종료"를 "PR/MR 병합(브랜치가 PR 마지막 커밋을 가리킬 때)"으로, "upstream 삭제 중 하나이면서"를 지운다. `:157` `!`에 "upstream이 삭제됐는데 base에 없는 커밋"을 더한다.

- [ ] **Step 6: Commit**

```bash
git add lib/status.zsh tests/status_internal.test.zsh tests/status.test.zsh README.md
git commit -m "fix(status): stop flagging gone or closed-PR branches as safe"
```

---

### Task 2: 삭제 로그

**Files:**
- Modify: `lib/config.zsh` (파일 앞부분에 `zmodload zsh/datetime`, `config_file_path`(:28-30) 아래에 두 함수)
- Modify: `lib/cmd/remove.zsh:4-27` (`remove_branch`), `:51-65` (`remove_remote_branch`)
- Modify: `tests/helpers.zsh:15-29` (`setup_env`)
- Modify: `README.md:209`(remove 절), `README.md:329-336`(환경 변수 표)
- Test: `tests/remove.test.zsh`, `tests/remove_interactive.test.zsh`

**Interfaces:**
- Produces:
  - `wt_state_dir` → stdout `${XDG_STATE_HOME:-$HOME/.local/state}/workytree`
  - `wt_deletion_log <repo_path> <ref> <full_sha> <restore_cmd>` → rc 0. 쓰기 실패 시 `warn "could not write the deletion log: <path>"`, rc 0
  - `remove_branch`, `remove_remote_branch`: 성공 경로에서 `wt_deletion_log` 한 번. 시그니처·REPLY·반환값 그대로

- [ ] **Step 1: `setup_env`에 `export XDG_STATE_HOME=$HOME/.local/state` 추가** (`XDG_CONFIG_HOME` 다음 줄)

- [ ] **Step 2: 실패하는 테스트**

`tests/remove.test.zsh`:

```zsh
test_branch_delete_is_logged() {
  fixture
  local sha; sha="$(git -C "$HOME/src/app" rev-parse fix/T)"
  wt remove app fix T -b >/dev/null 2>&1
  local line; line="$(<"$HOME/.local/state/workytree/deleted.log")"
  local -a f; f=("${(@ps:\t:)line}")
  assert_eq "${#f}" 5 five-columns
  [[ "${f[1]}" == <4>-<2>-<2>T<2>:<2>:<2>[+-]<2>:<2> ]]; assert_eq $? 0 iso-8601-with-colon-offset
  assert_eq "${f[2]}" "$HOME/src/app"
  assert_eq "${f[3]}" refs/heads/fix/T
  assert_eq "${f[4]}" "$sha"
  assert_eq "${f[5]}" "git -C $HOME/src/app branch fix/T $sha"
  eval "${f[5]}"
  assert_eq "$(git -C "$HOME/src/app" rev-parse fix/T)" "$sha" restored-from-log
}

test_kept_branch_is_not_logged() {
  fixture
  print y > "$WT/f"; git -C "$WT" add -A; git -C "$WT" commit -qm c
  wt remove app fix T -b >/dev/null 2>&1
  assert_not_exists "$HOME/.local/state/workytree/deleted.log"
}

test_unwritable_deletion_log_only_warns() {
  fixture
  mkdir -p "$HOME/.local/state"; print x > "$HOME/.local/state/workytree"
  local out; out="$(wt remove app fix T -b 2>&1)"
  assert_contains "$out" "could not write the deletion log"
  assert_eq "$(git -C "$HOME/src/app" branch --list fix/T)" "" deleted-anyway
}
```

`tests/remove_interactive.test.zsh`(bare remote fixture, `fix/T`는 머지됨):

```zsh
test_remote_delete_is_logged_and_restorable() {
  fixture
  local sha; sha="$(git -C "$HOME/src/app" rev-parse fix/T)"
  wt remove app fix T -b -r -y >/dev/null 2>&1
  local log; log="$(<"$HOME/.local/state/workytree/deleted.log")"
  local want="git -C $HOME/src/app push origin $sha:refs/heads/fix/T"
  assert_contains "$log" $'\trefs/remotes/origin/fix/T\t'"$sha"$'\t'"$want"
  eval "$want" 2>/dev/null
  assert_contains "$(remote_branch fix/T)" fix/T restored-on-remote
}
```

- [ ] **Step 3: 실패 확인**

Run: `zsh tests/remove.test.zsh; zsh tests/remove_interactive.test.zsh`
Expected: `test_branch_delete_is_logged`, `test_unwritable_deletion_log_only_warns`, `test_remote_delete_is_logged_and_restorable` FAIL. `test_kept_branch_is_not_logged`는 이미 PASS

- [ ] **Step 4: 구현**

- 시각: `t="$(strftime '%Y-%m-%dT%H:%M:%S%z' $EPOCHSECONDS)"; t="${t[1,-3]}:${t[-2,-1]}"`
- `remove_branch`: 삭제 전에 전체 sha(`rev-parse -q --verify refs/heads/$branch`)를 받아 두고, 성공 경로에서 `wt_deletion_log "$repo_path" "refs/heads/$branch" "$full" "git -C ${(q)repo_path} branch ${(q)branch} $full"`
- `remove_remote_branch`: 성공 경로에서 `wt_deletion_log "$repo_path" "refs/remotes/$remote/$rbranch" "$sha" "git -C ${(q)repo_path} push ${(q)remote} $sha:refs/heads/${(q)rbranch}"`

- [ ] **Step 5: 통과 확인**

Run: `zsh tests/run.zsh`
Expected: 모든 파일 PASS

- [ ] **Step 6: README**

`README.md:209` 아래: 지운 브랜치는 `~/.local/state/workytree/deleted.log`(`XDG_STATE_HOME`)에 시각·repo·ref·sha·복구 명령으로 남고, 다른 ref에 없는 커밋은 git gc 유예(기본 2주)가 지나면 되살릴 수 없다. 환경 변수 표에 `XDG_STATE_HOME` 행.

- [ ] **Step 7: Commit**

```bash
git add lib/config.zsh lib/cmd/remove.zsh tests/helpers.zsh tests/remove.test.zsh tests/remove_interactive.test.zsh README.md
git commit -m "feat(remove): append every deleted branch to a deletion log"
```

---

### Task 3: status 대상 repo 중복 제거

**Files:**
- Modify: `lib/cmd/status.zsh:46-53` (`_status_targets`)
- Test: `tests/status.test.zsh`

**Interfaces:**
- Produces: `_status_targets` 출력 형식 그대로(`name<TAB>project<TAB>repo_path`). 키는 `git -C <repo_path> rev-parse --path-format=absolute --git-common-dir`이고, 실패하거나 비면 `repo_path` 자체(중복 제거 안 됨, 오류 행 유지). 같은 키의 줄 중 `<repo_path>/.git`이 디렉터리인 줄이 이기고, 없으면 먼저 나온 줄. 출력 순서는 이긴 줄들의 처음 등장 순서

- [ ] **Step 1: 실패하는 테스트**

```zsh
test_linked_worktree_found_by_scan_is_collected_once() {
  fixture
  git -C "$HOME/src/app" worktree add -q "$HOME/src/agent-x" -b agent-x
  load_rows
  local -a mains; mains=(${(f)"$(print -r -- "$ROWS" | awk -F'\t' '$1=="main"')"})
  assert_eq "${#mains}" 1 one-main-row
  assert_eq "${${(@ps:\t:)mains[1]}[3]}" app main-checkout-wins
}
```

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/status.test.zsh`
Expected: 새 테스트 FAIL(main 행 2개), 나머지 PASS

- [ ] **Step 3: `_status_targets` 구현**

- [ ] **Step 4: 통과 확인**

Run: `zsh tests/status.test.zsh`
Expected: PASS(`test_unreadable_repo_becomes_one_error_row` 포함)

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/status.zsh tests/status.test.zsh
git commit -m "fix(status): collect a repository once when a linked worktree is also scanned"
```

---

### Task 4: 브랜치 분류 순수 함수

**Files:**
- Create: `lib/branches.zsh`
- Create: `tests/branches_internal.test.zsh` (`helpers.zsh`와 `lib/branches.zsh`만 source)

**Interfaces:**
- Produces (git을 부르지 않음):
  - `branch_protected <name>` → rc 0이면 보호
  - `branch_backup_name <name>` → rc 0이면 백업 패턴
  - `branch_ticket_key <name>` → rc 0, `REPLY`=키(원문 대소문자). 없으면 rc 1
  - `branch_name_has_key <name> <key>` → rc 0이면 포함
  - `branch_ticket_pr <key> <pr_file>` → `REPLY`=`merged|open|none`, `reply=(<ref>)`. 키가 든 head의 PR 중 `open`·`draft`가 하나라도 있으면 `open`, 아니면 `merged`가 있으면 `merged`, 둘 다 없으면 `none`. `pr_file`이 없으면 rc 1(조회 안 함)
  - `branch_owner <author_email> <user_email>` → `REPLY`=`me|teammate`. `<>` 제거, 대소문자 무시, user_email 비면 `teammate`
  - `branch_pushed <branch> <local_sha> <remote_sha> <upstream> <track>` → rc 0이면 `local_sha == remote_sha`이거나 `upstream == refs/remotes/origin/<branch>`이고 `track`에 `ahead`가 없음
  - `branch_side_why <protected> <merged> <pushed> <backup_ok> <gone> <age_s> <stale_s>` → `REPLY`=`protected|merged|pushed|backup|gone|stale|unmerged`(이 순서로 처음 맞는 것, age가 숫자가 아니면 stale 아님)
  - `branch_row_why <local_why|-> <remote_why|-> <owner me|teammate|->` → `REPLY`. 한쪽이 `protected`면 `protected`. `teammate` 원격은 제외. 남은 쪽이 없으면 `read-only`. 위험 순위 `unmerged > gone > stale > backup > pushed > merged`
  - `branch_why_class <why>` → `REPLY`=`safe`(merged, pushed, backup) | `force`(gone, stale, unmerged) | `none`(read-only, protected)

- [ ] **Step 1: 실패하는 테스트**

```zsh
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

test_key_matching_respects_boundaries() {
  branch_name_has_key fix/mpt-9167 MPT-9167; assert_eq $? 0 case-insensitive
  branch_name_has_key fix/mpt-9167 mpt-916; assert_eq $? 1 prefix-is-not-a-match
  branch_name_has_key fix/xmpt-9167 mpt-9167; assert_eq $? 1 needs-left-boundary
  branch_name_has_key fix/mpt-9167_v2 mpt-9167; assert_eq $? 0 underscore-is-a-boundary
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
  branch_side_why 0 0 0 0 0 - 100; assert_eq "$REPLY" unmerged
  branch_row_why merged stale me; assert_eq "$REPLY" stale riskier-side
  branch_row_why pushed unmerged teammate; assert_eq "$REPLY" pushed teammate-side-ignored
  branch_row_why - merged teammate; assert_eq "$REPLY" read-only
  branch_row_why merged protected me; assert_eq "$REPLY" protected
  branch_why_class backup; assert_eq "$REPLY" safe
  branch_why_class gone; assert_eq "$REPLY" force
  branch_why_class read-only; assert_eq "$REPLY" none
}
```

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/branches_internal.test.zsh`
Expected: FAIL(함수 없음)

- [ ] **Step 3: `lib/branches.zsh` 구현**

파일 머리 주석에 Task 5a의 브랜치 레코드 17필드를 적는다. 키 추출은 경계 위치마다 `(#b)` 패턴으로 시도한다. `zsh/pcre`는 쓰지 않는다.

- [ ] **Step 4: 통과 확인**

Run: `zsh tests/branches_internal.test.zsh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/branches.zsh tests/branches_internal.test.zsh
git commit -m "feat(status): classify branches for cleanup (backup tickets, ownership, protection)"
```

---

### Task 5a: 브랜치 수집기

**Files:**
- Modify: `lib/branches.zsh` (`status_collect_branches`)
- Create: `tests/branches_collect.test.zsh` (`helpers.zsh`, 모든 `lib/*.zsh`를 source. `forge_pr_rows`는 함수로 덮어씀)

**Interfaces:**
- Consumes: Task 4 함수, `status_base_ref`, `status_fmt_age`
- Produces:
  - `status_collect_branches <project> <repo> <repo_path> <stale_days> [pr_file]` → stdout 브랜치 레코드(커밋 시각 오래된 순), stderr 사유 줄, rc 0. `pr_file`이 없으면 PR 근거 없이 판정
  - 브랜치 레코드(탭 17필드, 빈 값 `-`):

| # | 이름 | 값 |
|---|---|---|
| 1 | type | `branch` 또는 `error` |
| 2 | project | |
| 3 | repo | |
| 4 | repo_path | |
| 5 | branch | 이름(원격은 `origin/` 뺀 이름) |
| 6 | local_sha | 전체 sha |
| 7 | remote_sha | 전체 sha |
| 8 | gone | 로컬 upstream이 gone이면 1, 아니면 0 |
| 9 | owner | `me`, `teammate`, `-`(원격 없음) |
| 10 | why | `branch_row_why` 값 |
| 11 | class | `branch_why_class` 값 |
| 12 | commit_ts | 로컬·원격 중 최신 |
| 13 | base_ahead | 지울 쪽 중 큰 값, 모르면 `-` |
| 14 | key | 백업 이름에서 뽑은 키(증명 여부와 무관) |
| 15 | pr_ref | 이 브랜치 이름의 PR |
| 16 | pr_state | |
| 17 | note | 아래 표, error면 git 메시지 첫 줄 |

| why | note |
|---|---|
| merged | `merged into <base 짧은 이름>` 또는 `PR <ref> merged` |
| pushed | `same as origin/<b>` |
| backup | `backup of <KEY> (PR <ref> merged)` |
| 백업 이름인데 미증명 | `backup of <KEY>: PR <ref> open` / `backup of <KEY>: no merged PR` / `backup of <KEY>: PR lookup skipped` |
| gone | `upstream deleted, <n> commits not in <base>` |
| stale | `<나이> old, <n> commits not in <base>` |
| unmerged | `<n> commits not in <base>` |
| read-only | `origin branch by <email>` |
| protected | `protected` |

- [ ] **Step 1: 실패하는 테스트**

각 테스트는 `make_repo ~/src/app` + bare `~/remote.git`(필요 시) + `git -C ~/src/app config user.email t@t`로 시작하고 `ROWS="$(status_collect_branches me app ~/src/app 30 [~/prs])"`, `bf <branch> <n>`(f[5]가 같은 첫 레코드의 n번째 필드, 없으면 `MISSING`)으로 단언한다.

| 테스트 | 준비 | 단언 |
|---|---|---|
| `test_merged_local_and_own_remote_share_one_row` | `fix/m` 커밋 후 push, main에 `--no-ff` 머지 후 push | 행 1개, why `merged`, class `safe`, owner `me`, f6·f7 모두 40자 |
| `test_teammate_only_remote_is_read_only` | x@y로 커밋한 `fix/t` push 후 로컬 삭제 | why `read-only`, class `none`, f6 `-`, note `origin branch by x@y` |
| `test_local_copy_of_teammate_branch_is_pushed` | 위 + 로컬 `fix/t`를 원격과 같은 sha로 | why `pushed`, class `safe` |
| `test_squash_merged_branch_is_merged_by_its_pr` | `fix/s` push 후 원격 삭제·`fetch --prune`, `~/prs`에 `fix/s !4 merged u <tip>` | why `merged`, f8 `1`, note `PR !4 merged` |
| `test_backup_of_a_merged_ticket_is_safe` | `backup/AB-1-pre-squash`(고유 커밋), `~/prs`에 `fix/AB-1 !5 merged` | why `backup`, f14 `AB-1`, class `safe` |
| `test_unproven_backups_stay_unmerged` | 같은 백업, `~/prs`가 open PR / PR 없음 / 인자 없음 | why `unmerged`, note가 각각 `PR !6 open`, `no merged PR`, `PR lookup skipped`로 끝남 |
| `test_base_head_checked_out_and_protected_are_handled` | `origin/HEAD`, 워크트리 `fix/w`, base를 `develop`(origin/HEAD → develop)으로 두고 `master` 존재 | `main`·`develop`·`HEAD`·`fix/w` MISSING, `master` why `protected` |
| `test_repo_without_origin_lists_local_branches_only` | 원격 없음, `fix/l` | 행 1개, f7 `-`, f9 `-` |
| `test_collection_leaves_refs_untouched` | 위 시나리오 몇 개 | 수집 전후 `git for-each-ref` 출력 같음, `FETCH_HEAD` 생기지 않음 |
| `test_collection_does_not_call_git_per_branch` | 원격 전용 40개 + 동료 원격과 같은 sha의 로컬 사본 40개, `user.email` 비움 | `git() { print x >> ~/git.calls; command git "$@"; }` 아래에서 줄 수 ≤ 12 |

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/branches_collect.test.zsh`
Expected: FAIL(함수 없음)

- [ ] **Step 3: 구현**

순서: worktree porcelain(실패 시 error 레코드 하나) → `checked_out` → `status_base_ref` → `git config user.email` → PR 맵 → `for-each-ref` 한 번(`refs/heads refs/remotes/origin`, 형식 `%(refname)\t%(objectname)\t%(committerdate:unix)\t%(upstream)\t%(upstream:track,nobracket)\t%(authoremail)` + `\t%(ahead-behind:$base)`, 출력이 비면 ahead-behind 없이 재시도) → `--merged=$base` 한 번(같은 두 prefix) → 이름 합집합 순회 → 커밋 시각으로 정렬해 출력. 맵 키는 전체 refname. git < 2.41에서는 base_ahead를 `-`로 둔다(브랜치별 `rev-list` 금지).

- [ ] **Step 4: 통과 확인**

Run: `zsh tests/branches_collect.test.zsh && zsh tests/branches_internal.test.zsh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/branches.zsh tests/branches_collect.test.zsh
git commit -m "feat(status): collect local and origin branches into branch records"
```

---

### Task 5b: `--branches` 옵션, 표·JSON, `__status-rows`

**Files:**
- Create: `lib/cmd/status_branches.zsh` (`_branches_format`, `_branches_render_table`, `_branches_render_json`)
- Modify: `lib/cmd/status.zsh` — `:6-10`(`ST_BRANCHES` 선언), `:12-32`(파싱·리셋·usage 두 곳), `:57-66`(`_status_collect_one`이 `ST_BRANCHES`면 `status_collect_branches`), `:110-132`(`ST_BRANCHES`면 정렬은 통과, `--stale`은 `class == safe || why == stale`), `:281-298`(`ST_BRANCHES`면 JSON 아니면 항상 표. fzf는 Task 7에서 연결), `:301-313`(`cmd___status-rows`가 `ST_BRANCHES`면 `_branches_format`). `_status_reload_args`에는 `--branches`를 넣지 않는다(Task 7이 모드별로 붙임)
- Modify: `bin/workytree:40`, `shell/completions/_workytree:68`, `README.md:115`
- Create: `tests/status_branches.test.zsh` (CLI, `tests/status.test.zsh`의 `fixture`·`with_origin` 복사)

**Interfaces:**
- Consumes: Task 5a 레코드
- Produces:
  - `_branches_format <records>` → `ST_RECS`, `ST_LINES`, `ST_HEADER`를 채움. 표시 줄 열: mark(safe `✓`, why stale `●`, 그 밖의 force `!`, none 공백), REPO, BRANCH, LOCAL(`●`/`-`), REMOTE(`● me`/`● teammate`/`gone`/`-`), WHY, COMMIT(나이), 마지막 토큰은 class 단어(`safe`/`force`/`keep`)로 끝나고 뒤에 공백 없음
  - `cmd___status-rows --branches` → 줄마다 레코드 17필드 + 탭 + 표시 줄(필드 18)
  - `_branches_render_table <records> <notes>`, `_branches_render_json <records> <notes>`. JSON 행: `{"type","project","repo","branch","local":{"sha","gone"}|null,"remote":{"sha","owner"}|null,"why","class","commit_age_s","base_ahead","key","pr":{"number","state"}|null,"note"}`, 최상위 `{"notes":[…],"rows":[…]}`
  - 모든 렌더러·정렬·필터는 `ST_BRANCHES`로 분기한다

- [ ] **Step 1: 실패하는 테스트**

| 테스트 | 단언 |
|---|---|
| `test_branches_rows_have_record_plus_display` | `wt __status-rows --branches --offline --no-color`의 각 줄 필드 수 18, f18에 WHY와 끝 단어 `safe`/`force`/`keep` |
| `test_branches_plain_table_has_why_column` | `wt status --branches --plain --offline` 헤더에 `WHY`, 머지된 `fix/m` 줄에 `merged` |
| `test_branches_json_escapes_names` | `fix/q"x`, `fix/a$b'c` 브랜치. `wt status --branches --json --offline`을 `python3 -c 'import json,sys; d=json.load(sys.stdin)'`로 파싱, 두 이름과 `local.sha` 존재 |
| `test_branches_stale_filter_keeps_cleanup_candidates` | `--branches --stale --plain`에 merged 행 있음, 미머지 신규 브랜치 없음 |
| `test_branches_option_is_completed` | `tests/complete.test.zsh`의 `_values` stub 패턴으로 `--branches` 포함 |
| `test_worktree_view_is_unchanged_without_branches` | `--branches` 없이 `__status-rows` 필드 수 27 |

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/status_branches.test.zsh`
Expected: FAIL(`--branches` usage error)

- [ ] **Step 3: 구현**

- [ ] **Step 4: 통과 확인**

Run: `zsh tests/run.zsh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/status_branches.zsh lib/cmd/status.zsh bin/workytree shell/completions/_workytree README.md tests/status_branches.test.zsh
git commit -m "feat(status): add --branches for table and JSON output"
```

---

### Task 6: 워크트리 목록에서 branch 행 제거

**Files:**
- Modify: `lib/status.zsh:3-18`(레코드 주석 type 목록), `:332-347`(branch 행 루프 삭제)
- Modify: `lib/cmd/status.zsh:117-118`(정렬 branch 분기), `:201`(`no worktrees found`), `:401`, `:426-429`(미리보기 branch 분기), `:460`(action 힌트)
- Modify: `README.md:145-151`(표시 대상에서 브랜치 제거, "삭제는 하지 않는다" → "삭제는 `ctrl-d`와 브랜치 모드의 `alt-d`로만", `--json`에서 `branch` 행이 빠지고 `--branches`로 옮겼다는 호환성 한 줄)
- Modify: `docs/demo/setup.zsh:75` 주석이 branch 행을 말하면 브랜치 모드로
- Modify: `tests/status_internal.test.zsh:4-6`, `tests/status_tui.test.zsh:6-7`의 source 목록에 `branches`, `cmd/status_branches` 추가
- Test: `tests/status.test.zsh`, `tests/status_internal.test.zsh`, `tests/status_tui.test.zsh`

**Interfaces:**
- Produces: `status_collect_repo`는 `main|worktree|orphan|error` 행만 낸다

- [ ] **Step 1: 테스트를 새 기대값으로 바꾼다**

| 테스트 | 바꾸는 내용 |
|---|---|
| `status.test.zsh` `test_branch_without_worktree_is_listed_but_base_is_not` | `test_branch_without_worktree_moves_to_branch_mode`: `field lonely 1` == `MISSING`, `wt status --offline --plain`에 `lonely` 없음, `--branches --plain`에 있음 |
| `status.test.zsh` `test_json_is_valid_and_escapes_branch_names` | 따옴표 이름을 `git -C ~/src/app worktree add -q ~/wts/app/fix/qx -b 'fix/q"x'`로 만든 워크트리 브랜치로 |
| 새 `status.test.zsh` `test_stale_and_json_have_no_branch_rows` | `--stale --json`에 `"type":"branch"` 없음 |
| `status_internal.test.zsh` `test_base_counts_without_ahead_behind_support` | 같은 fallback을 워크트리 행으로 |
| `status_internal.test.zsh` `test_sort_groups_types_then_oldest_first_with_main_checkouts_last` | 합성 branch 레코드 제거, 기대값 `worktree:w1 worktree:w2 orphan:- main:m` |
| `status_internal.test.zsh` `test_pr_state_counts_only_at_the_pr_head`, `test_remove_and_status_share_the_merged_verdict` | `grep ^branch` 대신 `status_collect_branches` 출력의 f10(merged 여부)과 비교 |
| `status_tui.test.zsh` fixture의 `git branch lonely` | 유지(브랜치 모드에서 씀) |
| `status_tui.test.zsh` `test_enter_on_branch_row_prints_nothing`, `test_action_refuses_non_worktree_rows` | orphan 행으로(`mkdir -p ~/wts/app/fix/ORPH`) |
| `status_tui.test.zsh` `test_display_field_carries_the_searchable_tags` | `fix/A` 워크트리 행의 f27 |

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/status.test.zsh; zsh tests/status_internal.test.zsh; zsh tests/status_tui.test.zsh`
Expected: 바꾼 테스트 FAIL

- [ ] **Step 3: branch 행 루프와 branch 전용 분기 삭제**

- [ ] **Step 4: 통과 확인**

Run: `zsh tests/run.zsh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/status.zsh lib/cmd/status.zsh README.md docs/demo/setup.zsh tests/status.test.zsh tests/status_internal.test.zsh tests/status_tui.test.zsh
git commit -m "feat(status)!: move branches without a worktree to branch mode"
```

---

### Task 7: TUI 브랜치 모드

**Files:**
- Modify: `lib/cmd/status.zsh:341-377` (`_status_run_fzf`를 모드 루프로), `:281-298`(Task 5b의 "ST_BRANCHES면 항상 표" 제거)
- Modify: `lib/cmd/status_branches.zsh` (`_branches_fzf_args`, `_branches_fetch_age`, `cmd___status-branch-preview`)
- Modify: `bin/workytree:76` (`__status-branch-preview`)
- Modify: `README.md:159-166` (키 표에 `ctrl-b`, 브랜치 모드 키 표)
- Test: `tests/status_tui.test.zsh`

**Interfaces:**
- Consumes: Task 5b `_branches_format`, `_status_records`
- Produces:
  - `_status_run_fzf <records> <notes>`: `mode`는 `ST_BRANCHES`로 시작. 모드별 레코드를 루프 안 변수에 보관하고, 처음 들어가는 모드일 때만 `_status_records`로 모은다(전환마다 PR 조회를 다시 하지 않음). 매번 `--expect=ctrl-b`. 출력 첫 줄이 `ctrl-b`면 모드를 바꿔 반복. rc ≠ 0이거나 첫 줄이 빈 줄이면 루프를 끝내고 기존 처리(워크트리 모드 enter → 경로 출력, 브랜치 모드 → 출력 없음)
  - 브랜치 모드 fzf 인자: `--multi`, `--with-nth=18`, `--bind=enter:ignore`, `alt-d:execute($qbin __status-action delete-branches {+f} <reload args>)+deselect-all+reload($branch_rows_cmd)`, `ctrl-r:reload($branch_rows_cmd --fetch)`(offline이면 `--fetch` 없음), `ctrl-s:transform-query(if [ {q} = 'safe$' ]; then echo; else echo 'safe$'; fi)`, `--preview=$qbin __status-branch-preview {}`. `branch_rows_cmd` = 워크트리 `rows_cmd` + ` --branches`
  - 헤더 1줄: `tab: mark · alt-d: delete marked · ctrl-r: refresh with fetch · ctrl-s: safe only · ctrl-b: worktrees`. 2줄: `_branches_fetch_age` 결과 `refs fetched <나이> ago (oldest) in <n> repos — ctrl-r before deleting`, 한 번도 fetch하지 않은 repo가 있으면 `<m> repos never fetched`를 덧붙임
  - 워크트리 모드 헤더 끝에 ` · ctrl-b: branches`, 인자에 `--expect=ctrl-b`
  - `_branches_fetch_age <repo_path...>`: repo마다 `git worktree list --porcelain`의 경로들에서 `git -C <path> rev-parse --path-format=absolute --git-path FETCH_HEAD`(실패 시 `<path>/.git/FETCH_HEAD`)를 얻어, 크기 > 0인 파일의 최신 mtime. `REPLY`=가장 오래된 repo의 나이(초, 없으면 `-`), `reply=(<repo 수> <never fetched 수>)`
  - `cmd___status-branch-preview <line>`: 로컬·원격 sha와 각 `git log --oneline -5`, 각 tip 작성자, PR, note(f17). 네트워크 없음

- [ ] **Step 1: fzf stub 확장**

`fzf_selecting`: 호출마다 인자를 `$HOME/fzf.args`(마지막 호출)와 `$HOME/fzf.args.<n>`(n은 1부터) 둘 다에 쓴다. 배열 `FZF_KEYS`에서 하나씩 꺼낸다. 값은 `ctrl-b`, `''`(enter), `esc`. 비어 있으면 `''`. `esc`면 아무것도 출력하지 않고 130. 그 밖에는 인자에 `--expect=*`가 있을 때 키를 첫 줄로 출력한 뒤, 기존처럼 `FZF_PICK` 줄을 출력한다(없으면 첫 입력 줄).

- [ ] **Step 2: 실패하는 테스트**

| 테스트 | 단언 |
|---|---|
| `test_ctrl_b_switches_to_branch_mode_and_back` | `FZF_KEYS=(ctrl-b ctrl-b esc)`: `fzf.args.2`에 `--multi`, `--with-nth=18`, `alt-d:` 바인딩, `fzf.args.3`에 `--with-nth=27` |
| `test_switching_back_does_not_recollect` | `_status_records`를 세는 래퍼로 감싸 위 시나리오에서 호출 2번 이하(초기 + 브랜치 모드 첫 진입) |
| `test_branch_mode_enter_is_ignored` | `--bind=enter:ignore` 포함, `FZF_KEYS=(ctrl-b '')`에서 출력 없음 |
| `test_branches_flag_starts_in_branch_mode` | `ST_BRANCHES=1`이면 `fzf.args.1`에 `--with-nth=18` |
| `test_branch_bindings_quote_a_bin_path_with_spaces` | `alt-d:execute($qbin __status-action delete-branches {+f} --no-color --offline)+deselect-all+reload($qbin __status-rows --no-color --offline --branches)`와 `ctrl-s:transform-query(if [ {q} = 'safe$' ]; then echo; else echo 'safe$'; fi)` 문자열이 정확히 있음 |
| `test_branch_preview_does_not_touch_the_network` | `git()` 래퍼가 `fetch`·`ls-remote`·`push`를 기록, 미리보기 후 기록 없음, 출력에 note와 작성자 |
| `test_fetch_age_counts_the_main_checkout_and_ignores_empty_files` | 메인 checkout `.git/FETCH_HEAD`(비어 있지 않음, `touch -t` 과거) → `REPLY` > 0. 0바이트면 never fetched 1 |

기존 `test_bindings_quote_a_bin_path_with_spaces`, `test_layout_follows_the_terminal_width_and_toggles`, `test_notes_appear_in_the_header`의 헤더·인자 기대값을 ` · ctrl-b: branches`와 `--expect=ctrl-b`에 맞게 고친다.

- [ ] **Step 3: 실패 확인**

Run: `zsh tests/status_tui.test.zsh`
Expected: 새 테스트 FAIL

- [ ] **Step 4: 구현**

- [ ] **Step 5: 통과 확인**

Run: `zsh tests/run.zsh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/cmd/status.zsh lib/cmd/status_branches.zsh bin/workytree README.md tests/status_tui.test.zsh
git commit -m "feat(status): switch between worktrees and branches with ctrl-b"
```

---

### Task 8a: 삭제 계획(재판정·소유 확인·묶음 출력)

**Files:**
- Modify: `lib/cmd/status.zsh:450-472` (`cmd___status-action`: `delete-branches`는 26필드 검사 **전에** `_branches_delete`로 넘김, usage 문자열 두 곳에 `delete-branches <file>`)
- Modify: `lib/cmd/status_branches.zsh` (`_branches_delete`, `_branches_plan`, `_branches_remote_all_mine`)
- Create: `tests/status_branches_delete.test.zsh` (`helpers.zsh`와 모든 `lib/*.zsh`, `lib/cmd/*.zsh`를 source, `_status_pause() { :; }`, `forge_pr_rows`는 함수로 덮어씀, 응답은 `WORKYTREE_PROMPT_INPUT` 파일(`tests/remove_interactive.test.zsh:18`의 `answers` 패턴))

**Interfaces:**
- Consumes: `status_collect_branches`, Task 4 함수, `wt_fetch_origin`, `forge_pr_rows`, `prompt_confirm`
- Produces:
  - `cmd___status-action delete-branches <records_file> [status opts]` → `_status_parse_opts`로 opts를 읽고 `_branches_delete <records_file>` 호출, rc 0
  - `_branches_delete <records_file>`: records 파일에서 f4(repo_path), f5(branch), f9(owner), f10(why)만 읽는다. 나머지는 쓰지 않는다
  - `_branches_remote_all_mine <repo_path> <base_ref|-> <remote_sha> <user_email>` → rc 0이면 tip 작성자와 `base..sha`(base가 `-`면 tip만)의 모든 작성자가 user_email(대소문자 무시)
  - `_branches_plan` → 전역 배열 `BR_PLAN`, 원소 `class<TAB>repo_path<TAB>branch<TAB>target<TAB>local_sha<TAB>remote_sha<TAB>reason`. class는 `safe|force|skip`, target은 `local|origin|local+origin`

흐름(스펙 "삭제 흐름" 1~4단계):

1. repo별로 표시 이름을 모은다
2. 표시 행 중 owner `me`가 있거나 why `pushed`인 repo는 `wt_fetch_origin`. rc 1이면 그 repo의 `fetch_failed=1`
3. `ST_OFFLINE`가 아니면 repo마다 `forge_pr_rows`를 임시 파일로 받는다(rc ≠ 0이면 파일 없이). 그다음 **항상** `status_collect_branches`로 다시 수집하고 표시 이름의 새 레코드를 쓴다
4. 항목 결정: 새 레코드 없음 → skip `no longer exists`. why `read-only`/`protected` → skip. 원격 쪽은 owner `me`이고 `fetch_failed`가 아니고 `_branches_remote_all_mine` 통과일 때만 대상(실패 사유 `could not fetch origin`, `has commits by others`). `fetch_failed`인 repo의 `pushed`는 force로 내림
5. 출력(stderr): `safe — merged or its ticket is merged`, `needs force — commits would exist nowhere else`, `skipped` 세 머리줄과 항목 줄 `  <repo>  <branch>  <target>  <짧은 sha>  <note 또는 사유>`
6. safe가 있으면 `prompt_confirm "delete the <n> safe refs?" n`, force는 항목마다 `prompt_confirm "force-delete <branch> (<target>) and lose <base_ahead> commits?" n`. 실행은 Task 8b. 이 작업에서는 승인 목록 `BR_APPROVED`(BR_PLAN과 같은 원소 형식)까지만 만든다

- [ ] **Step 1: 실패하는 테스트** (모두 응답 `n`으로 끝나 아무것도 지우지 않는 상태에서 계획 출력과 `BR_PLAN`을 단언)

| 테스트 | 단언 |
|---|---|
| `test_plan_groups_safe_force_and_skipped` | merged·stale·teammate 원격 각 1개 → 각 묶음에 해당 이름 |
| `test_no_to_the_safe_question_deletes_nothing` | 응답 `n` → 모든 ref 그대로, `BR_APPROVED` 비어 있음 |
| `test_backup_of_merged_ticket_is_in_the_safe_group` | `backup/AB-1-pre-squash` + `fix/AB-1` merged PR stub |
| `test_pr_lookup_failure_drops_backup_to_force` | `forge_pr_rows() { return 1; }` → 백업이 needs force |
| `test_offline_still_rejudges_from_current_refs` | `ST_OFFLINE=1`, 레코드 파일의 why를 `merged`로 위조 → 실제 미머지라 needs force |
| `test_remote_with_commits_by_others_is_skipped` | tip은 t@t, 중간 커밋 x@y → target `local`, skipped에 `has commits by others` |
| `test_fetch_failure_skips_remote_and_downgrades_pushed` | 수집 후 `git remote set-url origin ~/nowhere` → 원격 skip `could not fetch origin`, `pushed` 행은 force |
| `test_branch_checked_out_after_collection_is_skipped` | 레코드 파일 작성 후 `git worktree add` → skip |
| `test_vanished_branch_is_skipped` | 레코드 파일 작성 후 브랜치 삭제 → skip `no longer exists` |
| `test_quoted_names_survive_the_records_file` | `fix/q"x`, `fix/a$b'c`(merged), repo 경로에 공백(`~/src/my app`) → 계획에 두 이름이 그대로 |

레코드 파일은 `wt __status-rows --branches --offline --no-color`(또는 `status_collect_branches` + `_branches_format` 출력)에서 필요한 줄을 골라 만든다.

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/status_branches_delete.test.zsh`
Expected: FAIL(`delete-branches` 없음)

- [ ] **Step 3: 구현**

- [ ] **Step 4: 통과 확인**

Run: `zsh tests/run.zsh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/status.zsh lib/cmd/status_branches.zsh tests/status_branches_delete.test.zsh
git commit -m "feat(status): plan branch deletions from fresh refs with ownership checks"
```

---

### Task 8b: 삭제 실행, 결과, 문서

**Files:**
- Modify: `lib/cmd/status_branches.zsh` (`_branches_delete`에 실행·결과 추가)
- Modify: `README.md` 상태 보기 절(브랜치 모드 삭제 흐름, 원격은 본인 커밋만 있는 브랜치만, 삭제 로그·gc 유예)
- Modify: `docs/superpowers/specs/2026-10-23-noninteractive-ux-design.md:243`, `docs/superpowers/specs/2026-10-06-worktree-status-design.md:286-287`
- Test: `tests/status_branches_delete.test.zsh`

**Interfaces:**
- Consumes: Task 8a `BR_APPROVED`, `remove_branch`, `remove_remote_branch`, `_rm_print_results`, `wt_state_dir`, `_status_pause`
- Produces: 승인 항목마다 로컬이 있으면 `remove_branch <repo> <b> 1 <local_sha>`, 그다음 원격이 대상이면 `remove_remote_branch <repo> origin <b> <remote_sha>`. 두 함수의 stdout은 stderr로 보낸다. 결과 행 `ok|fail|skip` + 탭 + `local   <repo>  <branch>  deleted (was <sha>)` 형식으로 `_rm_print_results`, 끝에 `deletion log: <wt_state_dir>/deleted.log`, 마지막에 `_status_pause`

- [ ] **Step 1: 실패하는 테스트**

| 테스트 | 단언 |
|---|---|
| `test_safe_rows_are_deleted_after_one_yes` | merged 로컬 + 본인 원격, 응답 `y` → 로컬·`remote.git` 모두 없음, stderr에 `(was <짧은 sha>)`와 `restore it with:`, 로그 2줄 |
| `test_force_rows_are_asked_one_by_one` | stale 2개, 응답 `y n` → 첫째만 삭제 |
| `test_pushed_row_deletes_local_only` | 동료 원격과 같은 sha 로컬 사본, 응답 `y` → 로컬 없음, 원격 그대로 |
| `test_branch_that_moved_after_judging_is_kept` | `functions -c remove_branch real_remove_branch`, 래퍼가 `git update-ref refs/heads/<b> <새 커밋>` 후 진짜 함수 호출 → 브랜치 유지, 결과 `✗`, 로그에 없음 |
| `test_remote_that_moved_fails_the_lease` | `remove_remote_branch` 래퍼가 두 번째 clone에서 새 커밋을 push한 뒤 진짜 함수 호출 → 원격 유지, 결과 `✗`, 로컬은 삭제 |
| `test_repo_without_origin_deletes_locally_without_fetch` | 원격 없는 repo의 merged 브랜치, `wt_fetch_origin` 래퍼 호출 기록 없음, 로컬 삭제 |

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/status_branches_delete.test.zsh`
Expected: 새 테스트 FAIL

- [ ] **Step 3: 구현**

- [ ] **Step 4: 통과 확인**

Run: `zsh tests/run.zsh && zsh -n bin/workytree lib/*.zsh lib/cmd/*.zsh shell/workytree.zsh shell/completions/_workytree tests/*.zsh`
Expected: PASS, 문법 오류 없음

- [ ] **Step 5: 문서**

README 상태 보기 절에 브랜치 모드 삭제 흐름(계획 → safe 한 번 → force 개별 → 결과), 원격 소유 규칙, 삭제 로그와 gc 유예. 비대화 설계 `:243` 불변식 행 끝에 "예외: 머지된 PR이 있고 열린 PR이 없는 티켓의 백업 브랜치(브랜치 모드, 2026-10-23-branch-cleanup-design)", 상태 설계 `:286-287` 비목표에 "2026-10-23-branch-cleanup-design.md가 대체".

- [ ] **Step 6: Commit**

```bash
git add lib/cmd/status_branches.zsh README.md tests/status_branches_delete.test.zsh docs/superpowers/specs/2026-10-23-noninteractive-ux-design.md docs/superpowers/specs/2026-10-06-worktree-status-design.md
git commit -m "feat(status): delete approved branches and report per-ref results"
```

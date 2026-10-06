# wt status — 워크트리·브랜치 현황 TUI 설계

작성일: 2026-10-06

## 1. 배경과 목표

워크트리와 브랜치는 만들기는 쉽고 치우기는 어렵다. `wt list`는 repo별 `git worktree list`를
그대로 보여 줄 뿐이라, "어느 것이 오래됐고, 어느 것이 이미 머지돼 지워도 되는가"를 판단하려면
repo마다 git·PR 화면을 따로 열어야 한다.

목표:

- config에 등록된 범위(`all_repos`, `--project`) 전체의 워크트리·브랜치를 한 화면에 모은다.
- 정리 판단에 필요한 신호를 행마다 보여 준다: 워크트리 age, 브랜치 age, 연결된 PR/MR,
  머지 여부, upstream 삭제 여부, 커밋 안 된 변경, push 안 된 커밋.
- 그 화면에서 바로 이동(cd)·삭제(`remove`)·PR 열기를 할 수 있다.
- **조회는 아무것도 바꾸지 않는다.** 쓰기 동작은 사용자가 키로 고른 기존 명령(`remove`)과
  명시적 `--fetch`뿐이다.

비목표(§10): PR 리뷰 상태·CI 결과, 브랜치 단독 삭제 액션, 결과 캐시, 전체 화면 자체 TUI.

## 2. 명령 형태

```
wt status [repo] [--fetch|--offline] [--stale [days]] [--json] [--plain]
          [--project p] [--no-color]
```

| 옵션 | 동작 |
|---|---|
| `[repo]` | `resolve_repo`로 repo 하나로 좁힌다 |
| `--fetch` | repo마다 `wt_fetch_origin` 후 수집 (gone/merged 판정을 최신화) |
| `--offline` | fetch와 PR 조회를 모두 하지 않는다 |
| `--stale [days]` | safe·stale 행만 보인다. days를 주면 `stale_days`를 이번 실행만 덮어쓴다 |
| `--json` | JSON 배열을 stdout에 출력 |
| `--plain` | fzf가 있어도 표로 출력 |

`--fetch`와 `--offline`을 같이 주면 usage error(exit 2).

기존 `list`는 바꾸지 않는다. 이름을 `status`로 분리한 것은 `list`의 출력이 `git worktree list`
그대로라는 현재 계약을 유지하기 위해서다.

## 3. 행 종류

| 종류 | 출처 | 비고 |
|---|---|---|
| `worktree` | repo별 `git worktree list --porcelain` | 메인 체크아웃은 `main` 태그, 정리 판정 제외. `worktree_root` 밖의 워크트리는 `external` 태그 |
| `branch` | 어느 워크트리에도 체크아웃되지 않은 `refs/heads/*` | base 브랜치(§4.2) 자체는 제외 |
| `orphan` | `worktree_root/<repo>/<kind>/<ticket>` 중 git이 모르는 디렉터리 | `prune`의 탐지만 재사용(§6.3). cruft-only 여부는 preview에 표시 |
| `error` | 수집에 실패한 repo | repo당 1행. 나머지 repo는 계속 표시 |

워크트리 목록을 디렉터리 순회(`_rm_managed_worktrees`)가 아니라 porcelain에서 얻는 이유:
`worktree_root` 밖에 수동으로 만든 워크트리와 `locked`/`prunable` 상태를 git이 아는 그대로
잡기 위해서다.

## 4. 수집 데이터와 판정 규칙

### 4.1 컬럼

| 컬럼 | 계산 | 판단 불가 시 |
|---|---|---|
| ACTIVE (워크트리 age) | `max(mtime(<gitdir>/index), mtime(<gitdir>/HEAD), mtime(<gitdir>/logs/HEAD))` | `?` |
| COMMIT (브랜치 age) | `for-each-ref --format='%(committerdate:unix)'` — repo당 1회로 전체 브랜치 일괄 | `?` |
| (base 대비 집계) | 같은 `for-each-ref`의 `%(ahead-behind:<base>)`(git 2.41+)와 `for-each-ref --merged=<base>` 1회. 브랜치마다 git을 부르지 않는다. git 2.41 미만이면 브랜치별 `rev-list --left-right --count`로 대체 | — |
| 생성 시각 (preview 전용) | 워크트리: `<gitdir>` birthtime(macOS `stat -f %B`), 없으면 `logs/HEAD` 첫 줄 시각. 브랜치: `git reflog show <branch>` 마지막 항목 | `unknown` |
| MERGED | `for-each-ref --merged=<base>`에 포함 **또는** PR 상태 `merged` | 로컬 판정만 사용 |
| GONE | `%(upstream:track)`이 `[gone]` | — |
| DIRTY | worktree 행만 `_worktree_dirt_kind` → `clean`/`idea-only`/`real`/`unknown`. `GIT_OPTIONAL_LOCKS=0`으로 실행해 `git status`가 index를 다시 쓰지 않게 한다(index mtime이 ACTIVE이므로, 다시 쓰면 조회할 때마다 모든 워크트리가 "방금 활동"이 된다). repo 안에서 최대 4개 병렬 | `unknown` |
| AHEAD/BEHIND | upstream 대비: `%(upstream:track)`. base 대비: `rev-list --left-right --count <base>...<branch>` | `-` |
| LOCKED / PRUNABLE | porcelain의 `locked`, `prunable` 줄 | — |
| PR | §5 | `-` |
| SIZE | preview에서만 `du -sk` | — |

age 표시 형식: 60분 미만 `<1h`, 24시간 미만 `Nh`, 14일 미만 `Nd`, 8주 미만 `Nw`, 이후 `Nmo`
(30일 단위), 2년 이상 `Ny`. JSON에는 초 단위 정수로 넣는다.

목록의 age는 "마지막 활동/마지막 커밋" 기준이다. 정리 판단은 "얼마나 방치됐나"가 핵심이고,
생성 시각은 Linux birthtime 부재·reflog 만료로 부정확할 수 있어 preview 보조 정보로만 둔다.

### 4.2 base ref

다음 순서로 처음 존재하는 것을 쓴다. repo당 1회 결정한다.

1. `refs/remotes/origin/HEAD`가 가리키는 ref
2. `refs/remotes/origin/main`, `refs/remotes/origin/master`
3. 메인 체크아웃의 현재 브랜치

`remove`의 merged 판정(upstream → HEAD)과 기준이 다르다. `remove`는 "`git branch -d`가
거부할지"를 묻고, status는 "기본 브랜치에 들어갔는가"를 묻기 때문이다.

squash/rebase 머지는 커밋 SHA가 바뀌어 `--is-ancestor`가 놓친다. PR 상태 `merged`가 이 경우의
유일한 근거이며, `--offline`이거나 forge CLI가 없으면 탐지되지 않는다(README에 명시).

### 4.3 종합 플래그

| 플래그 | 태그 | 조건 |
|---|---|---|
| `✓` | `safe` | (MERGED 또는 PR `merged`/`closed` 또는 GONE) **이고** DIRTY ∈ {clean, idea-only, 해당 없음} **이고** upstream 대비 ahead = 0 **이고** not locked |
| `●` | `stale` | safe가 아니고, ACTIVE(branch 행은 COMMIT)가 `stale_days`보다 오래됨 |
| `!` | `dirty` | DIRTY ∈ {real, unknown} 또는 upstream 대비 ahead > 0 (upstream 없으면 base 대비 ahead > 0이고 MERGED 아님) |
| ` ` | — | 그 외 |

우선순위는 `!` > `✓` > `●`이다. `!`인 행은 오래됐어도 `●`로 표시하지 않는다. 지우면 작업을
잃는 행이라는 사실이 가장 중요하기 때문이다.

`unknown`은 절대 `safe`가 되지 않는다(R24: 판단 불가를 clean으로 취급하지 않는다).
PR `closed`(머지 없이 닫힘)는 버려진 작업으로 보고 safe 근거에 포함한다. 단 dirty·ahead
조건은 그대로 적용되므로 로컬에만 있는 작업은 보호된다. PR의 `merged`/`closed`는 로컬 브랜치
tip이 그 PR의 head 커밋과 같을 때만 판정 근거로 쓴다. 머지 뒤에 커밋을 더했거나 같은 이름의
브랜치를 다시 쓴 경우에는 PR 상태를 표시만 하고 판정에서는 무시한다.
`main`, `orphan`, `error` 행은 플래그를 계산하지 않는다.

## 5. PR/MR 조회 (`lib/forge.zsh`)

### 5.1 forge 판별

`git remote get-url origin`의 호스트로 판별한다(https, `git@host:`, `ssh://` 형식 모두).

1. 호스트가 `github.com`이거나 `gh auth status --hostname <host>`가 성공 → `github`
2. `glab auth status --hostname <host>`가 성공 → `gitlab`
3. 그 외 → `none`

`glab auth status`는 네트워크를 타므로(실측 약 0.8초) 판별 결과를 호스트별로 `WT_FORGE_KINDS`에
캐시한다. `status`는 repo별 job을 띄우기 전에 호스트마다 한 번 판별해 두고, job은 fork 시점에
이를 상속한다.

### 5.2 조회

repo당 네트워크 호출 1회:

- github: `gh pr list --repo <host/owner/name> --state all --limit 200 --json number,state,isDraft,headRefName,url,headRefOid,updatedAt`
- gitlab: `glab mr list -R <origin URL> --all --per-page 100 -F json` (`-R`은 Git URL을 그대로 받으므로
  self-hosted 호스트가 보존된다)

출력을 `branch<TAB>번호<TAB>상태<TAB>url<TAB>head_sha` 행으로 정규화한다(GitLab은 `sha`). 상태는 `open`/`draft`/`merged`/
`closed` 넷 중 하나다. 같은 브랜치에 PR이 여럿이면 `updatedAt`(GitLab은 `updated_at`)이 가장
최근인 것 하나만 남긴다. JSON 파싱은 `jq`에 의존하지 않는다. 두 CLI 모두 내장 `--jq`로 탭 구분
출력을 만든다(gh 2.98, glab 1.118에서 실측).

`GIT_TERMINAL_PROMPT=0`, 그리고 CLI별 비대화 환경변수(`GH_PROMPT_DISABLED=1`,
`GLAB_NO_PROMPT=1`)로 인증 프롬프트가 화면을 막지 않게 한다. repo당 15초 timeout을 둔다.

### 5.3 실패 처리

CLI 없음, 미인증, timeout, 비정상 종료 모두 그 repo의 PR 컬럼을 `-`로 두고 이유를 한 줄
남긴다. origin이 없는 repo는 실패가 아니라 조회할 대상이 없는 것이므로 note 없이 넘어간다. 이유는 repo 단위로 모아 표/fzf 헤더 아래 한 번씩만 보여 준다(행마다 반복하지 않는다).
exit code는 0을 유지한다. PR은 보조 신호이고, 로컬 신호만으로도 화면은 유효하기 때문이다.

## 6. 구조

### 6.1 파일과 책임

| 파일 | 책임 |
|---|---|
| `lib/forge.zsh` (신규) | §5 전체. `forge_kind <repo_path>`, `forge_pr_rows <repo_path>` |
| `lib/status.zsh` (신규) | repo 1개 → 행 TSV. §3·§4 판정, age 포맷, base ref, JSON escape |
| `lib/cmd/status.zsh` (신규) | `cmd_status`(옵션·병렬 수집·렌더러 선택), `cmd___status-rows`(fzf reload용 행 출력), `cmd___status-preview`, `cmd___status-action`(ctrl-d/ctrl-o가 부르는 내부 명령: 행 종류 확인 후 `cmd_remove` 또는 브라우저) |
| `lib/config.zsh` | `ai_setting`의 본문을 `project_setting <project> <key>`로 옮겨 `stale_days`와 공유. `ai_setting`은 위임만 한다 |
| `lib/ui.zsh` | `ui_init force`: stdout이 TTY가 아니어도 색을 켠다(fzf 입력, wrapper가 캡처하는 출력) |
| `lib/cmd/prune.zsh` | orphan 후보 탐지를 함수로 분리(§6.3). 동작 변경 없음 |
| `bin/workytree` | dispatch 목록과 `usage()`에 추가 |
| `shell/workytree.zsh` | wrapper의 cd 대상 명령에 `status` 추가 |
| `shell/completions/_workytree`, `lib/cmd/complete.zsh` | `status`와 옵션 자동완성 |

### 6.2 행 형식

탭 구분. 앞쪽은 숨김 필드, 뒤쪽은 표시 필드다. fzf는 `--delimiter '\t' --with-nth <표시 시작>..`
으로 표시 필드만 보여 주고, preview·액션은 `{n}` 치환으로 숨김 필드를 받는다. 화면 문자열을
다시 파싱하지 않으므로 공백이 든 경로도 안전하다.

필드 1–26은 원본 레코드(`lib/status.zsh` 머리 주석이 번호를 정의한다. 빈 값은 모두 `-`로,
zsh `read`가 연속 탭을 합쳐 빈 필드를 잃는 문제를 피한다), 필드 27은 정렬·패딩된 표시 문자열
(`mark repo branch active commit state pr tags`)이다. fzf는 `--with-nth=27`로 27만 보여 주고
검색도 27 안에서만 한다. 그래서 `tags`(`safe stale dirty merged gone locked prunable main external
orphan`)를 표시 문자열 끝에 흐린 색으로 둔다. `ctrl-s`의 `stale` 쿼리와 직접 입력한 `gone` 등이
여기에 매칭된다.

### 6.3 orphan 탐지 분리

현재 `prune_repo`는 `git worktree prune`(쓰기) → 등록 목록 수집 → 후보 순회와 삭제를 한
함수에서 한다. 이 중 "등록 목록 수집 + 후보 순회 + containment guard"를
`_prune_orphan_candidates <project> <repo> <repo_path>`(NUL 구분 출력)로 분리한다.
`prune_repo`는 기존처럼 `git worktree prune` 후 이 함수를 호출해 삭제한다.
status는 **`git worktree prune` 없이** 이 함수만 호출한다. 그래서 git에 등록됐지만 디렉터리가
사라진 항목은 `prunable` worktree 행으로 보인다.

등록 목록 조회에 실패하면 기존 R24 규칙대로 빈 결과가 아니라 실패를 반환한다. status는 그
repo에 orphan 행을 만들지 않고, 이유를 §5.3과 같은 방식으로 한 줄 남긴다.

### 6.4 실행 흐름

1. `require_config` → 대상 repo 목록(`all_repos "$WT_PROJECT_OPT"` 또는 `resolve_repo`).
2. repo마다 백그라운드 job: (`--fetch`면 `wt_fetch_origin`) → `forge_pr_rows` → 로컬 수집 →
   `mktemp -d` 아래 `<순번>.rows`, `<순번>.notes`에 기록. 동시 실행은 최대 8개이며, 배치 단위가
   아니라 풀 방식이다(zsh에는 `wait -n`이 없어 `$jobstates` 수를 `zselect`로 폴링). 배치 단위로
   기다리면 느린 repo 하나가 배치 전체를 붙잡는다.
3. 전부 끝나면 순번 순서로 합친다. 실행마다 출력 순서가 같아야 테스트와 사용자 기억이 맞는다.
   수집 중에는 stderr에 `ui_progress`를 표시한다(stderr가 TTY일 때만).
4. 렌더러 선택:
   - `--json` → JSON
   - `--plain`, fzf 없음, fzf < 0.38, stdin 또는 stdout이 TTY 아님 → 표
   - 그 외 → fzf

임시 디렉터리는 EXIT trap으로 지운다.

## 7. 렌더러

### 7.1 표

컬럼 `FLAG REPO BRANCH ACTIVE COMMIT STATE PR TAGS`. STATE는 `merged`/`gone`/`dirty`/`locked`/
`prunable`/`↑N ↓M` 중 해당하는 것을 짧게 잇는다. 정렬은 종류(worktree → branch → orphan →
main → error) 다음 age 오래된 순이다. 메인 체크아웃은 정리 대상이 아니므로 정리 후보 아래에 둔다. 색은 기존 `ui.zsh` 규칙(TTY + `NO_COLOR` 미설정 + `--no-color`
아님)을 따른다. 행이 없으면 `no worktrees or branches found`를 stderr에 쓰고 exit 0.

### 7.2 JSON

행마다 객체 하나인 배열. 키: `type project repo path kind ticket branch flag tags active_age_s
commit_age_s created_at merged gone dirty ahead behind base_ahead base_behind locked prunable pr note`
(`pr`은 `{number,state,url}` 또는 `null`, `note`는 error 행의 사유). notes는 `{"notes":[...],"rows":[...]}`의 `notes`에
넣는다. `jq` 없이 zsh로 escape한다(`"`, `\`, 제어문자).

### 7.3 fzf (최소 0.38)

| 키 | 바인딩 | 대상 |
|---|---|---|
| `enter` | fzf 종료 → path를 stdout 마지막 줄에 출력 | worktree·main 행. 그 외 행이면 출력 없이 종료 |
| `ctrl-d` | `execute(<bin> __status-action remove {})+reload(<bin> __status-rows <원래 옵션>)`. `__status-action`이 관리 대상 worktree 행이면 `cmd_remove`를 실행하고, 아니면 이유와 수동 명령 힌트를 보여 준다. 결과를 읽을 수 있게 키 입력을 기다린 뒤 목록으로 돌아간다 | 관리 대상 worktree 행만 |
| `ctrl-o` | `execute-silent(<bin> __status-action open {})` → `open` 또는 `xdg-open` | PR이 있는 행 |
| `ctrl-r` | `reload(<bin> __status-rows --fetch <원래 옵션>)` | 전체 |
| `ctrl-s` | 쿼리가 `stale`이면 비우고, 아니면 `change-query(stale)` | 전체 |
| `esc` | 출력 없이 exit 0 | — |

`<bin>`은 `$WORKYTREE_HOME/bin/workytree` 절대 경로다(셸 함수 `wt`는 fzf 자식 셸에 없다).
바인딩 문자열에 들어가는 모든 값은 `${(q)}`로 quoting한다.

`ctrl-d`의 `remove`는 fzf가 넘겨주는 TTY에서 대화형으로 실행돼 기존 질문(dirty 처리, 로컬·원격
브랜치 삭제)을 그대로 쓴다. 이 자식 프로세스에는 `WORKYTREE_CD_CAPABLE`을 넘기지 않으므로
destination 질문은 나오지 않는다.

헤더에는 키 안내 한 줄과 §5.3 notes를 표시한다. preview 창은 오른쪽 50%에 두고, 터미널 폭이
120 미만이면 아래쪽 50%에 둔다.

### 7.4 preview (`__status-preview <type> <repo_path> <path> <branch>`)

- 전체 경로, 종류·태그
- 워크트리 생성 시각 / 마지막 활동, 브랜치 생성 시각 / 마지막 커밋(시각 + 상대 age)
- base·upstream 대비 ahead/behind
- PR 번호·상태·URL
- `git status --short` 상위 15줄(초과분은 개수만), 최근 커밋 5개(`--oneline`)
- 디스크 사용량(`du -sk`, 선택한 행만 계산)
- orphan 행: cruft-only 여부와 수동 정리 명령 힌트(`wt prune <repo>`)
- branch 행: 수동 삭제 명령 힌트(`git -C <repo> branch -d <branch>`)

### 7.5 종료 처리

fzf가 끝났을 때 `$PWD`가 더는 존재하지 않으면(`ctrl-d`로 서 있던 워크트리를 지운 경우)
enter 선택이 없어도 그 워크트리가 속했던 repo의 메인 체크아웃 경로를 마지막 줄로 출력한다.
`remove`의 "소스 repo로 이동"과 같은 결과다. CLI는 호출한 셸의 cwd를 물려받으므로 별도 전달
없이 `[[ -d $PWD ]]`로 판단한다. 어느 repo였는지는 시작 시점에 `$PWD`를 포함하는 worktree 행으로
기억해 둔다.

## 8. shell wrapper

`shell/workytree.zsh`의 cd 대상 case에 `status`를 추가한다. 동작은 기존 규약 그대로다. stdout
마지막 줄이 디렉터리면 cd하고, 비어 있으면 아무것도 하지 않는다. fzf는 화면을 `/dev/tty`에
직접 그리므로 stdout 캡처와 충돌하지 않는다.

`--json`/`--plain` 출력도 이 캡처를 거친다. 마지막 줄이 디렉터리가 아니므로 cd 없이 그대로
출력되지만, 출력이 커지면 스크립트는 wrapper가 아니라 `bin/workytree status --json`을 직접
호출하는 것이 맞다(README에 명시).

## 9. config

| 키 | 범위 | 기본값 | 의미 |
|---|---|---|---|
| `stale_days` | 전역, `[project]` | `30` | stale 임계값(일). `--stale <days>`가 1회 덮어씀 |

조회 순서는 `[project]` → 전역 → 기본값으로, `ai_session`과 같다. 양의 정수가 아니면 경고
한 줄 후 30을 쓴다.

## 10. 비목표

- PR 리뷰 상태, CI 결과: repo당 추가 API 호출이 필요하고 정리 판단에는 상태만으로 충분하다.
- branch 행의 삭제 액션: 이번 범위의 삭제는 기존 `remove` 재사용으로 한정한다. preview에 수동
  명령만 안내한다.
- PR 결과 캐시: 무효화 규칙이 필요하다. 느리다는 실측이 생기면 §6.4의 수집 단계 앞에 추가한다.
- 자체 전체 화면 TUI, fzf 스트리밍 표시(`--listen`).

## 11. 테스트

`bin/workytree`는 시스템 경로를 PATH 앞에 붙이므로, PATH에 가짜 실행 파일을 넣는 방식
(`fake_agent`)으로는 설치된 `gh`/`glab`/`fzf`를 가릴 수 없다. 외부 CLI가 필요한 테스트는 lib를
직접 source하고 같은 이름의 셸 함수로 stub한다(함수가 외부 명령보다 먼저 찾아진다). 테스트용
환경변수 훅은 제품 코드에 넣지 않는다.

| 파일 | 방식 | 검증 |
|---|---|---|
| `tests/status.test.zsh` | CLI, `--offline --json`/`--plain` | §11.1 시나리오 |
| `tests/status_internal.test.zsh` | lib source | age 포맷 경계값, §4.3 판정표 전 조합, base ref 결정 순서, JSON escape |
| `tests/forge.test.zsh` | lib source + `gh`/`glab` 함수 stub | URL 형식별 판별(https/ssh/scp형/self-hosted), 정규화, 같은 브랜치 다중 PR, CLI 없음·미인증·비정상 종료 시 빈 결과 + note |
| `tests/status_tui.test.zsh` | lib source + `fzf` 함수 stub(인자 기록, 정해진 선택 반환) | enter → 마지막 줄 path, esc → 무출력 exit 0, 바인딩 quoting(공백 든 경로), §7.5 사라진 `$PWD` 처리, fzf < 0.38 → 표 |
| `tests/prune.test.zsh` (기존) | 그대로 통과 | §6.3 분리 후 회귀 없음 |
| `tests/shell.test.zsh` (추가) | 기존 방식 | `status` 마지막 줄로 cd, 빈 출력이면 cd 없음 |
| `tests/complete.test.zsh` (추가) | 기존 방식 | `status`와 옵션 |

### 11.1 CLI 시나리오

시각은 `GIT_COMMITTER_DATE`와 `touch -t`로 과거에 고정하고, 경계는 넉넉하게(예: 100일 전 →
stale) 잡아 실행 시점에 따라 결과가 흔들리지 않게 한다.

1. base에 머지된 깨끗한 워크트리 → `✓`
2. 100일 전 커밋, 머지 안 됨, 깨끗함, upstream과 같은 위치까지 push됨 → `●`
   (upstream이 없으면 §4.3에 따라 로컬 전용 작업이므로 `!` — 별도 케이스로 확인)
3. 추적 안 되는 파일 → `!`. `.idea/`만 있으면 `✓` 유지
4. upstream이 지워진 브랜치(로컬 bare remote에서 삭제 후 `fetch --prune`) → `gone`, `✓`
5. upstream보다 ahead → `!`
6. locked 워크트리 → `✓` 아님
7. 워크트리 없는 브랜치 → `branch` 행. base 브랜치는 행 없음
8. orphan 디렉터리 → `orphan` 행, 디렉터리는 그대로 존재(조회가 지우지 않음)
9. 메인 체크아웃 → `main` 태그, 플래그 없음
10. `--project`, `[repo]`, `--stale`, `--stale 0`, `--fetch --offline` 동시 지정 → exit 2
11. 읽을 수 없는 repo 하나 → 그 repo만 `error` 행, 나머지 정상, exit 0
12. stdout이 TTY가 아님 → fzf 설치 여부와 무관하게 표

CI는 변경하지 않는다. CI에는 fzf·gh·glab이 없지만 위 테스트는 stub과 비대화 출력만 쓴다.
lint job의 `zsh -n` 루프가 `lib/*.zsh`, `lib/cmd/*.zsh` glob을 쓰므로 새 파일도 자동 포함된다.

## 12. 문서

- `README.md`: Usage에 `wt status` 추가, "Status" 섹션 신설 — 행 종류·플래그 의미, 키 바인딩,
  `gh`/`glab`/`fzf` 선택 의존성과 인증, `--fetch`/`--offline`, squash 머지는 PR 상태로만
  탐지된다는 한계, 스크립트는 `bin/workytree status --json`을 직접 호출할 것.
- `usage()`, completion 갱신.

## 13. 구현 순서

각 단계 끝에서 `zsh tests/run.zsh` 전체 통과를 유지한다.

1. `lib/forge.zsh` + `tests/forge.test.zsh`
2. `lib/cmd/prune.zsh` orphan 탐지 분리(기존 prune 테스트로 회귀 확인)
3. `lib/status.zsh` 수집·판정 + `tests/status_internal.test.zsh`
4. `cmd_status`의 `--json`/`--plain`, 병렬 수집 + `tests/status.test.zsh`
5. fzf 렌더러·preview·액션·§7.5 + `tests/status_tui.test.zsh`
6. wrapper, completion, `stale_days`, README

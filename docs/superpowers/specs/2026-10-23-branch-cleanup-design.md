# wt status 브랜치 모드 설계

작성일: 2026-10-23

`wt status`에 브랜치 전용 화면(브랜치 모드)을 더한다. 각 repo의 로컬 브랜치와 `origin` 원격 브랜치를 한 행에 묶어 "왜 지워도 되는가"를 보여 주고, 표시한 행을 계획 → 확인 → 삭제 → 결과 순서로 지운다. 조회는 지금처럼 아무것도 바꾸지 않는다.

## 배경

워크트리는 `wt remove`로 치우지만 브랜치 잔해는 남는다. 2026-10-23에 등록된 repo 35개를 읽기 전용으로 조사한 결과다(fetch 없이 로컬 ref 기준).

| 사용자가 말한 경우 | 실측 | 지금 남는 이유 |
|---|---|---|
| `remove` 중 브랜치 삭제 실패 후 방치 | 워크트리 없는 `<kind>/<ticket>` 로컬 브랜치 129개. 그중 upstream이 gone이고 ancestry로는 머지가 아닌 것 25개 | squash 머지는 `git branch -d`가 거부함. 실패는 stderr 경고로만 남음 |
| 워크트리에서 만든 백업 브랜치 방치 | `backup/*` 70개, 모두 로컬 전용. 57개가 다른 ref에 없는 커밋을 가짐 | upstream이 없고 머지 판정도 불가해 영원히 `!`. `--stale` 필터에도 안 걸림 |
| 오래된 브랜치 방치 | 워크트리 없는 로컬 295개. `origin` 전용 889개(1년 초과 150개) | 원격 브랜치는 수집하지 않음. 로컬 branch 행은 지울 수단이 없음 |

원격 전용 889개 가운데 마지막 커밋 작성자가 사용자 본인인 것은 87개다. 대부분 동료의 브랜치이므로 원격 삭제에는 소유 확인이 필요하다.

`status_flag`(`lib/status.zsh:105`)는 upstream이 gone이거나 PR이 tip에서 closed이면 머지되지 않았어도 `✓`를 준다(README "상태 보기"의 표, `tests/status_internal.test.zsh:26,28`). 반면 `remove`의 `branch_verdict`는 gone이면 `unmerged`, closed PR이면 `pushed`로 판정하고 둘 다 기본값 No로 묻는다(T7-1). 두 판정이 어긋난 채로 `✓`에 일괄 삭제를 붙이면 작업이 사라진다.

## 사용자 결정

| 항목 | 결정 |
|---|---|
| 백업 브랜치 | 해당 티켓이 머지되면 그 티켓의 백업은 지운다 |
| 복구 수단 | 지울 때 sha와 복구 명령을 출력하고 삭제 로그 파일에도 남김. 보관용 ref는 만들지 않으며, 다른 ref에 없는 커밋은 gc 유예(기본 `gc.pruneExpire=2.weeks.ago`)가 지나면 복구할 수 없음을 감수 |
| 화면 배치 | 기존 목록에 섞지 않고 `ctrl-b`로 전환하는 브랜치 모드. 로컬과 원격을 한 행에 나란히 표시 |
| 삭제 흐름 | 아래 "삭제 흐름"의 계획 → safe 일괄 확인 → force 개별 확인 → 결과 순서 |
| 백업 확인 방식 | 머지된 티켓의 백업은 safe 묶음에서 한 번에 확인하고 지움. 비대화 설계 §3.14에 예외로 추가 |
| 워크트리 목록의 branch 행 | 브랜치 모드로 옮김. 워크트리 목록에는 워크트리·orphan·error 행만 남음 |

나머지 규칙 중 Claude가 정한 것은 "결정 사항" 표의 "누가" 열에 표시했다.

## 목표

- 범위 안 repo의 로컬·`origin` 브랜치를 한 화면에서 보고, 행마다 삭제 근거(WHY)를 확인한다
- squash 머지된 브랜치와 머지된 티켓의 백업을 "안전"으로 판정한다
- 표시한 여러 행을 한 번에 지우되, 판정한 sha와 다르면 지우지 않는다
- 모든 삭제에 `(was <sha>)`와 복구 명령을, 모든 실패에 이유와 재시도 명령을 출력한다
- 워크트리 목록의 `✓`와 `remove`의 머지 판정을 일치시킨다

## 비목표

| 항목 | 이유 |
|---|---|
| `origin` 외 원격 삭제 | PR 조회가 `origin`만 대상이고(`lib/forge.zsh:103`), fork·upstream은 대개 사용자 소유가 아님 |
| repo별 base 지정 | mobidoc-migration처럼 `origin/HEAD`가 실제 통합 브랜치가 아닌 repo가 있지만 별도 기능. 이번에는 기존 `status_base_ref`를 그대로 씀 |
| patch-id·임시 커밋 기반 squash 탐지 | `commit-tree` 방식은 객체를 씀. 머지 근거는 ancestry와 PR만 씀 |
| 실패 기록 파일 | 잔해가 생기는 근본 원인은 squash 판정 실패. 판정을 고치면 잔해가 `merged`/`backup` 행으로 다시 드러남. 실패한 ref는 지워지지 않았으므로 목록에 그대로 남음 |
| 보관용 ref(`refs/wt-archive/*`) | 사용자 결정. gc 유예를 감수 |
| 삭제 로그 회전·정리 | 한 줄이 짧고 삭제 빈도가 낮음. 크기가 문제 되면 별도로 다룸 |
| 로컬만·원격만 지우는 키 | 사용자 결정. 한 행은 그 브랜치의 로컬과 본인 원격 둘 다 |
| 비대화 일괄 삭제 | 삭제는 fzf 안에서만. `-y`·터미널 없음에서는 브랜치 모드도 표로만 출력 |
| 동료 원격 브랜치 삭제 | 소유 판정 참고 |

## 행 모델

브랜치 모드의 한 행은 repo 하나의 브랜치 이름 하나다. `refs/heads/<b>`와 `refs/remotes/origin/<b>`를 이름으로 짝짓는다. upstream 설정은 짝짓기에 쓰지 않는다. 조사에서 로컬 브랜치 14개가 같은 이름이 아닌 base를 추적하고 있었기 때문이다.

| 열 | 내용 |
|---|---|
| REPO | repo 이름 |
| BRANCH | 브랜치 이름 |
| LOCAL | `●` 있음, `-` 없음 |
| REMOTE | `● me`, `● teammate`, `gone`(로컬 upstream이 삭제됨), `-` |
| WHY | 아래 "분류"의 등급 |
| COMMIT | 로컬·원격 중 최신 커밋 나이 |

행에서 빼는 것:

- base 브랜치와 `origin/HEAD`
- 어느 워크트리에든 체크아웃된 브랜치. 워크트리 목록의 `ctrl-d`(`remove`)로 다룸

보호 브랜치 `main`, `master`, `develop`, `release/*`는 행으로 보이지만 WHY가 `protected`이고 지울 수 없다. gitflow repo에서 base가 `develop`이면 뒤처진 `master`가 ancestry상 `merged`가 되기 때문이다.

헤더에 `origin` ref의 대략적인 마지막 fetch 시점을 항상 표시한다. repo마다 메인 checkout과 링크된 워크트리의 `FETCH_HEAD`(`git rev-parse --path-format=absolute --git-path FETCH_HEAD`) 중 비어 있지 않은 파일의 가장 최근 mtime을 쓴다. 그런 파일이 없는 repo는 "never fetched"로 센다. 실패한 fetch는 이 파일을 0바이트로 만들고, 다른 원격 fetch도 mtime을 바꾸므로 참고 값일 뿐이다. 원격 삭제 직전에는 어차피 다시 fetch한다("삭제 흐름" 1단계).

## 소유 판정

원격 쪽이 사용자 것인지는 두 단계로 판정한다.

1. 목록: `origin/<b>` tip의 `%(authoremail:trim)`이 그 repo의 `git config user.email`과 같으면 `me`, 아니면 `teammate`로 표시한다. `for-each-ref` 한 번으로 얻으므로 추가 비용이 없다. `%(authoremail)`은 `<...>`를 포함하므로 `:trim`이 필요하다
2. 삭제 계획: tip 작성자가 본인이고, base에 없는 커밋 중 다른 작성자의 커밋이 하나도 없을 때만 원격을 지운다. 표시한 행에만 `rev-list` 한 번씩 실행한다

이메일 비교는 대소문자를 구분하지 않는다. `user.email`이 비어 있으면 모든 원격을 `teammate`로 본다.

## 분류

로컬과 원격을 각각 판정한다. 행의 WHY는 **이번에 지울 쪽** 중 더 위험한 등급이다. 지우지 않을 `teammate` 원격은 WHY에 넣지 않는다.

| WHY | 조건 | 삭제 등급 |
|---|---|---|
| `merged` | tip이 base의 조상이거나, PR이 그 tip에서 머지됨(`status_merged_rule`) | safe |
| `pushed` | 로컬만 지우고, 로컬 tip이 남겨 둘 `origin/<b>`와 같거나(upstream이 `origin/<b>`이고 ahead 없음 포함) 그 조상 | safe (잃는 커밋 없음) |
| `backup` | 이름이 백업 패턴이고, 이름에서 뽑은 티켓 키가 "머지된 티켓"(아래) | safe (고유 커밋을 잃을 수 있음, 사용자 결정) |
| `gone` | 로컬 upstream이 삭제됐고 머지가 증명되지 않음 | force |
| `stale` | 최신 커밋이 `stale_days`보다 오래됐고 머지가 증명되지 않음 | force |
| `unmerged` | 그 밖의 모든 경우 | force |
| `read-only` | 원격만 있고 소유 판정에서 `teammate` | 삭제 불가 |
| `protected` | 보호 브랜치 | 삭제 불가 |

### 백업 판정

백업 패턴은 조사에서 실제로 나온 형태로 고정한다. 대소문자는 구분하지 않는다.

| 패턴 | 예 |
|---|---|
| `backup/*` | `backup/mpt-9167-pre-amend2`, `backup/mr5-pre-squash3-0902-1637` |
| `*-backup` · `*-backup-*` | `mpt-9412-backup-pre-squash`, `jeje-preview-backup-20260825` |
| `*-before-*` | `mpt-9641-before-squash` |

티켓 키는 `[A-Za-z]{2,}-[0-9]+` 중 첫 번째로, 이름의 처음이나 `/`·`-`·`_` 바로 뒤에서 시작하고 이름의 끝이나 `/`·`-`·`_` 바로 앞에서 끝나야 한다(`fix/ABC-12x`에는 키가 없음). `backup`, `before`, `pre`로 시작하는 후보는 키가 아니다. 키 비교는 대소문자를 구분하지 않고, 다른 브랜치 이름 안에서도 같은 경계 규칙으로 찾는다(`mpt-916`은 `mpt-9167`과 맞지 않음).

| 이름 | 키 |
|---|---|
| `backup/mpt-9167-pre-amend2` | `mpt-9167` |
| `backup/MPT-9777-local-a8dae-20261006` | `MPT-9777` |
| `backup/mr5-pre-squash3-0902-1637` | 없음 |
| `jeje-preview-backup-20260825` | 없음 |

키를 뽑지 못하면 WHY는 일반 규칙(`stale`/`unmerged`)을 따른다.

"머지된 티켓"은 다음을 모두 만족할 때다.

- head 브랜치 이름에 그 키가 들어간 PR 중 `merged` 상태인 것이 있음
- 그 키를 head에 가진 PR 중 열린 것이 없음

티켓 브랜치가 ancestry로만 머지된 경우는 근거로 쓰지 않는다. 티켓 브랜치를 base로 되돌리거나 새로 만들면 커밋 없이도 `merged`가 되므로, 그 전에 떠 둔 백업이 유일한 사본일 수 있기 때문이다. 오프라인이거나 PR 조회 범위(GitHub 200건, GitLab 100건, 브랜치별 최신 PR만: `lib/forge.zsh:80-117`)를 넘으면 증명할 수 없고, 백업은 `stale`/`unmerged`로 남는다.

## 워크트리 목록의 ✓ 정정

`status_flag`를 두 군데 고친다.

- safe 조건에서 "gone"과 "PR closed at tip"을 뺀다
- dirty 조건의 "upstream 없음"에 "upstream이 gone"을 포함한다. gone이면 원격 사본이 사라져 로컬이 유일한 사본이다

| 상태 | 지금 | 바뀐 뒤 |
|---|---|---|
| gone, 머지 안 됨, base보다 앞섬 | `✓` | `!` |
| PR closed at tip, 원격 살아 있음 | `✓` | `●` 또는 빈 칸(나이 기준) |
| 머지됨 | `✓` | `✓` |

README의 `✓` 설명과 `tests/status_internal.test.zsh`의 판정표를 같이 고친다. `remove`의 `branch_verdict`는 바꾸지 않는다.

## 워크트리 목록에서 branch 행 이동

워크트리 없는 로컬 브랜치(`branch` 행)는 워크트리 목록에서 빠지고 브랜치 모드에만 나온다(사용자 결정). 바뀌는 동작은 다음과 같다.

| 대상 | 지금 | 바뀐 뒤 |
|---|---|---|
| `wt status` fzf 목록 | worktree·branch·orphan·error 행 | worktree·orphan·error 행 |
| `wt status --plain` / `--json` | `type: "branch"` 행 포함 | 포함 안 함. `--branches`를 붙여야 나옴 |
| `wt status --stale` | safe·stale인 branch 행 포함 | 포함 안 함 |
| 상세 창·`ctrl-d`의 branch 분기 | `git branch -d` 안내 | 분기 삭제 |

`--json`에서 `branch` 행이 사라지는 것은 스크립트 사용자에게 호환성이 깨지는 변경이므로 README에 적는다.

## 화면과 키

`ctrl-b`로 워크트리 목록과 브랜치 모드를 오간다. `wt status --branches`는 브랜치 모드로 시작하고, `--plain`·`--json`·`-y`에서는 같은 행을 표나 JSON으로 출력한다.

| 키 (브랜치 모드) | 동작 |
|---|---|
| `tab` / `shift-tab` | 행 표시·해제 |
| `alt-d` | 표시한 행(없으면 현재 행)을 "삭제 흐름"으로 넘김. 끝나면 표시를 지우고 새로고침 |
| `ctrl-r` | 모든 repo `git fetch --prune origin` 후 새로고침 (워크트리 목록과 같은 동작) |
| `ctrl-s` | safe 행만 보기 |
| `ctrl-b` | 워크트리 목록으로 |
| `enter` | fzf를 끝내지 않고 목록 유지 |

fzf 최소 버전은 0.38(`lib/cmd/status.zsh:7`)이다. 0.38에는 `transform`(0.45)과 `change-header`(0.40)가 없으므로 다음 제약이 생긴다.

- tab 표시를 행마다 막을 수 없다. 지울 수 없는 행도 표시되고, 계획 단계에서 skipped로 빠진다
- 같은 키가 모드마다 다르게 동작하려면 바인딩 명령이 현재 모드를 알아야 한다(모드 상태 파일, `--header-lines`를 `reload`로 교체, 또는 `become`으로 fzf 재실행 등)
- `enter`를 모드에 따라 다르게 하려면 위와 같은 방법이 필요하다

상세 창은 로컬·원격 각각의 sha, 최근 커밋 5개, 작성자, PR, 백업 이름이면 키와 그 키의 PR 판정(`PR !5 merged`, `PR !5 open`, `no merged PR`, `PR lookup skipped`)을 보여 준다. 상세 창은 네트워크를 쓰지 않는다.

`ctrl-s`의 "safe 행만"은 표시 줄 끝의 등급 단어로 정확히 거른다. fuzzy 검색어 `safe`는 `stale … force`처럼 글자가 흩어진 줄도 맞추기 때문이다.

## 삭제 흐름

`alt-d`는 fzf `execute`로 터미널에 나와 다음 순서로 진행하고, 끝나면 키 입력을 기다린 뒤 목록으로 돌아간다. 표시한 레코드는 `{+f}`(파일로 전달)로 넘긴다. 레코드 한 줄이 필드 27개라 `{+}`로는 많이 표시했을 때 명령줄 길이 한도에 닿을 수 있다.

1. 원격 삭제나 `pushed` 판정이 필요한 repo마다 `wt_fetch_origin`을 한 번 실행한다. `pushed`도 원격 ref가 최신이어야 "잃는 커밋 없음"이 성립하기 때문이다. 실패(반환값 1)하면 그 repo의 원격 삭제는 모두 skipped로 돌리고, `pushed` 행은 needs force로 내린다.
2. 표시한 행을 현재 ref로 다시 판정한다. fzf 레코드의 값은 쓰지 않는다. PR 근거는 대상 repo마다 `forge_pr_rows`를 다시 불러 얻는다(`--offline`이면 부르지 않음). 조회가 실패하면 ancestry만으로 판정하므로 squash 머지 브랜치와 백업은 needs force로 내려간다. 이때 판정한 전체 sha가 이후 삭제의 기준이다.
3. 계획을 safe / needs force / skipped 세 묶음으로 출력한다. 행마다 repo, 브랜치, 대상(local / origin / local+origin), 짧은 sha, 근거를 한 줄로 쓴다.
4. safe 묶음을 한 번 묻는다(기본 No). needs force 항목은 브랜치마다 따로 묻는다(기본 No, 잃을 커밋 수 표시).
5. 승인된 항목을 로컬 → 원격 순서로 지운다.
   - 로컬: `remove_branch <repo> <b> 1 <판정 sha>`. squash 머지·백업은 `-d`가 거부하므로 항상 강제 삭제하되, 판정 후 움직였으면 지우지 않음
   - 원격: `remove_remote_branch <repo> origin <b> <판정 sha>` (`--force-with-lease`)
6. ref마다 `✓` / `✗` / `–` 결과 행을 출력한다. `✓`에는 `(was <sha>)`와 복구 명령, `✗`에는 git 메시지와 재시도 명령을 붙인다. 결과 끝에 삭제 로그 경로를 한 줄 출력한다.

### 삭제 로그

결과 화면은 키 입력 뒤 사라지고, 브랜치를 지우면 그 브랜치의 reflog도 함께 지워진다. 그래서 지운 ref마다 한 줄을 `${XDG_STATE_HOME:-$HOME/.local/state}/workytree/deleted.log`에 덧붙인다.

```text
2026-10-23T17:30:12+09:00	/Users/bahn/…/mobidoc-front	refs/heads/backup/mpt-9167-pre-amend2	9f8e7d6…(전체 sha)	git -C /Users/bahn/…/mobidoc-front branch backup/mpt-9167-pre-amend2 9f8e7d6…
2026-10-23T17:30:13+09:00	/Users/bahn/…/mobidoc-server	refs/remotes/origin/fix/MPT-9411	4d5e6f7…(전체 sha)	git -C /Users/bahn/…/mobidoc-server push origin 4d5e6f7…:refs/heads/fix/MPT-9411
```

| 항목 | 규칙 |
|---|---|
| 형식 | 탭 구분: 시각(ISO 8601, 로컬 시간대), repo 절대 경로, 지운 ref 전체 이름, 전체 sha, 복구 명령 |
| 기록 시점 | 삭제가 성공한 ref만. 실패·유지·skipped는 남기지 않음 |
| 기록 위치 | `remove_branch`와 `remove_remote_branch` 안. 그래서 `wt remove`가 지운 브랜치도 같이 기록됨 |
| 쓰기 실패 | 경고만 출력하고 삭제 흐름은 계속함 |
| 유효 기간 | 지운 커밋이 다른 ref에 없으면 gc 유예(기본 약 2주)가 지나면 복구 명령이 실패함. README에 적음 |

이 파일은 config 다음으로 workytree가 쓰는 두 번째 파일이다. config 디렉터리가 아니라 XDG state 디렉터리에 두는 이유는 사용자가 편집하는 설정이 아니라 도구가 쌓는 기록이기 때문이다.

skipped가 되는 경우: 동료 원격, 다른 작성자 커밋이 섞인 원격, 보호 브랜치, 판정 사이에 체크아웃된 브랜치, base, 2단계에서 사라진 ref, fetch에 실패한 repo의 원격.

출력 채널은 비대화 설계(2026-10-23 §6.1)를 따른다. 계획과 결과는 stderr, 질문은 `prompt_confirm`으로 `/dev/tty`에 쓴다. `remove_branch`와 `remove_remote_branch`는 자체 `success`(stdout)와 hint를 출력하므로, 그대로 부르면 결과 행과 중복된다. 두 함수에 결과 행만 남기는 방법을 더하거나 결과 행을 생략하고 두 함수의 출력을 쓰는 것은 빌더가 정한다.

출력 예:

```text
safe — merged or its ticket is merged
  mobidoc-front   backup/mpt-9167-pre-amend2   local          9f8e7d6  backup of mpt-9167 (PR !812 merged)
  mobidoc-server  fix/MPT-9411                 origin         4d5e6f7  merged into origin/develop
needs force — commits would exist nowhere else
  mobidoc-server  chore/flyway                 local+origin   7a8b9c0  stale 167d, 3 commits not in origin/develop
skipped
  (none)
delete the 2 safe refs? [y/N]

✓ local   mobidoc-front   backup/mpt-9167-pre-amend2   deleted (was 9f8e7d6)
      restore: git -C ~/…/mobidoc-front branch backup/mpt-9167-pre-amend2 9f8e7d6
✗ origin  mobidoc-server  fix/MPT-9411                 not deleted: <git 메시지>
      retry:   git -C ~/…/mobidoc-server push --force-with-lease=refs/heads/fix/MPT-9411:4d5e6f7 origin --delete fix/MPT-9411
– both    mobidoc-server  chore/flyway                 kept (force declined)
```

## 수집

- 브랜치 모드는 기존 `status_collect_repo`의 `for-each-ref`에 `refs/remotes/origin`을 더한다. 필요한 필드는 refname, objectname, upstream, `upstream:track`, `committerdate:unix`, `authoremail:trim`이다. `refs/remotes/origin/HEAD`는 걸러 낸다
- `--merged=<base>`와 `%(ahead-behind:<base>)`도 원격 ref까지 같은 호출로 얻는다. git 2.41 미만에서는 기존 코드가 브랜치마다 `rev-list`를 부르므로(`lib/status.zsh:177-181`), 원격 전용 ref는 base 대비 개수를 `-`로 둔다
- 맵 키는 전체 refname을 쓴다. `%(refname:short)`는 같은 이름의 태그가 있으면 `heads/x`로 바뀌어 키가 어긋난다
- 같은 저장소가 두 번 이상 수집되지 않게 `status`의 대상 목록을 `git rev-parse --git-common-dir`로 중복 제거한다. 조사에서 Claude Code 에이전트 워크트리(`.claude/worktrees/*`)가 별도 repo로 잡혀 datavase가 3번 수집됐다(`lib/resolve.zsh:159`). 남기는 쪽은 메인 checkout(작업 트리의 `.git`이 디렉터리인 쪽)이다. `all_repos`는 바꾸지 않는다. `remove`, `prune`, `create`에 영향이 가기 때문이다
- 수집, 새로고침, 상세 창은 fetch하지 않는다. 쓰기는 `ctrl-r`과 `alt-d`뿐이다

## 결정 사항

| 결정 | 누가 | 이유 | 기각한 대안 |
|---|---|---|---|
| 별도 모드(`ctrl-b`) | 사용자 | 로컬·원격을 한 행에서 봄 | 기존 목록에 행 추가, 티켓 단위 묶음 |
| 한 행 = 로컬 + 본인 원격 | 사용자 | 대상별 판단을 줄임 | 대상별 키 분리 |
| sha와 복구 명령 출력 + 삭제 로그, gc 유예 감수 | 사용자 | 화면이 사라져도 sha가 남음. 커밋 보존까지는 불필요 | `refs/wt-archive/*`, 출력만 |
| 로그는 삭제 헬퍼 안에서 기록 | Claude | 브랜치 모드와 `wt remove`가 같은 기록을 남김 | 브랜치 모드에서만 기록 |
| 원격은 본인 것만 삭제 | Claude | 원격 전용 889개 중 본인 것 87개 | 모든 원격 허용, 원격 삭제 없음 |
| 원격 소유는 작성자 이메일 | Claude | 로컬 정보만으로 판정 | forge API로 push 사용자 조회 |
| 백업 근거는 머지된 PR만 | Claude | ancestry는 되돌린 티켓 브랜치를 머지로 오판 | 티켓 브랜치 ancestry 허용, 이름만으로 safe |
| 보호 브랜치 고정 목록 | Claude | gitflow에서 뒤처진 `master`가 `merged`가 됨 | config 키 |
| 지우지 않을 쪽은 WHY에 넣지 않음, `pushed` 추가 | Claude | 원격에 남는 로컬 사본은 잃는 것이 없음 | 두 쪽 중 위험한 쪽 일괄 |
| 삭제 직전 해당 repo만 fetch | Claude | 조회 무변경 원칙 유지, lease가 묵은 sha에 걸리는 문제 방지 | 수집 때 fetch, fetch 없이 삭제 |
| 재판정 때 PR 다시 조회, 실패 시 force로 | Claude | 비대화 설계 §3.14의 "오프라인이면 ancestry만" | 수집 때 PR 캐시 |
| 표시는 막지 않고 계획에서 skipped | Claude | fzf 0.38에 `transform` 없음 | tab 차단, 최소 버전 상향 |
| 로컬 삭제는 항상 `-D` + 판정 sha | Claude | squash 머지·백업은 `-d`가 거부함. 판정 sha 비교로 안전을 대신 보장 | `-d` 시도 후 실패 시 질문 |
| `✓`에서 gone·closed 제외 | Claude | `remove`(T7-1)와 판정 일치. README에 문서화된 동작을 바꿈 | 브랜치 모드만 엄격하게 |
| 중복 제거는 `status` 안에서만 | Claude | `all_repos`를 바꾸면 다른 명령에 영향 | `all_repos`에서 제거 |

## 다른 설계와의 관계

- 설계 2026-10-06 §10의 "branch 행 삭제 액션" 비목표를 이 문서가 대체한다
- 비대화 설계 2026-10-23 §3.14(T7-1): "판정 무변경 후 강제 삭제", "gone·unmerged는 기본값 예 아님"을 따른다. "`-B` 없이는 어떤 커밋도 마지막 ref를 잃지 않음"에는 예외 하나를 더한다: 머지된 PR이 있고 열린 PR이 없는 티켓의 백업 브랜치(사용자 결정)
- 같은 문서 P7(status TUI)과 겹치는 부분: branch 행이 브랜치 모드로 옮겨지므로 P7의 "Enter on branch rows keeps the list"는 이 문서가 구현한다. P7의 `ctrl-s`(safe + stale)는 워크트리 목록 기준이고, 브랜치 모드의 `ctrl-s`는 safe만 보인다

## 테스트

기존 방식을 따른다. bare remote를 둔 git fixture, `GIT_COMMITTER_DATE`로 고정한 시각, `fzf`·`gh`·`glab` 함수 stub(설계 2026-10-06 §11). 브랜치 모드 시나리오:

1. 머지된 로컬 + 본인 원격 → `merged`, 둘 다 삭제, 복구 명령 출력
2. squash 머지(PR stub이 tip에서 merged), upstream gone → `merged`
3. `backup/<KEY>-pre-squash`(고유 커밋 있음) + `<KEY>` head의 merged PR → `backup`, 삭제됨
4. 같은 백업인데 PR 없음(티켓 브랜치가 ancestry로만 머지) → `unmerged`. 같은 키의 열린 PR 있음 → `unmerged`. PR 조회 실패 → needs force
5. 원격 전용, 다른 작성자 → `read-only`, 표시해도 skipped
6. 원격 tip은 본인이지만 base에 없는 커밋에 다른 작성자 포함 → 원격 skipped
7. 로컬이 `teammate` 원격의 조상 → `pushed`, 로컬만 safe로 삭제
8. 계획과 삭제 사이에 로컬이 움직임 → 유지. 원격이 움직임 → lease 실패 `✗`
9. 워크트리에 체크아웃된 브랜치 → 행 없음. 계획 단계에서 새로 체크아웃됨 → skipped
10. base, `origin/HEAD` → 행 없음. base가 `develop`일 때 `master` → `protected`
11. 에이전트 워크트리로 같은 저장소가 두 번 등록됨 → 메인 checkout으로 한 번만 수집
12. 수집 전후 모든 ref가 그대로임
13. safe 확인에 No → 아무것도 지우지 않음
14. 티켓 키 추출: 위 "백업 판정"의 예 표 전부, `mpt-916`과 `mpt-9167` 불일치
15. 워크트리 목록: gone + 미머지 → `!`, closed PR at tip → `✓` 아님
16. 워크트리 목록: 워크트리 없는 로컬 브랜치 → 행 없음(`--plain`, `--json`, `--stale` 모두). `--branches`에서는 나옴. 기존 `tests/status.test.zsh` 시나리오 7을 이 기준으로 바꿈
17. 삭제 로그: 성공한 로컬·원격 삭제마다 한 줄, 실패·유지는 없음. 기록된 복구 명령을 실행하면 같은 sha로 ref가 되살아남. `XDG_STATE_HOME`을 테스트 임시 디렉터리로 지정
18. 삭제 로그 쓰기 실패(디렉터리 쓰기 불가) → 경고만 나오고 삭제는 완료됨
19. `wt remove -b`로 지운 브랜치도 삭제 로그에 기록됨

## 문서

- README "상태 보기": "삭제는 하지 않는다" 문장, 표시 대상 목록(branch 행 제외), `✓` 정의, 키 표, `--branches` 옵션, `--json` 호환성 변경
- README: 삭제 로그 위치·형식과 gc 유예 이후 복구할 수 없다는 점(`remove` 절에도)
- 설계 2026-10-06 §10의 "branch 행 삭제 액션" 비목표에 이 문서를 가리키는 줄 추가
- 비대화 설계 2026-10-23 §3.14에 백업 예외 추가
- `shell/completions/_workytree`에 `--branches`

## 빌더에게 맡기는 것

- fzf 0.38 안에서 모드 전환과 모드별 키 동작을 구현하는 방법. 최소 버전을 올려야 하면 그 이유를 README에 남길 것
- `--branches --json`의 필드 이름과 중첩 구조
- 열 너비, 색, 상세 창 배치
- `remove_branch`/`remove_remote_branch` 출력과 결과 행의 중복 처리
- 새 파일로 나눌지(`lib/cmd/status_branches.zsh` 등) 기존 파일에 넣을지

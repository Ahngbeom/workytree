# wt create 이후 AI 세션 자동 실행 설계

작성일: 2026-08-26

## 1. 배경과 목표

`wt create`는 워크트리를 만들고 셸 래퍼가 그 경로로 `cd`하는 것까지 한다. 사용자는 그
직후 거의 항상 같은 동작을 반복한다 — 새 워크트리에서 AI 코딩 에이전트를 띄우는 것.
이 마지막 한 걸음을 옵션으로 자동화한다.

목표:

- 워크트리 생성 → 이동 → 에이전트 실행을 한 명령으로 잇는다.
- 실행할 에이전트를 PATH에서 탐색하되, 설정으로 명시 지정할 수 있다.
- 에이전트를 띄우기 전에 유용한 옵션(permission-mode, model, teammate-mode 등)을
  대화형으로 제안한다.
- **기존 `wt create`의 동작을 한 줄도 바꾸지 않는다.** 전부 opt-in이다.

비목표(§9 참조): 새 터미널 탭/창 열기, 백그라운드 세션 관리, 초기 프롬프트 주입.

### 1.1 왜 터미널 앱 감지 어댑터를 만들지 않는가

최초 요구는 "터미널 앱 환경 감지 후 새 세션 오픈"이었다. 두 가지 실측이 이 방향을 접게
했다.

첫째, 에이전트를 **현재 셸에서 그대로 실행**하기로 결정하면 iTerm2/Ghostty/WezTerm별
osascript 어댑터가 통째로 불필요해진다. 어댑터는 앱마다 문법이 다르고 앱 업데이트마다
깨지는, 이 저장소가 감당할 이유가 없는 유지보수 면적이다.

둘째, `claude`는 `--teammate-mode <auto|tmux|iterm2|in-process>`로 **이미 그 감지를 자기
안에서 수행한다**. workytree가 터미널을 직접 몰 필요 없이 이 플래그를 넘겨주면 된다.
감지 책임을 그것을 가장 잘 아는 쪽에 남긴다.

### 1.2 왜 중첩 실행 방지 로직을 만들지 않는가

"에이전트 안에서 `wt create --ai`를 돌리면 에이전트가 중첩된다"는 위험은 실재하지만,
전용 방어 코드가 필요 없다. 에이전트의 셸 도구 안에서 실측한 결과:

```
interactive=NO   stdin_tty=NO   stdout_tty=NO
```

셸 래퍼는 이미 `[[ -o interactive ]]`일 때만 동작한다(`shell/workytree.zsh:67`). 이 기존
가드가 중첩 경로를 전부 차단한다. `CLAUDECODE` 같은 에이전트별 마커 환경변수 테이블은
만들지 않는다 — 유지보수해야 할 목록만 늘고 얻는 것이 없다.

## 2. 실행 채널: runfile

`bin/workytree`는 순수 CLI다. 계산하고, git을 호출하고, 출력한다. `cd`하지 않고 대화형
프로그램을 실행하지도 않는다. 이 불변식이 저장소 전체의 뼈대이므로 유지한다.

한편 대화형 에이전트는 호출자의 TTY를 상속해야 하므로 `$(...)`로 캡처되는 서브셸 안에서는
띄울 수 없다. 따라서 **결정은 CLI가, 실행은 래퍼가** 한다. 둘 사이의 전달 채널이 runfile이다.

```
wt() [shell/workytree.zsh]
  │  WORKYTREE_AI_RUNFILE=$(mktemp) export, EXIT trap으로 정리
  ▼
bin/workytree create --ai ...
  │  create_do 성공 → ai_maybe_offer()
  │    ├ /dev/tty 로 옵션 인터뷰 (stdout 오염 없음)
  │    └ 조립한 argv를 runfile에 한 줄에 하나씩 기록
  │  stdout 마지막 줄 = <target>          ← 기존 계약 그대로
  ▼
wt() 가 builtin cd <target> 후, runfile이 비어있지 않으면 실행
```

### 2.1 stdout 계약을 건드리지 않는 이유

대안은 stdout에 `WT_EXEC\t<command>` 같은 지시어 줄을 추가하는 것이었다. 채택하지 않았다.
`create`의 stdout에는 이미 `info` 줄들이 섞여 있고(`lib/ui.zsh:12`), 거기에 접두어 기반
프로토콜을 얹으면 사용자 데이터(브랜치명, 경로)가 우연히 접두어와 충돌할 수 있는 창구가
생긴다. "마지막 줄 = 경로"는 단일 규칙이라 안전하다. 이 규칙에 두 번째 규칙을 더하지 않는다.

### 2.2 소유권

runfile은 **래퍼가 만들고 래퍼가 지운다.** CLI는 이미 존재하는 경로에 쓰기만 한다. CLI가
직접 mktemp하면 누가 언제 지우는지가 불분명해지고, CLI가 죽었을 때 파일이 남는다.

`WORKYTREE_AI_RUNFILE`이 unset이면 — 즉 래퍼를 거치지 않고 `bin/workytree`를 직접
호출했다면 — CLI는 stderr로 셸 통합이 필요하다고 경고하고, **워크트리 생성 자체는 정상
성공(exit 0)시킨다.** 에이전트를 못 띄운 것은 생성 실패가 아니다.

### 2.3 argv 전달과 eval 배제

runfile에는 **argv 한 원소당 한 줄**을 쓴다. 토큰화는 CLI가 `${(z)...}`로 수행하고(따옴표를
올바르게 처리), 래퍼는 이미 쪼개진 배열을 받는다.

```zsh
local -a cmd; cmd=( ${(f)"$(<$WORKYTREE_AI_RUNFILE)"} )
(( ${#cmd} )) && "${cmd[@]}"
```

`eval`은 쓰지 않는다. config 값에 셸 메타문자가 들어있을 때 임의 명령 실행으로 번지기
때문이다. 설정 파일은 사용자 것이지만, 설정 파일이 곧 실행 권한이 되는 설계는 피한다.

대가: **빈 문자열 인자는 지원하지 않는다.** `--foo ""` 같은 형태를 config에 적을 수 없다.
문서화하고 넘어간다.

### 2.4 exec가 아닌 일반 호출

래퍼는 `exec`가 아니라 일반 호출로 에이전트를 띄운다. 에이전트를 종료하면 사용자는 새
워크트리 안의 셸로 돌아온다. `exec`였다면 셸까지 함께 사라진다.

## 3. 설정 스키마

```ini
ai_session = off                 # off(기본) | ask | always
ai_agent   = claude              # 미설정 시 자동 탐색

[project work]
repo_root     = ~/work/products
worktree_root = ~/work/worktrees
ai_session    = always           # project 단위 오버라이드
ai_agent      = codex

[agent claude]
command         = claude
ask             = permission_mode,model,teammate_mode
permission_mode = plan,acceptEdits,auto,bypassPermissions,dontAsk,manual
model           = opus,sonnet,fable
effort          = low,medium,high,xhigh,max
teammate_mode   = auto,tmux,iterm2,in-process
```

### 3.1 `[agent <name>]` 섹션 신설

`project`/`repo`에 이어 세 번째 섹션 타입을 추가한다. 섹션 안의 각 키는 옵션 하나의 **제안
목록**이고, `ask`가 질문 대상과 순서를 정한다.

이것은 새 개념이 아니라 기존 `kinds = feature,fix,chore,...` 패턴을 그대로 옮긴 것이다.
`kinds`도 강제가 아닌 제안 목록이고, `prompt_choose "kind" 1 ...`의 `1`이 목록 밖 값의 자유
입력을 허용한다(`lib/cmd/create.zsh:125`). 옵션 제안도 같은 문법·같은 UI·같은 의미를 갖는다.

세부 규칙 셋:

- **`ask`에 없는 키는 질문하지 않는다.** 위 예시의 `effort`가 그렇다 — 값 목록은 준비되어
  있고 사용자가 `ask`에 한 단어를 더하면 바로 켜진다. 섹션에 키를 정의하는 것과 질문하는
  것은 분리되어 있다.
- **`ask`가 섹션에 없는 키를 가리키면 그 항목을 건너뛴다.** 오류로 만들지 않는다 — 내장
  프로필을 부분적으로 흉내 낸 설정이 config 전체를 못 쓰게 만드는 쪽이 더 나쁘다.
- **`command`가 없으면 섹션 이름을 실행 파일 이름으로 쓴다.** `[agent claude]`에서
  `command = claude`는 생략 가능하다.

하위 호환 문제는 없다. 오늘 config에 `[agent claude]`를 쓰면 파서가 하드 실패한다:

```
workytree: config parse error at <path>:7: [agent claude]   (exit 3)
```

즉 이 섹션을 이미 쓰고 있는 사용자가 존재할 수 없다.

### 3.2 플래그 매핑 규칙

config 키 문법은 `[A-Za-z_][A-Za-z0-9_]*`라 하이픈을 쓸 수 없다(`lib/config.zsh:150`).
따라서 규칙 하나를 둔다: **키의 `_`를 `-`로 바꾸고 앞에 `--`를 붙인다.**

| config 키 | 조립되는 argv |
| --- | --- |
| `permission_mode = plan` 선택 | `--permission-mode plan` |
| `teammate_mode = iterm2` 선택 | `--teammate-mode iterm2` |

값은 항상 별도 argv 원소로 넣는다(`--flag=value`가 아님). 값에 공백이 있어도 안전하다.

### 3.3 내장 기본 프로필

위 `[agent claude]` 블록 전체를 코드에 내장 기본값으로 둔다. 사용자가 같은 이름의 섹션을
정의하면 **통째로 교체**된다(키 단위 병합이 아님). 병합은 "내장 목록에서 항목 하나를 빼고
싶다"를 표현할 수 없어 더 나쁘다.

`codex`, `gemini`, `cursor-agent`, `aider`에 대한 내장 프로필은 두지 않는다. 각 CLI의 플래그를
검증 없이 코드에 박는 것은 노후화 부채이고, 프로필 없는 에이전트는 §4.3의 경로로 인터뷰 없이
그냥 실행되므로 여전히 동작한다.

### 3.4 `teammate_mode`에 대한 알려진 위험

`--teammate-mode`는 `claude --help`에 **표시되지 않는 비공개 플래그**다. 존재와 허용값은
실측으로 확인했다:

```
$ claude --teammate-mode __bogus__
error: option '--teammate-mode <mode>' argument '__bogus__' is invalid.
       Allowed choices are auto, tmux, iterm2, in-process.
```

문서화되지 않은 플래그는 예고 없이 사라지거나 값이 바뀔 수 있고, 그러면 조립된 명령이 실행
시점에 실패한다. 이 위험을 알고도 기본 `ask`에 포함한다 — 정확히 이런 이유로 목록을 코드가
아닌 config에 두었기 때문에, 깨지더라도 사용자가 `[agent claude]` 한 줄로 복구할 수 있다.
README의 "알려진 한계"에 명시한다.

## 4. 해석 순서

### 4.1 설정값 우선순위

`ai_session`과 `ai_agent` 모두: **project 값 → 전역 값 → 내장 기본값**.

`repo` 단위 오버라이드는 두지 않는다. `[repo]` 섹션은 명시 등록한 저장소에만 존재하므로,
스캔으로 발견된 저장소는 이 계층을 쓸 수 없어 규칙이 비대칭해진다.

### 4.2 에이전트 자동 탐색

`ai_agent`가 설정되지 않았으면 다음 순서로 `$+commands[...]` 첫 히트를 쓴다:

```
claude → codex → gemini → cursor-agent → aider
```

하나도 없으면 조용히 아무것도 하지 않는다. 에이전트가 없는 환경에서 경고를 띄우는 것은
소음이다.

### 4.3 프로필 매칭

해석된 에이전트 이름이 `[agent <name>]`(또는 내장 프로필)과 매칭되면 그 프로필의 `command`를
쓰고 인터뷰를 진행한다. 매칭되지 않으면 그 값을 그대로 실행 명령으로 쓰고 **인터뷰 없이**
실행한다. `ai_agent = aider`가 이 경로다.

### 4.4 실행 게이트

아래를 **모두** 만족할 때만 runfile에 기록한다.

1. `--ai` 플래그가 주어졌거나 해석된 `ai_session != off`
2. `WORKYTREE_AI_RUNFILE`이 설정되어 있음
3. 해석된 에이전트 실행 파일이 PATH에 존재

`--ai`는 `ai_session`을 **덮어쓴다.** `ai_session = off`(기본값)여도 `--ai`를 주면 실행되고,
이때 §5의 확인 프롬프트도 건너뛴다 — 플래그를 명시적으로 친 것 자체가 확인이다.
반대 방향의 스위치(`ai_session = always`를 이번 한 번만 끄기)는 두지 않는다. 필요해지면
`--no-ai`로 추가한다.

## 5. 인터뷰 흐름

`ai_session = ask`이면 먼저 확인 프롬프트를 띄운다. `--ai` 또는 `always`이면 건너뛴다.

```
open a claude session here? [Y/n]
```

이어서 `ask` 목록의 각 옵션에 대해:

```
permission-mode>
  1) (skip)
  2) plan
  3) acceptEdits
  ...
choose [1-7] or type a value:
```

- 기존 `prompt_choose "<option>" 1 "(skip)" <값들...>`을 그대로 쓴다. fzf가 있으면 fzf 화면,
  없으면 번호 메뉴 — 두 경로 모두 이미 구현되어 있다.
- `allow_free=1`이므로 목록에 없는 값도 타이핑할 수 있다. 이것이 §3.4의 노후화를 **조용한
  실패가 아닌 가벼운 불편**으로 낮추는 장치다.
- `(skip)` 선택 시 해당 플래그를 argv에서 생략한다.

### 5.1 비대화형 경로

`-y`/`--yes`이거나 프롬프트가 불가능한 환경이면 인터뷰 전체를 건너뛰고 `command`만 실행한다.
`prompt_available`(`lib/prompt.zsh:5`)이 이미 두 경우를 함께 판정한다.

### 5.2 취소 처리

인터뷰 중 `q`나 EOF로 취소하면 **워크트리는 그대로 두고 에이전트만 띄우지 않는다.** 이미
생성된 것을 되돌리지 않는다. `cmd_create`의 기존 취소 지점(생성 *전* 확인 프롬프트,
`lib/cmd/create.zsh:147`)은 exit 130이지만, 이 인터뷰는 생성 *후*이므로 exit 0이다.

## 6. 변경 대상

| 파일 | 변경 |
| --- | --- |
| `lib/config.zsh` | 섹션 정규식 3곳(`:133`, `:288`, `:345`)에 `agent` 추가; `WT_ACFG`/`WT_AGENTS` 신설; `_config_split_key`에 `agent.<name>.<key>` |
| `lib/agent.zsh` | **신규** — 설정 해석, PATH 탐색, 인터뷰, argv 조립, runfile 기록 |
| `lib/cmd/create.zsh` | `--ai` 필터링; `create_do` 성공 후 `ai_maybe_offer` 호출 |
| `shell/workytree.zsh` | runfile mktemp/export/trap; `cd` 후 실행 |
| `shell/completions/_workytree` | `--ai` 추가 |
| `README.md` | 새 절, config 키 표, `teammate_mode` 한계 명시 |

`--ai`는 전역 옵션이 아니라 `cmd_create` 안에서 처리한다. `create`에서만 의미가 있고,
`parse_global_opts`에 넣으면 다른 서브커맨드가 이 플래그를 조용히 무시하게 된다. 다만
`cmd_create`는 positional 개수를 검사하므로(`lib/cmd/create.zsh:99`) `--ai`를 먼저 걸러내야 한다.

## 7. 테스트

TTY도 실제 에이전트도 없이 전부 검증 가능하다.

- **`tests/agent.test.zsh` (신규)** — `WORKYTREE_PROMPT_INPUT`으로 인터뷰 답변을 주입하고
  `WORKYTREE_AI_RUNFILE` 내용을 검증한다. 케이스: `(skip)` 선택 시 플래그 생략, 자유 입력값
  통과, `_`→`-` 매핑, `-y`일 때 인터뷰 미실행, `ai_session = off`일 때 runfile이 비어 있음,
  runfile 미설정 시 경고 + exit 0.
- **탐색** — 임시 디렉터리에 가짜 실행 파일을 만들어 PATH 앞에 붙이고 우선순위를 검증한다.
- **`tests/shell.test.zsh` 확장** — 기존 `zsh_i`(`zsh -i -c`)가 이미 대화형이므로, 가짜
  에이전트가 마커를 출력하는지와 그 시점의 `$PWD`가 워크트리인지를 확인한다.
- **`tests/config.test.zsh` 확장** — `[agent]` 파싱, 중복 `[agent]` 거부,
  `config set agent.claude.model`.

## 8. 오류 처리

| 상황 | 동작 |
| --- | --- |
| runfile 미설정(래퍼 미경유) | stderr 경고, 워크트리 생성은 성공(exit 0) |
| 에이전트를 PATH에서 못 찾음 | 조용히 미실행 |
| `ai_agent`가 명시됐는데 PATH에 없음 | stderr 경고, exit 0 |
| 인터뷰 취소(`q`/EOF) | 미실행, exit 0 |
| 중복 `[agent <name>]` | 기존 중복 섹션과 동일하게 파싱 실패(exit 3) |

핵심 원칙: **AI 세션 실행 실패는 절대 `create`를 실패시키지 않는다.** 워크트리는 만들어졌고,
그것이 이 명령의 본래 계약이다.

## 9. 범위 밖 (후속 작업)

- `wt cd --ai` — 래퍼는 공유되지만 CLI 쪽 `cmd_cd`/`cmd_path` 경로에 별도 배선이 필요하다.
  이 설계 위에서는 거의 공짜로 추가된다.
- 초기 프롬프트 주입(`claude "PROJ-1 작업 시작"`).
- 새 탭/창/pane 실행 — §1.1 참조.
- `claude`의 `-w/--worktree`, `--tmux`와의 통합. 기능이 겹치지만 workytree의
  project-scoped 레이아웃을 대체하지는 못한다. 조립된 argv에 `--worktree`가 섞이지 않도록
  주의한다.

# workytree 상용화 설계 (oldwt → workytree/wt)

작성일: 2026-08-25

## 1. 배경과 목표

`oldwt`는 `~/.local/bin/oldwt`(zsh, 499줄) + `~/.config/zsh/acme-worktrees.zsh`(auto-cd 래퍼) + `~/.config/zsh/completions/_oldwt`로 구성된 개인용 git worktree 관리 명령이다. `~/Acme/products`(repo 스캔 루트)와 `~/Acme/workspace/worktrees`(worktree 루트)가 core와 completion 양쪽에 하드코딩되어 있어 다른 사용자가 설치할 수 없다.

목표: 이 저장소(`workytree`)에 **누구나 설치 가능한** 도구로 재구성한다.

- 정식 이름 `workytree`, 실행 명령 `wt`를 기본 alias로 제공(옵트아웃 가능).
- 구현 언어는 zsh 유지(기존 코드 재사용, macOS 1차 대상). core는 "경로 계산·git 호출·출력"만 하는 순수 함수형으로 유지해 추후 이식이 쉽도록 한다.
- 설정은 **프로젝트(= repo_root + worktree_root 한 쌍)** 단위. 파일 직접 편집과 `wt project|repo|config` 명령 양쪽으로 구성 가능.
- repo 해석은 세 모델을 결합: 명시 등록(alias) → 프로젝트 repo_root 스캔 → 현재 위치 추론. 추론 결과는 **반드시 대화형으로 확인**한다.
- 기존 oldwt 워크트리 레이아웃(`<worktree_root>/<repo>/<kind>/<ticket>`, 브랜치 `<kind>/<ticket>`)을 그대로 유지해 데이터 이관 없이 호환한다.

## 2. 설정 파일과 프로젝트 모델

파일: `${XDG_CONFIG_HOME:-~/.config}/workytree/config` — INI 계열, zsh만으로 파싱.

```ini
# workytree config
default_project = acme
alias_wt = true               # wt 축약 명령 설치 여부 (기본 true)
kinds = feature,fix,chore,hotfix,refactor   # create 시 추천 목록 (강제 아님)

[project acme]
repo_root     = ~/Acme/products
worktree_root = ~/Acme/workspace/worktrees
scan_depth    = 5             # repo_root 아래 .git 탐색 깊이 (기본 3)

[project personal]
repo_root     = ~/personal
worktree_root = ~/orca/workspaces

[repo backend]                # 명시 등록 (선택)
path    = ~/src/legacy-api
project = personal            # worktree_root는 이 프로젝트 것을 사용
```

규칙:
- `[project <name>]`은 `repo_root`와 `worktree_root`를 반드시 함께 가진다(경로 쌍 불변식).
- `[repo <name>]`은 `path`와 `project`를 가진다. worktree_root는 항상 프로젝트에서만 온다.
- `~`와 `$VAR`는 값 읽기 시 확장한다.
- 명령으로 설정을 수정할 때는 해당 키/섹션 라인만 교체해 사용자 주석과 순서를 보존한다.
- 반복 키는 허용하지 않는다(프로젝트를 여러 개 두는 것으로 대체).

### repo 해석 순서 (`wt create [repo] …`)

1. `[repo <name>]` 명시 등록 → 즉시 매치.
2. 모든 `[project]`의 `repo_root`를 `scan_depth`까지 스캔해 `.git`(디렉터리 또는 파일) basename 매치. 프로젝트 간 이름 중복이면 오류 + `--project <name>`으로 한정.
3. repo 생략 → 현재 위치 `git rev-parse --show-toplevel`. 그 경로가 어느 프로젝트의 `repo_root` 아래인지로 프로젝트를 결정. 어디에도 속하지 않으면 대화형으로 프로젝트/repo 선택.

worktree 경로: `<프로젝트 worktree_root>/<repo>/<kind>/<ticket>`, 브랜치 `<kind>/<ticket>`.

## 3. 저장소 구조와 설치

```
workytree/
├── bin/workytree              # core 진입점 (zsh). cd 하지 않음
├── lib/
│   ├── config.zsh             # 설정 파싱/쓰기 — 유일한 설정 파일 I/O 지점
│   ├── resolve.zsh            # repo/project 해석 순서
│   ├── prompt.zsh             # 대화형 선택/확인 (TTY 감지, --yes, fzf 선택적 사용)
│   ├── ui.zsh                 # info/success/warn/error 색상 출력
│   └── cmd/                   # 서브커맨드 하나당 파일
│       ├── create.zsh remove.zsh prune.zsh list.zsh path.zsh
│       └── init.zsh project.zsh repo.zsh config.zsh
├── shell/
│   ├── workytree.zsh          # 셸 통합: workytree()/wt() 함수(auto-cd), completion 등록
│   └── completions/_workytree # zsh completion — `workytree __complete` 호출, 경로 하드코딩 없음
├── install.sh
├── tests/
├── README.md
└── docs/superpowers/specs/
```

설치 흐름(`install.sh`):
1. 저장소를 `~/.local/share/workytree`로 clone/갱신.
2. `~/.local/bin/workytree` → `bin/workytree` symlink.
3. `.zshrc`에 `source ~/.local/share/workytree/shell/workytree.zsh` 한 줄 추가(존재 시 skip, 수정 전 `.zshrc.bak-<date>` 백업).
4. 설정 파일이 없으면 `wt init` 안내.

`wt` alias: `shell/workytree.zsh` 로드 시 config `alias_wt`(기본 true)를 읽어 `wt()` 함수를 정의. 이미 `wt`가 다른 명령/함수/alias로 존재하면 정의하지 않고 경고. 환경변수 `WORKYTREE_ALIAS=0`으로도 끌 수 있다.

셸 래퍼 동작:
- `create`/`cd`는 core 출력의 **마지막 줄 = 경로** 규약으로 받아 `builtin cd`(interactive 셸에서만). 나머지 줄은 그대로 표시.
- 그 외 서브커맨드는 `command workytree "$@"`로 위임.
- core의 대화형 프롬프트는 `/dev/tty`로 직접 입출력하므로 `$(…)` 캡처와 충돌하지 않는다.

## 4. 명령 인터페이스

```
workytree init                                   # 대화형 초기 설정 (프로젝트 1개 + alias 여부)
workytree create [repo] [kind] [ticket] [base]   # 누락 인자는 대화형; --yes 로 비대화
workytree remove <repo> <kind> <ticket> [--force] [-b|--branch] [-B|--branch-force]
workytree prune [repo]                           # repo 생략 시 전체 프로젝트
workytree list [repo]
workytree repos                                  # 모든 프로젝트의 repo (name, project, path)
workytree path [repo [kind [ticket]]]            # 경로만 출력 (스크립트용)
workytree cd   [repo [kind [ticket]]]            # 셸 래퍼에서만 의미 있음
workytree project list | add <name> <repo_root> <worktree_root> | remove <name> | default <name>
workytree repo    list | add <path> [--name n] [--project p] | remove <name>
workytree config  path | get <key> | set <key> <value> | edit
workytree __complete <args…>                     # completion 내부용 (숨김)
workytree help | --version
```

공통 옵션: `--project <name>`, `--yes/-y`(비TTY에서는 자동), `--no-color`.

oldwt 대비 변경점: (1) `create` 인자 전부 선택적, (2) `prune`의 repo 생략 가능, (3) `repos`에 project 컬럼 추가. 인자 순서·플래그·출력 규약은 동일.

종료 코드: 0 성공 / 1 일반 오류 / 2 사용법 오류 / 3 설정 없음(`wt init` 안내) / 130 대화형 취소.

## 5. 대화형 `create` 흐름

```
$ wt create
? project    ▸ acme (현재 위치에서 감지)          ← 감지되면 질문 생략
? repo       ▸ acme-server (현재 repo) 맞습니까? [Y/n]   ← 감지 실패 시 번호 목록
? kind       1) feature 2) fix 3) chore 4) hotfix 5) refactor  [직접 입력 가능]
? ticket     PROJ-1234
? base       ▸ origin/develop (upstream 자동)  [Enter=기본 / 목록 / 직접 입력]
──────────────────────────────
repo:    acme-server  → ~/Acme/products/acme/backend/acme-server
target:  ~/Acme/workspace/worktrees/acme-server/fix/PROJ-1234
branch:  fix/PROJ-1234  (base: origin/develop)
Create? [Y/n]
```

규칙:
- 인자로 준 항목은 질문을 건너뛴다. 4개 전부 주면 요약+최종 확인만, `--yes`면 그것도 생략.
- kind 추천 목록은 config `kinds`로 사용자 정의, 강제하지 않는다.
- 브랜치 `<kind>/<ticket>`가 이미 있으면 기존 브랜치 체크아웃을 알리고 base 질문을 건너뛴다.
- target 경로가 이미 있으면 `reused`로 표시하고 경로만 출력(oldwt 동일).
- 비TTY에서 인자가 부족하면 질문 대신 종료코드 2 + 사용법.
- 선택 UI는 `fzf`가 있으면 사용, 없으면 번호 입력 폴백. `fzf`는 필수 의존성이 아니다.
- 모든 질문과 최종 확인이 끝난 뒤에만 `git worktree add`를 실행한다. 취소는 부수효과를 남기지 않는다.

## 6. 오류 처리

- 설정 파일 없음 → 종료코드 3, `run 'wt init'` 안내. 파싱 오류 → `파일:줄` 표시 후 종료.
- repo 이름 중복 → 후보를 `project/path`로 나열하고 `--project` 안내.
- `remove` 안전장치(oldwt 이관): `.idea/`·`.DS_Store`만 dirty면 자동 폐기, 그 외 변경/dirty submodule은 `--force` 필수, 초기화된 submodule이 있으면 `worktree remove --force`, 제거 후 `worktree prune` self-heal 및 잔존 디렉터리 삭제.
- `prune`: 등록되지 않은 `<kind>/<ticket>` 디렉터리 중 cruft(`.idea/`, `.DS_Store`, 빈 디렉터리)만 있는 것만 삭제, 실제 파일이 있으면 경고 후 유지.

## 7. 테스트

`tests/run.zsh` 러너가 `tests/*.test.zsh`를 실행. 외부 프레임워크 없음. 각 테스트는 `HOME`·`XDG_CONFIG_HOME`을 임시 디렉터리로 격리하고 임시 bare repo + clone 픽스처를 사용한다.

- 단위: `config.zsh` 파싱/쓰기(주석·순서 보존, 섹션 추가/삭제, `~` 확장), `resolve.zsh` 해석 순서(alias → 스캔 → cwd), 중복 오류, `--project` 한정, `scan_depth`.
- 통합: `create`(신규 브랜치/기존 브랜치/기존 경로 재사용/base 명시·자동), `remove`(clean/idea-only/dirty/--force/-b/-B), `prune` 고아 디렉터리, `path` 출력 규약, 종료 코드.
- 대화형: `--yes` 경로, 비TTY 인자 부족 시 종료코드 2. 프롬프트 입력은 환경변수 `WORKYTREE_PROMPT_INPUT=<file>`로 `/dev/tty` 대신 파일에서 읽게 하여 스크립트로 시뮬레이션.
- 셸 통합: `zsh -ic`로 `wt`/`workytree` 함수 정의 여부, `alias_wt=false`·기존 `wt` 존재 시 미정의, `create` 후 `pwd` 변경.

## 8. 범위 밖 (후속 작업)

- Homebrew formula, bash/fish 지원.
- tmux 통합(`fdtmux` 후계), `claude-cc`의 worktree 로직 흡수.
- 홈 디렉터리의 `oldwt`·`acme-worktrees.zsh`·`_oldwt` 제거와 `Acme/CLAUDE.md`·`README.md` 갱신. 전환은 `wt init`으로 `repo_root=~/Acme/products`, `worktree_root=~/Acme/workspace/worktrees` 프로젝트를 등록하면 기존 워크트리가 그대로 인식된다.

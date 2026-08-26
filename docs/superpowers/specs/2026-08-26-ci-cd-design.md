# workytree CI/CD 구성 계획

**작성일:** 2026-08-26
**대상 저장소:** github.com/Ahngbeom/workytree
**상태:** 제안 (승인 대기)

## 1. 현재 상태

- 순수 zsh CLI (`bin/workytree`, `lib/`, `shell/`) + POSIX sh 설치 스크립트(`install.sh`). 빌드 산출물 없음.
- 테스트: `tests/run.zsh`가 `tests/*.test.zsh` 14개 파일을 각각 별도 프로세스로 실행, 하나라도 실패하면 exit 1. 로컬(M-series mac) 기준 약 35초.
- 정적 분석: 없음. `shellcheck -s sh install.sh` 실행 시 SC1007 경고 1건(`CDPATH= cd` 관용구 — 오탐).
- 버전: `bin/workytree`의 `WORKYTREE_VERSION="0.1.0"` 하드코딩. git tag 없음.
- 배포 경로: `curl … /main/install.sh | sh` (README에 "아직 동작하지 않음"으로 표기). 설치 시 `git clone` → `~/.local/share/workytree`, 업데이트는 `git pull --ff-only`.
- CI 설정 파일(`.github/`) 없음. 브랜치 보호 규칙 미확인.

## 2. 목표와 범위

**목표**
1. PR·push마다 테스트 + lint가 자동 실행되어 main이 항상 녹색을 유지한다.
2. macOS와 Linux(zsh 5.9) 양쪽에서 테스트가 통과함을 보장한다.
3. 태그 기반 릴리스가 자동으로 GitHub Release를 생성하고, `WORKYTREE_VERSION`과 태그가 어긋나지 않는다.

**범위 밖 (YAGNI)**
- Homebrew tap / 패키지 매니저 배포 — 현재 설치 경로가 `git clone` 기반이라 불필요. 필요해지면 별도 스펙.
- 코드 커버리지 측정 — zsh용 성숙한 도구 없음.
- 릴리스 노트 자동 생성 도구(release-please 등) — 커밋 규약이 혼재(한/영, conventional 일부)라 도입 효과 낮음. GitHub 기본 자동 노트로 충분.

## 3. 접근 방식 비교

| 접근 | 장점 | 단점 |
|---|---|---|
| **A. GitHub Actions, 워크플로 2개 (ci / release)** — 권장 | 저장소가 GitHub, 무료 macOS 러너, 설정 최소 | GitHub 종속 |
| B. GitHub Actions + Docker 이미지로 zsh 버전 고정 | zsh 버전 재현성 높음 | macOS는 Docker 불가 → 이중 경로, 이 규모에 과함 |
| C. Makefile/`ci.sh`로 로컬 진입점 통일 후 Actions는 호출만 | 로컬·CI 동일 명령 | 이미 `tests/run.zsh`가 그 역할, 추가 계층 불필요 |

**A 선택.** 단, C의 취지는 "CI가 실행하는 명령 = 로컬에서 실행하는 명령"이므로 워크플로에서 `zsh tests/run.zsh`와 `shellcheck` 명령을 그대로 호출하고 별도 스크립트를 두지 않는다.

## 4. 설계

### 4.1 `ci.yml` — 테스트 + lint

- **트리거:** `pull_request`(모든 브랜치), `push`(main). `concurrency`로 같은 브랜치의 이전 실행 취소.
- **job `test`** — matrix: `macos-latest`, `ubuntu-latest`
  - ubuntu: `sudo apt-get install -y zsh` (ubuntu-latest의 zsh는 5.9). macos: 기본 zsh 5.9.
  - `fzf`는 설치하지 않는다 — 테스트는 fzf 없는 폴백 경로를 검증하며, 로컬 개발 환경에도 fzf가 없다.
  - 실행: `zsh tests/run.zsh`
  - `git config --global` 없이 동작함을 확인 (helpers.zsh가 `GIT_CONFIG_GLOBAL=/dev/null`로 격리하므로 이미 보장됨).
  - 타임아웃 10분.
- **job `lint`** — `ubuntu-latest`
  - `shellcheck -s sh install.sh`. SC1007은 `install.sh` 19행에 `# shellcheck disable=SC1007` 인라인 주석으로 제외(관용구 오탐).
  - `zsh -n` 문법 검사: `bin/workytree`, `lib/**/*.zsh`, `shell/workytree.zsh`, `shell/completions/_workytree`, `tests/*.zsh`. shellcheck가 zsh를 지원하지 않으므로 최소한의 파싱 검증.
- **job `install-smoke`** — `ubuntu-latest`, 신규 테스트 파일 없이 워크플로 step만으로 구성
  - 임시 `HOME`에서 `sh install.sh` 실행 → `~/.local/bin/workytree --version` 출력 확인 → `.zshrc`에 source 줄 1회 추가 확인 → 재실행 시 멱등 확인.
  - `tests/install.test.zsh`가 이미 유사 검증을 하므로, 이 job은 **실제 기본 경로(`$HOME/.local/*`)에 대한 end-to-end 확인** 역할만 한다. 중복이 크면 제거 대상.

### 4.2 `release.yml` — 태그 릴리스

- **트리거:** `push` tags `v*.*.*`
- **step 1 버전 일치 검증:** 태그 `vX.Y.Z`의 `X.Y.Z`가 `bin/workytree`의 `WORKYTREE_VERSION`과 같지 않으면 실패. 불일치 릴리스를 원천 차단.
- **step 2 테스트 재실행:** `zsh tests/run.zsh` (ubuntu만, 태그가 main의 통과 커밋을 가리킨다는 가정 하에 이중 안전장치).
- **step 3 GitHub Release 생성:** `softprops/action-gh-release` 또는 `gh release create` 사용, `--generate-notes`. 첨부 자산 없음 — 설치는 여전히 `git clone`이므로 tarball은 GitHub이 자동 제공하는 것으로 충분.
- 권한: `permissions: contents: write` — 이 워크플로에만 부여, `ci.yml`은 `contents: read`.

### 4.3 릴리스 절차 (사람이 하는 부분)

1. `bin/workytree`의 `WORKYTREE_VERSION` 올리고 PR → merge.
2. `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. `release.yml`이 검증 후 Release 생성.

`install.sh`의 `git pull --ff-only` 업데이트 경로는 main을 따라가므로 태그와 무관하게 동작한다. 태그는 "안정 버전 표식 + 릴리스 노트" 용도.

### 4.4 브랜치 보호 (GitHub 설정, 워크플로 외)

- main에 required status checks: `test (macos-latest)`, `test (ubuntu-latest)`, `lint`.
- 직접 push 금지, PR 필수. 리뷰 승인 수는 1인 프로젝트이므로 0.
- 이 설정은 코드로 관리하지 않고 저장소 Settings에서 수동 적용. 적용 명령: `gh api -X PUT repos/Ahngbeom/workytree/branches/main/protection …` (실행은 사용자 확인 후).

### 4.5 부수 변경

- `install.sh` 19행: `# shellcheck disable=SC1007` 주석 추가.
- README "Install" 절: "does not work yet" 문구는 저장소가 이미 public GitHub에 있으므로 실제 curl 경로가 동작하는지 `install-smoke` job으로 확인 후 문구 갱신 (동작한다면 삭제).
- README에 CI 상태 배지 추가.

## 5. 리스크와 미확인 사항

| 항목 | 내용 | 대응 |
|---|---|---|
| ubuntu zsh 버전 | apt zsh가 5.9가 아닐 경우 `extendedglob`/`${0:A}` 등 동작 차이 가능 | 첫 실행에서 확인. 5.8 이하면 `ppa` 또는 macOS-only로 축소 |
| Linux 경로 차이 | `mktemp -d`가 `/tmp`, `:A` 해석 등 helpers가 macOS `/private/var` 전제로 주석 작성됨 | 테스트가 이미 `:A`로 정규화하므로 문제 없을 가능성 높음. 실패 시 개별 수정 |
| 테스트 시간 | 로컬 35초, GitHub macOS 러너는 2–3배 느릴 수 있음 | 10분 타임아웃 내 충분. 병렬화는 불필요 |
| `install.sh` 네트워크 | `install-smoke`가 체크아웃 안에서 실행되면 `FROM_CHECKOUT=1` 경로만 검증됨 | curl 경로 검증은 `WORKYTREE_REPO_URL`을 체크아웃 `file://` 경로로 주어 clone 경로도 확인 |
| 브랜치 보호 | 워크플로 파일로는 강제 불가 | 4.4 수동 절차, 사용자 승인 필요 |

## 6. 검증 기준

- [ ] PR 생성 시 `test`×2, `lint`, `install-smoke` 4개 체크가 모두 녹색.
- [ ] 의도적으로 테스트 하나를 깨뜨린 PR에서 `test`가 빨간색.
- [ ] `WORKYTREE_VERSION`과 다른 태그를 push하면 `release.yml`이 step 1에서 실패하고 Release가 생성되지 않음.
- [ ] 일치하는 태그 push 시 Release가 자동 노트와 함께 생성됨.
- [ ] `act` 또는 로컬에서 `shellcheck`·`zsh -n`·`zsh tests/run.zsh`가 CI와 동일 명령으로 통과.

## 7. 구현 순서 (플랜 작성 시 태스크 단위)

1. `install.sh` SC1007 주석, `.github/workflows/ci.yml` (test + lint) — PR로 올려 macOS/Linux 첫 결과 확인.
2. Linux에서 실패하는 테스트가 있으면 수정.
3. `install-smoke` job 추가, README 설치 문구 갱신.
4. `.github/workflows/release.yml` + 버전 검증 스크립트.
5. 브랜치 보호 적용(수동), README 배지.
6. `v0.1.0` 태그로 첫 릴리스 — 파이프라인 end-to-end 확인.

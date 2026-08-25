# workytree 상용화 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `oldwt`를 프로젝트(repo_root+worktree_root 쌍) 단위 설정과 대화형 create를 갖춘, 누구나 설치 가능한 `workytree`/`wt` 명령으로 재구성한다.

**Architecture:** `bin/workytree`(zsh)가 `lib/*.zsh`를 source 해 실행되는 순수 CLI(경로 계산·git 호출·출력만, `cd` 안 함). `shell/workytree.zsh`가 같은 이름의 셸 함수로 감싸 `create`/`cd`의 마지막 출력 줄로 `builtin cd` 한다. 설정은 `~/.config/workytree/config`(INI 계열) 하나이며 `lib/config.zsh`만 그 파일을 읽고 쓴다.

**Tech Stack:** zsh 5.8+, git 2.31+ (`--path-format=absolute`), 선택적 `fzf`. 테스트는 외부 프레임워크 없이 zsh + 임시 git repo.

**Spec:** `docs/superpowers/specs/2026-08-25-workytree-commercialization-design.md`

## Global Constraints

- 구현 언어는 zsh. 외부 의존성 없음(`fzf`는 선택). `bin/workytree`는 `set -u`, `setopt extendedglob` 하에 동작한다.
- 설정 파일: `${WORKYTREE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/workytree/config}`.
- worktree 경로 규칙: `<worktree_root>/<repo>/<kind>/<ticket>`, 브랜치 `<kind>/<ticket>`. 변경 금지(oldwt 호환).
- 출력 규약: `create`/`path`는 **마지막 stdout 줄이 경로**. 진행 메시지는 그 앞 줄에 출력.
- 종료 코드: 0 성공 / 1 일반 오류 / 2 사용법 오류 / 3 설정 없음 / 130 대화형 취소.
- 오류 메시지 접두어는 `workytree: ` 이고 stderr로 출력.
- 대화형 입력은 `${WORKYTREE_PROMPT_INPUT:-/dev/tty}`에서 읽는다. `--yes`/`-y` 또는 `/dev/tty`를 열 수 없으면 비대화형.
- 공통 옵션 `--project <name>`, `--yes|-y`, `--no-color`는 어느 위치에 와도 인식한다.
- 커밋 메시지 끝에 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` 및 세션 링크를 붙인다.

---

## File Structure

| 파일 | 책임 |
|---|---|
| `bin/workytree` | 진입점. 전역 옵션 파싱, 서브커맨드 디스패치, `help`/`--version` |
| `lib/ui.zsh` | `info/success/warn/error/die/usage_error` 색상 출력 |
| `lib/config.zsh` | 설정 파일 파싱→전역 배열, `config_get/config_set/config_unset/config_remove_section`, `expand_path` |
| `lib/resolve.zsh` | `require_config`, repo 스캔/등록/해석, `project_of_path`, `infer_current_repo`, `worktree_path`, `default_base_ref` |
| `lib/prompt.zsh` | `prompt_available/prompt_confirm/prompt_input/prompt_choose` |
| `lib/cmd/{repos,list,path,create,remove,prune,project,repo,config,init,complete}.zsh` | 서브커맨드 하나당 하나. 함수명 `cmd_<name>` |
| `shell/workytree.zsh` | `workytree()`/`wt()` 셸 함수(auto-cd), completion 등록 |
| `shell/completions/_workytree` | zsh completion. `workytree __complete …` 만 호출 |
| `install.sh` | clone/symlink/.zshrc 등록 |
| `tests/run.zsh`, `tests/helpers.zsh`, `tests/*.test.zsh` | 테스트 러너/헬퍼/케이스 |

### 전역 상태 (lib/config.zsh 가 정의, 모든 lib/cmd 가 읽음)

```zsh
typeset -g  WT_CONFIG_FILE          # 설정 파일 절대 경로
typeset -gi WT_CONFIG_EXISTS=0
typeset -gA WT_CFG                  # 전역 키 → 값           예: WT_CFG[default_project]
typeset -ga WT_PROJECTS             # 프로젝트 이름(파일 순서)
typeset -gA WT_PCFG                 # "<project>.<key>" → 값  예: WT_PCFG[fd.repo_root]
typeset -ga WT_REPOS                # 등록 repo 이름
typeset -gA WT_RCFG                 # "<repo>.<key>" → 값     키: path, project
typeset -g  WT_PROJECT_OPT=""       # --project 값 (bin/workytree 가 설정)
typeset -gi WT_YES=0                # --yes
```

---

### Task 1: 스캐폴드 — 테스트 러너, ui.zsh, bin/workytree 디스패치

**Files:**
- Create: `tests/run.zsh`, `tests/helpers.zsh`, `tests/cli.test.zsh`
- Create: `lib/ui.zsh`, `bin/workytree`
- Create: `.gitignore`

**Interfaces:**
- Produces: `info`, `success`, `warn`, `error`, `die <msg>`(exit 1), `usage_error <msg>`(exit 2), `usage`(stdout), `main`. `bin/workytree`는 `lib/*.zsh`와 `lib/cmd/*.zsh`를 모두 source 하고 `cmd_<name>`을 호출한다. 테스트 헬퍼: `setup_env`, `make_repo <dir>`, `write_config`(stdin), `wt …`, `assert_eq <actual> <expected> [msg]`, `assert_contains <haystack> <needle> [msg]`, `assert_exit <code> cmd…`, `assert_dir <path>`, `assert_not_exists <path>`, `run_tests`.

- [ ] **Step 1: 테스트 러너와 헬퍼 작성**

`tests/run.zsh`:
```zsh
#!/usr/bin/env zsh
# Runs every tests/*.test.zsh in its own process; exit 1 if any file fails.
cd "${0:A:h:h}" || exit 1
rc=0
for f in tests/*.test.zsh; do
  print "== $f"
  zsh "$f" || rc=1
done
exit $rc
```

`tests/helpers.zsh`:
```zsh
# Shared helpers for tests/*.test.zsh. Source this at the top of each test file.
WT_TEST_ROOT="${0:A:h:h}"
WT_BIN="$WT_TEST_ROOT/bin/workytree"
typeset -gi _pass=0 _fail=0
typeset -g TMP_ROOT=""

setup_env() {
  TMP_ROOT="$(mktemp -d)"
  export HOME="$TMP_ROOT/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  unset WORKYTREE_PROMPT_INPUT WORKYTREE_CONFIG WORKYTREE_ALIAS
  cd "$TMP_ROOT"
}
teardown_env() { cd /; [[ -n "$TMP_ROOT" ]] && rm -rf "$TMP_ROOT"; }

# make_repo <dir>: git repo on branch main with one commit
make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  print hello > "$1/README.md"
  git -C "$1" add -A && git -C "$1" commit -qm init
}

write_config() { mkdir -p "$XDG_CONFIG_HOME/workytree"; cat > "$XDG_CONFIG_HOME/workytree/config"; }

wt() { "$WT_BIN" "$@"; }

assert_eq() {
  if [[ "$1" == "$2" ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL ${3:-}: expected [$2] got [$1]"; fi
}
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL ${3:-}: [$1] does not contain [$2]"; fi
}
assert_exit() {
  local want="$1"; shift
  "$@" >/dev/null 2>&1; local got=$?
  assert_eq "$got" "$want" "exit code of: $*"
}
assert_dir() { if [[ -d "$1" ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL: dir missing $1"; fi }
assert_not_exists() { if [[ ! -e "$1" ]]; then (( ++_pass )); else (( ++_fail )); print -u2 "  FAIL: exists $1"; fi }

run_tests() {
  local t
  for t in ${(ok)functions[(I)test_*]}; do
    setup_env
    print "  $t"
    $t
    teardown_env
  done
  print "$_pass passed, $_fail failed"
  (( _fail == 0 ))
}
```

`.gitignore`:
```
.DS_Store
*.bak
```

- [ ] **Step 2: 실패하는 CLI 테스트 작성**

`tests/cli.test.zsh`:
```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

test_version_prints_semver() {
  local out; out="$(wt --version)"
  assert_eq "$?" 0
  assert_contains "$out" "workytree 0."
}

test_help_exits_zero() {
  assert_exit 0 wt help
  assert_exit 0 wt --help
  assert_contains "$(wt help)" "workytree create"
}

test_no_args_is_usage_error() { assert_exit 2 wt; }

test_unknown_command_is_usage_error() {
  assert_exit 2 wt bogus
  assert_contains "$(wt bogus 2>&1)" "workytree: unknown command: bogus"
}

test_global_options_are_accepted_anywhere() {
  # --no-color / -y / --project are consumed before dispatch; help still works after them
  assert_exit 0 wt --no-color help
  assert_exit 0 wt help -y --project x
}

run_tests
```

- [ ] **Step 3: 실패 확인**

Run: `zsh tests/run.zsh`
Expected: `bin/workytree: no such file` 류 오류로 FAIL.

- [ ] **Step 4: ui.zsh 작성**

`lib/ui.zsh`:
```zsh
# Colored output helpers. Color only when stdout is a TTY, NO_COLOR is unset, and --no-color not given.
typeset -gi WT_COLOR=1
ui_init() {
  if (( WT_COLOR )) && [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    WT_C_INFO=$'\033[38;5;39m' WT_C_OK=$'\033[38;5;70m' WT_C_WARN=$'\033[38;5;178m'
    WT_C_ERR=$'\033[38;5;196m' WT_C_DIM=$'\033[38;5;244m' WT_C_RESET=$'\033[0m'
  else
    WT_C_INFO='' WT_C_OK='' WT_C_WARN='' WT_C_ERR='' WT_C_DIM='' WT_C_RESET=''
  fi
}
info()    { print -r -- "${WT_C_INFO}$*${WT_C_RESET}"; }
success() { print -r -- "${WT_C_OK}$*${WT_C_RESET}"; }
warn()    { print -r -- "${WT_C_WARN}$*${WT_C_RESET}"; }
dim()     { print -r -- "${WT_C_DIM}$*${WT_C_RESET}"; }
error()   { print -u2 -r -- "${WT_C_ERR}workytree: $*${WT_C_RESET}"; }
die()         { error "$*"; exit 1; }
usage_error() { error "$*"; exit 2; }
```

- [ ] **Step 5: bin/workytree 작성**

`bin/workytree`:
```zsh
#!/usr/bin/env zsh
# workytree — git worktree manager. Pure CLI: computes paths, calls git, prints. Never cd's.
set -u
setopt extendedglob
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:${PATH:-}"

typeset -g WORKYTREE_VERSION="0.1.0"
typeset -g WORKYTREE_HOME="${0:A:h:h}"   # :A resolves the ~/.local/bin symlink

typeset -g  WT_PROJECT_OPT=""
typeset -gi WT_YES=0
typeset -ga ARGS

local f
for f in "$WORKYTREE_HOME"/lib/*.zsh(N) "$WORKYTREE_HOME"/lib/cmd/*.zsh(N); do
  source "$f"
done

usage() {
  cat <<'EOF'
Usage: workytree <command> [args] [--project <name>] [--yes|-y] [--no-color]

  workytree init [name repo_root worktree_root]      interactive first-time setup
  workytree create [repo] [kind] [ticket] [base]     create (or reuse) a worktree; asks for missing args
  workytree remove <repo> <kind> <ticket> [--force] [-b|--branch] [-B|--branch-force]
  workytree prune [repo]                             prune stale refs + orphan dirs
  workytree list [repo]                              git worktree list per repo
  workytree repos                                    repos across all projects
  workytree path [repo [kind [ticket]]]              print a path (script-friendly)
  workytree cd   [repo [kind [ticket]]]              cd (shell integration only)
  workytree project list|add <name> <repo_root> <worktree_root>|remove <name>|default <name>
  workytree repo    list|add <path> [--name n] [--project p]|remove <name>
  workytree config  path|get <key>|set <key> <value>|edit
  workytree help | --version
EOF
}

parse_global_opts() {
  ARGS=()
  while (( $# )); do
    case "$1" in
      --project)   shift; [[ $# -gt 0 ]] || usage_error "--project requires a name"; WT_PROJECT_OPT="$1" ;;
      --project=*) WT_PROJECT_OPT="${1#--project=}" ;;
      --yes|-y)    WT_YES=1 ;;
      --no-color)  WT_COLOR=0 ;;
      *)           ARGS+=("$1") ;;
    esac
    shift
  done
}

main() {
  parse_global_opts "$@"
  ui_init
  set -- "${ARGS[@]}"
  (( $# )) || { usage >&2; exit 2; }
  local command="$1"; shift
  case "$command" in
    help|-h|--help) usage ;;
    --version|version) print -r -- "workytree $WORKYTREE_VERSION" ;;
    init|create|remove|prune|list|repos|path|cd|project|repo|config|__complete)
      (( $+functions[cmd_$command] )) || die "command not implemented yet: $command"
      "cmd_$command" "$@" ;;
    *) usage >&2; usage_error "unknown command: $command" ;;
  esac
}

main "$@"
```

Run: `chmod +x bin/workytree tests/run.zsh`

- [ ] **Step 6: 테스트 통과 확인**

Run: `zsh tests/run.zsh`
Expected: `5 passed, 0 failed`

- [ ] **Step 7: 커밋**

```bash
git add .gitignore bin lib tests
git commit -m "feat: workytree CLI 스캐폴드 (디스패치, ui, 테스트 러너)"
```

---

### Task 2: config.zsh — 설정 파싱/쓰기 + `config` 명령

**Files:**
- Create: `lib/config.zsh`, `lib/cmd/config.zsh`
- Test: `tests/config.test.zsh`

**Interfaces:**
- Produces: `config_file_path`, `config_load`(파일 없으면 빈 상태·rc 0), `expand_path <p>`, `config_get <dotted-key>`(없으면 rc 1), `config_set <dotted-key> <value>`, `config_unset <dotted-key>`, `config_remove_section <project|repo> <name>`. dotted-key: `default_project` | `project.<name>.<key>` | `repo.<name>.<key>`. 모든 쓰기 함수는 끝에 `config_load`를 다시 호출한다.
- `cmd_config path|get|set|edit`.

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/config.test.zsh`:
```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

test_config_path_honors_xdg() {
  assert_eq "$(wt config path)" "$XDG_CONFIG_HOME/workytree/config"
  WORKYTREE_CONFIG=/x/y wt config path | read -r p; assert_eq "$p" "/x/y"
}

test_get_reads_global_project_repo_keys() {
  write_config <<'EOF'
# top comment
default_project = fd   # trailing comment
kinds = feature,fix

[project fd]
repo_root     = ~/products
worktree_root = ~/wts

[repo backend]
path = ~/src/api
project = fd
EOF
  assert_eq "$(wt config get default_project)" "fd"
  assert_eq "$(wt config get kinds)" "feature,fix"
  assert_eq "$(wt config get project.fd.repo_root)" "$HOME/products"
  assert_eq "$(wt config get repo.backend.project)" "fd"
  assert_exit 1 wt config get project.fd.nope
}

test_set_replaces_in_place_and_preserves_comments() {
  write_config <<'EOF'
# keep me
default_project = fd

[project fd]
repo_root = ~/a
worktree_root = ~/b
EOF
  wt config set project.fd.worktree_root ~/c
  wt config set default_project other
  local f="$XDG_CONFIG_HOME/workytree/config"
  assert_contains "$(cat "$f")" "# keep me"
  assert_eq "$(grep -c 'worktree_root' "$f")" "1"
  assert_eq "$(wt config get project.fd.worktree_root)" "$HOME/c"
  assert_eq "$(wt config get default_project)" "other"
}

test_set_appends_missing_key_and_section() {
  write_config <<'EOF'
[project fd]
repo_root = ~/a
EOF
  wt config set project.fd.worktree_root ~/b
  wt config set project.new.repo_root ~/n
  wt config set alias_wt false
  local f="$XDG_CONFIG_HOME/workytree/config"
  assert_eq "$(wt config get project.fd.worktree_root)" "$HOME/b"
  assert_eq "$(wt config get project.new.repo_root)" "$HOME/n"
  assert_eq "$(wt config get alias_wt)" "false"
  # global key must land before the first section header
  assert_eq "$(head -1 "$f")" "alias_wt = false"
}

test_set_creates_file_when_missing() {
  wt config set default_project fd
  assert_eq "$(wt config get default_project)" "fd"
}

test_parse_error_reports_line() {
  write_config <<'EOF'
default_project = fd
this is not valid
EOF
  local out; out="$(wt config get default_project 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "config:2"
}

test_duplicate_project_is_error() {
  write_config <<'EOF'
[project a]
repo_root = ~/x
worktree_root = ~/y
[project a]
repo_root = ~/z
worktree_root = ~/w
EOF
  assert_exit 1 wt config get default_project
}

run_tests
```


- [ ] **Step 2: 실패 확인**

Run: `zsh tests/config.test.zsh`
Expected: `command not implemented yet: config` 로 FAIL.

- [ ] **Step 3: lib/config.zsh 작성**

```zsh
# Single point of config-file I/O. Format: INI-like; "[project <name>]" / "[repo <name>]" sections,
# "key = value" lines, "#" comments (whole line, or after whitespace). No repeated keys.
typeset -g  WT_CONFIG_FILE=""
typeset -gi WT_CONFIG_EXISTS=0
typeset -gA WT_CFG WT_PCFG WT_RCFG
typeset -ga WT_PROJECTS WT_REPOS

config_file_path() {
  print -r -- "${WORKYTREE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/workytree/config}"
}

# expand_path <p>: "~/x" and "$VAR"/"${VAR}" expansion; trailing slash removed.
expand_path() {
  local p="$1"
  [[ "$p" == "~" ]] && p="$HOME"
  p="${p/#\~\//$HOME/}"
  while [[ "$p" =~ '\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?' ]]; do
    p="${p/"$MATCH"/${(P)match[1]:-}}"
  done
  print -r -- "${p%/}"
}

_config_strip_comment() {
  local line="$1"
  [[ "$line" == [[:space:]]#\#* ]] && { print -r -- ""; return; }
  print -r -- "${line%%[[:space:]]##\#*}"
}

config_load() {
  WT_CONFIG_FILE="$(config_file_path)"
  WT_CFG=() WT_PCFG=() WT_RCFG=() WT_PROJECTS=() WT_REPOS=()
  WT_CONFIG_EXISTS=0
  [[ -f "$WT_CONFIG_FILE" ]] || return 0
  WT_CONFIG_EXISTS=1
  local raw line lineno=0 sect_type="" sect_name="" key value
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    (( lineno++ ))
    line="$(_config_strip_comment "${raw%%$'\r'}")"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ "$line" =~ '^[[:space:]]*\[[[:space:]]*(project|repo)[[:space:]]+([^]]*)\][[:space:]]*$' ]]; then
      sect_type="$match[1]"
      sect_name="${${match[2]##[[:space:]]#}%%[[:space:]]#}"
      if [[ "$sect_type" == project ]]; then
        (( ${WT_PROJECTS[(Ie)$sect_name]} )) && die "duplicate [project $sect_name] at $WT_CONFIG_FILE:$lineno"
        WT_PROJECTS+=("$sect_name")
      else
        (( ${WT_REPOS[(Ie)$sect_name]} )) && die "duplicate [repo $sect_name] at $WT_CONFIG_FILE:$lineno"
        WT_REPOS+=("$sect_name")
      fi
      continue
    fi
    if [[ "$line" =~ '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$' ]]; then
      key="$match[1]" value="${match[2]%%[[:space:]]#}"
      case "$sect_type" in
        "")      WT_CFG[$key]="$value" ;;
        project) WT_PCFG[$sect_name.$key]="$value" ;;
        repo)    WT_RCFG[$sect_name.$key]="$value" ;;
      esac
      continue
    fi
    die "config parse error at $WT_CONFIG_FILE:$lineno: $line"
  done < "$WT_CONFIG_FILE"
}

# _config_split_key <dotted> -> sets REPLY_TYPE REPLY_NAME REPLY_KEY
_config_split_key() {
  local key="$1" rest
  case "$key" in
    project.*.*|repo.*.*)
      REPLY_TYPE="${key%%.*}"; rest="${key#*.}"; REPLY_NAME="${rest%.*}"; REPLY_KEY="${rest##*.}" ;;
    *.*) usage_error "invalid config key: $key (use <key>, project.<name>.<key>, repo.<name>.<key>)" ;;
    *)   REPLY_TYPE="" REPLY_NAME="" REPLY_KEY="$key" ;;
  esac
}

# config_get <dotted-key>: prints value (path-like keys expanded); rc 1 if unset
config_get() {
  local REPLY_TYPE REPLY_NAME REPLY_KEY v
  _config_split_key "$1"
  case "$REPLY_TYPE" in
    project) (( ${+WT_PCFG[$REPLY_NAME.$REPLY_KEY]} )) || return 1; v="${WT_PCFG[$REPLY_NAME.$REPLY_KEY]}" ;;
    repo)    (( ${+WT_RCFG[$REPLY_NAME.$REPLY_KEY]} )) || return 1; v="${WT_RCFG[$REPLY_NAME.$REPLY_KEY]}" ;;
    *)       (( ${+WT_CFG[$REPLY_KEY]} )) || return 1; v="${WT_CFG[$REPLY_KEY]}" ;;
  esac
  case "$REPLY_KEY" in
    repo_root|worktree_root|path) expand_path "$v" ;;
    *) print -r -- "$v" ;;
  esac
}

# _config_write <type> <name> <key> <value> <delete:0|1>
# Rewrites the file line by line, replacing the key inside its section, appending the key
# at the end of the section, or appending a new section. Comments and order are preserved.
_config_write() {
  local want_type="$1" want_name="$2" key="$3" value="$4" delete="$5"
  local file tmp line cur_type="" cur_name="" in_target=0 seen_target=0 done=0
  file="$(config_file_path)"
  mkdir -p "${file:h}"
  [[ -f "$file" ]] || : > "$file"
  tmp="$(mktemp "${file}.XXXXXX")"
  [[ -z "$want_type" ]] && { in_target=1; seen_target=1; }
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ '^[[:space:]]*\[[[:space:]]*(project|repo)[[:space:]]+([^]]*)\][[:space:]]*$' ]]; then
        if (( in_target && !done && !delete )); then print -r -- "$key = $value"; done=1; fi
        cur_type="$match[1]"; cur_name="${${match[2]##[[:space:]]#}%%[[:space:]]#}"
        if [[ "$cur_type" == "$want_type" && "$cur_name" == "$want_name" ]]; then in_target=1; seen_target=1; else in_target=0; fi
        print -r -- "$line"; continue
      fi
      if (( in_target && !done )) && [[ "$(_config_strip_comment "$line")" =~ "^[[:space:]]*${key}[[:space:]]*=" ]]; then
        (( delete )) || print -r -- "$key = $value"
        done=1; continue
      fi
      print -r -- "$line"
    done < "$file"
    if (( !done && !delete )); then
      if (( seen_target )); then
        print -r -- "$key = $value"
      else
        print -r -- ""; print -r -- "[$want_type $want_name]"; print -r -- "$key = $value"
      fi
    fi
  } > "$tmp"
  mv "$tmp" "$file"
}

config_set()   { local REPLY_TYPE REPLY_NAME REPLY_KEY; _config_split_key "$1"; _config_write "$REPLY_TYPE" "$REPLY_NAME" "$REPLY_KEY" "$2" 0; config_load; }
config_unset() { local REPLY_TYPE REPLY_NAME REPLY_KEY; _config_split_key "$1"; _config_write "$REPLY_TYPE" "$REPLY_NAME" "$REPLY_KEY" "" 1; config_load; }

# config_remove_section <project|repo> <name>: drops the header and every line until the next header
config_remove_section() {
  local want_type="$1" want_name="$2" file tmp line skipping=0
  file="$(config_file_path)"
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "${file}.XXXXXX")"
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ '^[[:space:]]*\[[[:space:]]*(project|repo)[[:space:]]+([^]]*)\][[:space:]]*$' ]]; then
        local n="${${match[2]##[[:space:]]#}%%[[:space:]]#}"
        if [[ "$match[1]" == "$want_type" && "$n" == "$want_name" ]]; then skipping=1; continue; else skipping=0; fi
      fi
      (( skipping )) || print -r -- "$line"
    done < "$file"
  } > "$tmp"
  mv "$tmp" "$file"
  config_load
}
```

`_config_write`에서 global 키(`want_type` 비어 있음)는 처음부터 `in_target=1`이므로 첫 섹션 헤더 직전에 삽입된다 — 테스트 `head -1 == "alias_wt = false"`가 이를 검증한다.

- [ ] **Step 4: lib/cmd/config.zsh 작성 + main에서 config_load 호출**

`lib/cmd/config.zsh`:
```zsh
cmd_config() {
  local sub="${1:-}"; shift 2>/dev/null
  case "$sub" in
    path) config_file_path ;;
    get)  [[ $# -eq 1 ]] || usage_error "usage: workytree config get <key>"
          config_get "$1" || { error "config key not set: $1"; exit 1; } ;;
    set)  [[ $# -eq 2 ]] || usage_error "usage: workytree config set <key> <value>"
          config_set "$1" "$2"; success "set $1 = $2" ;;
    edit) local f; f="$(config_file_path)"; mkdir -p "${f:h}"; [[ -f "$f" ]] || : > "$f"
          exec "${VISUAL:-${EDITOR:-vi}}" "$f" ;;
    *)    usage_error "usage: workytree config path|get <key>|set <key> <value>|edit" ;;
  esac
}
```

`bin/workytree`의 `main`에서 `ui_init` 다음 줄에 `config_load`를 추가한다:
```zsh
  ui_init
  config_load
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `zsh tests/run.zsh`
Expected: 모든 파일 `0 failed`.

- [ ] **Step 6: 커밋**

```bash
git add lib/config.zsh lib/cmd/config.zsh bin/workytree tests/config.test.zsh
git commit -m "feat: 설정 파일 파싱/쓰기 및 config 명령"
```

---

### Task 3: resolve.zsh — repo 해석 + `repos`/`path`/`list`

**Files:**
- Create: `lib/resolve.zsh`, `lib/cmd/repos.zsh`, `lib/cmd/path.zsh`, `lib/cmd/list.zsh`
- Test: `tests/resolve.test.zsh`

**Interfaces:**
- Produces:
  - `require_config` (설정/프로젝트 없으면 exit 3; `--project`가 미존재 프로젝트면 exit 1)
  - `project_repo_root <p>`, `project_worktree_root <p>`, `project_scan_depth <p>`(기본 3), `config_kinds`(배열 출력, 기본 `feature fix chore hotfix refactor`)
  - `scan_project_repos <p>` / `registered_repos [p]` / `all_repos [p]` → 각 줄 `name<TAB>project<TAB>path`
  - `is_known_repo <name>` rc
  - `resolve_repo <name> [project]` → `project<TAB>path` (0개: exit 1, 2개 이상: exit 1 + 후보 나열)
  - `project_of_path <abs>` → 프로젝트 이름 또는 rc 1
  - `infer_current_repo` → `project<TAB>name<TAB>repo_path` 또는 rc 1
  - `worktree_path <project> <repo> <kind> <ticket>`, `worktree_parent <project> <repo> [kind]`
  - `default_base_ref <repo_path>`
- `cmd_repos`, `cmd_path`, `cmd_list`, `cmd_cd`(= `cmd_path`).

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/resolve.test.zsh`:
```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

# Two projects: fd (nested product/layer/repo layout) and me (flat)
fixture() {
  make_repo "$HOME/fd/products/acme/backend/server"
  make_repo "$HOME/fd/products/acme/frontend/front"
  make_repo "$HOME/me/src/blog"
  make_repo "$HOME/elsewhere/legacy-api"
  write_config <<EOF
default_project = fd
[project fd]
repo_root = ~/fd/products
worktree_root = ~/fd/wts
scan_depth = 4
[project me]
repo_root = ~/me/src
worktree_root = ~/me/wts
[repo api]
path = ~/elsewhere/legacy-api
project = me
EOF
}

test_missing_config_exits_3() {
  assert_exit 3 wt repos
  assert_contains "$(wt repos 2>&1)" "workytree init"
}

test_repos_lists_registered_then_scanned() {
  fixture
  local out; out="$(wt repos)"
  assert_contains "$out" "api"
  assert_contains "$out" "server"
  assert_contains "$out" "blog"
  assert_eq "$(wt repos | wc -l | tr -d ' ')" "4"
  assert_eq "$(wt repos | head -1 | cut -f1)" "api"
}

test_scan_depth_limits_discovery() {
  fixture
  wt config set project.fd.scan_depth 1
  local out; out="$(wt repos)"
  assert_eq "${out//server/}" "$out" "server must not be found at depth 1"
}

test_path_resolves_registered_and_scanned() {
  fixture
  assert_eq "$(wt path api)" "$HOME/elsewhere/legacy-api"
  assert_eq "$(wt path server)" "$HOME/fd/products/acme/backend/server"
  assert_eq "$(wt path server fix)" "$HOME/fd/wts/server/fix"
  assert_eq "$(wt path server fix PROJ-1)" "$HOME/fd/wts/server/fix/PROJ-1"
  assert_eq "$(wt path api fix PROJ-1)" "$HOME/me/wts/api/fix/PROJ-1"
}

test_ambiguous_name_needs_project() {
  fixture
  make_repo "$HOME/me/src/server"
  local out; out="$(wt path server 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "ambiguous"
  assert_contains "$out" "--project"
  assert_eq "$(wt path server --project me)" "$HOME/me/src/server"
}

test_unknown_repo_and_project() {
  fixture
  assert_exit 1 wt path nope
  assert_exit 1 wt path server --project ghost
}

test_path_without_args_infers_from_cwd() {
  fixture
  cd "$HOME/fd/products/acme/backend/server"
  assert_eq "$(wt path)" "$HOME/fd/products/acme/backend/server"
  cd "$HOME"
  assert_exit 1 wt path
}

test_list_shows_worktrees() {
  fixture
  assert_contains "$(wt list server)" "$HOME/fd/products/acme/backend/server"
  assert_contains "$(wt list)" "repo: blog"
}

run_tests
```

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/resolve.test.zsh`
Expected: `command not implemented yet: repos` 로 FAIL.

- [ ] **Step 3: lib/resolve.zsh 작성**

```zsh
# Repo/project resolution. Order: registered [repo] alias -> scan of every [project].repo_root -> cwd inference.

require_config() {
  if (( !WT_CONFIG_EXISTS )); then
    error "no config found at $WT_CONFIG_FILE"; error "run 'workytree init' to create one"; exit 3
  fi
  if (( ${#WT_PROJECTS} == 0 )); then
    error "no [project] defined in $WT_CONFIG_FILE"
    error "run 'workytree project add <name> <repo_root> <worktree_root>'"; exit 3
  fi
  if [[ -n "$WT_PROJECT_OPT" ]] && ! project_exists "$WT_PROJECT_OPT"; then
    die "unknown project: $WT_PROJECT_OPT (run 'workytree project list')"
  fi
}

project_exists()        { (( ${WT_PROJECTS[(Ie)$1]} )); }
project_repo_root()     { expand_path "${WT_PCFG[$1.repo_root]:-}"; }
project_worktree_root() { expand_path "${WT_PCFG[$1.worktree_root]:-}"; }
project_scan_depth()    { print -r -- "${WT_PCFG[$1.scan_depth]:-3}"; }
default_project()       { print -r -- "${WT_CFG[default_project]:-${WT_PROJECTS[1]:-}}"; }
config_kinds()          { print -r -- "${(s:,:)${WT_CFG[kinds]:-feature,fix,chore,hotfix,refactor}}"; }

# scan_project_repos <project>: "name\tproject\tpath" for every git repo under repo_root (depth-limited)
scan_project_repos() {
  local p="$1" root depth entry r
  root="$(project_repo_root "$p")"; depth="$(project_scan_depth "$p")"
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 2 -maxdepth $(( depth + 1 )) -name .git \( -type d -o -type f \) -print -prune 2>/dev/null \
    | while IFS= read -r entry; do r="${entry:h}"; print -r -- "${r:t}"$'\t'"$p"$'\t'"$r"; done | sort -u
}

registered_repos() {
  local filter="${1:-}" n p
  for n in "${WT_REPOS[@]}"; do
    p="${WT_RCFG[$n.project]:-}"
    [[ -n "$filter" && "$p" != "$filter" ]] && continue
    print -r -- "$n"$'\t'"$p"$'\t'"$(expand_path "${WT_RCFG[$n.path]:-}")"
  done
}

all_repos() {
  local filter="${1:-}" p
  { registered_repos "$filter"
    for p in "${WT_PROJECTS[@]}"; do
      [[ -n "$filter" && "$p" != "$filter" ]] && continue
      scan_project_repos "$p"
    done
  } | awk -F'\t' '!seen[$1 FS $3]++'
}

is_known_repo() { all_repos "$WT_PROJECT_OPT" | cut -f1 | grep -qx -- "$1"; }

# resolve_repo <name> [project] -> "project\tpath"
resolve_repo() {
  local name="$1" filter="${2:-$WT_PROJECT_OPT}" p n path line
  local -a matches
  if (( ${WT_REPOS[(Ie)$name]} )); then
    p="${WT_RCFG[$name.project]:-}"
    if [[ -z "$filter" || "$p" == "$filter" ]]; then
      print -r -- "$p"$'\t'"$(expand_path "${WT_RCFG[$name.path]:-}")"; return 0
    fi
  fi
  for p in "${WT_PROJECTS[@]}"; do
    [[ -n "$filter" && "$p" != "$filter" ]] && continue
    while IFS=$'\t' read -r n p path; do
      [[ "$n" == "$name" ]] && matches+=("$p"$'\t'"$path")
    done < <(scan_project_repos "$p")
  done
  case ${#matches} in
    0) error "repo not found: $name (run 'workytree repos')"; exit 1 ;;
    1) print -r -- "${matches[1]}" ;;
    *) error "repo name '$name' is ambiguous across projects; narrow it with --project <name>:"
       for line in "${matches[@]}"; do print -u2 -r -- "  ${line%%$'\t'*}"$'\t'"${line#*$'\t'}"; done
       exit 1 ;;
  esac
}

# project_of_path <path>: project whose repo_root or worktree_root contains it (longest match)
project_of_path() {
  local target="${1:A}" p root best="" bestlen=0
  for p in "${WT_PROJECTS[@]}"; do
    for root in "$(project_repo_root "$p")" "$(project_worktree_root "$p")"; do
      [[ -n "$root" ]] || continue
      root="${root:A}"
      [[ "$target" == "$root" || "$target" == "$root"/* ]] || continue
      (( ${#root} > bestlen )) && { best="$p"; bestlen=${#root}; }
    done
  done
  [[ -n "$best" ]] && print -r -- "$best"
}

# infer_current_repo -> "project\tname\trepo_path" for the canonical repo of cwd (works inside worktrees)
infer_current_repo() {
  local common repo_path p n
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  repo_path="${common:A:h}"
  for n in "${WT_REPOS[@]}"; do
    if [[ "$(expand_path "${WT_RCFG[$n.path]:-}"):A" == "$repo_path" ]]; then
      print -r -- "${WT_RCFG[$n.project]:-}"$'\t'"$n"$'\t'"$repo_path"; return 0
    fi
  done
  p="$(project_of_path "$repo_path")" || return 1
  print -r -- "$p"$'\t'"${repo_path:t}"$'\t'"$repo_path"
}

worktree_parent() { local p="$1" repo="$2" kind="${3:-}"; print -r -- "$(project_worktree_root "$p")/$repo${kind:+/$kind}"; }
worktree_path()   { print -r -- "$(project_worktree_root "$1")/$2/$3/$4"; }

default_base_ref() {
  local repo_path="$1" upstream current
  upstream="$(git -C "$repo_path" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" && "$upstream" != "@{upstream}" ]]; then print -r -- "$upstream"; return 0; fi
  current="$(git -C "$repo_path" branch --show-current 2>/dev/null || true)"
  [[ -n "$current" ]] || die "cannot determine base branch from $repo_path"
  print -r -- "$current"
}
```

- [ ] **Step 4: repos / path / list 명령 작성**

`lib/cmd/repos.zsh`:
```zsh
cmd_repos() {
  require_config
  all_repos "$WT_PROJECT_OPT" | while IFS=$'\t' read -r n p path; do
    printf '%s\t%s\t%s\n' "$n" "$p" "$path"
  done
}
```

`lib/cmd/path.zsh`:
```zsh
cmd_path() {
  require_config
  local r project repo_path
  case $# in
    0) r="$(infer_current_repo)" || die "not inside a workytree project (run 'workytree repos')"
       git rev-parse --show-toplevel ;;
    1) r="$(resolve_repo "$1")" || exit $?; print -r -- "${r#*$'\t'}" ;;
    2) r="$(resolve_repo "$1")" || exit $?; worktree_parent "${r%%$'\t'*}" "$1" "$2" ;;
    3) r="$(resolve_repo "$1")" || exit $?; worktree_path "${r%%$'\t'*}" "$1" "$2" "$3" ;;
    *) usage_error "usage: workytree path [repo [kind [ticket]]]" ;;
  esac
}
cmd_cd() { cmd_path "$@"; }
```

`lib/cmd/list.zsh`:
```zsh
cmd_list() {
  require_config
  local r path n p
  if (( $# == 1 )); then
    r="$(resolve_repo "$1")" || exit $?
    path="${r#*$'\t'}"
    info "repo: $1 (${r%%$'\t'*})"; success "path: $path"
    git -C "$path" worktree list | sed 's/^/  /'; return $?
  fi
  all_repos "$WT_PROJECT_OPT" | while IFS=$'\t' read -r n p path; do
    info "repo: $n ($p)"
    git -C "$path" worktree list | sed 's/^/  /'
  done
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `zsh tests/run.zsh`
Expected: `0 failed`.

- [ ] **Step 6: 커밋**

```bash
git add lib/resolve.zsh lib/cmd/repos.zsh lib/cmd/path.zsh lib/cmd/list.zsh tests/resolve.test.zsh
git commit -m "feat: 프로젝트 기반 repo 해석과 repos/path/list 명령"
```

---

### Task 4: `create` — 비대화형 경로

**Files:**
- Create: `lib/cmd/create.zsh`, `lib/prompt.zsh`(이번 태스크에서는 `prompt_available`만)
- Test: `tests/create.test.zsh`

**Interfaces:**
- Consumes: `resolve_repo`, `infer_current_repo`, `is_known_repo`, `worktree_path`, `default_base_ref`.
- Produces: `cmd_create [repo] [kind] [ticket] [base]`. 첫 positional이 repo로 취급되는 규칙: (a) positional이 4개이거나 (b) `is_known_repo`이거나 (c) cwd에서 repo를 추론할 수 없을 때. 그 외에는 cwd repo를 쓰고 positional은 kind부터 시작한다. `prompt_available` rc(0=대화형 가능). `create_do <project> <repo> <repo_path> <kind> <ticket> <base>`: 요약 출력 + `git worktree add`, 마지막 줄 경로.

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/create.test.zsh`:
```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

fixture() {
  make_repo "$HOME/src/app"
  make_repo "$HOME/src/lib"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

test_create_full_args_noninteractive() {
  fixture
  local out; out="$(wt create app fix PROJ-1 main 2>&1)"
  assert_eq "$?" 0
  assert_dir "$HOME/wts/app/fix/PROJ-1"
  assert_eq "$(git -C "$HOME/wts/app/fix/PROJ-1" branch --show-current)" "fix/PROJ-1"
  assert_eq "${out##*$'\n'}" "$HOME/wts/app/fix/PROJ-1" "last line is the path"
  assert_contains "$out" "result: created"
}

test_create_auto_base_uses_current_branch() {
  fixture
  git -C "$HOME/src/app" checkout -qb develop
  wt create app feature X >/dev/null
  assert_eq "$(git -C "$HOME/wts/app/feature/X" log --format=%s -1)" "init"
  assert_contains "$(wt create app feature Y 2>&1)" "develop (auto-detected)"
}

test_create_existing_branch_is_checked_out() {
  fixture
  git -C "$HOME/src/app" branch fix/OLD
  assert_contains "$(wt create app fix OLD 2>&1)" "existing branch"
  assert_eq "$(git -C "$HOME/wts/app/fix/OLD" branch --show-current)" "fix/OLD"
}

test_create_existing_path_is_reused() {
  fixture
  wt create app fix R1 >/dev/null
  local out; out="$(wt create app fix R1)"
  assert_contains "$out" "result: reused"
  assert_eq "${out##*$'\n'}" "$HOME/wts/app/fix/R1"
}

test_create_infers_repo_from_cwd() {
  fixture
  cd "$HOME/src/lib"
  wt create chore C1 >/dev/null
  assert_dir "$HOME/wts/lib/chore/C1"
  # ...and from inside a worktree of that repo
  cd "$HOME/wts/lib/chore/C1"
  wt create chore C2 >/dev/null
  assert_dir "$HOME/wts/lib/chore/C2"
}

test_create_missing_args_noninteractive_is_usage_error() {
  fixture
  assert_exit 2 wt create app fix
  assert_exit 2 wt create
  cd "$HOME/src/app"; assert_exit 2 wt create fix
}

test_create_unknown_repo_outside_project() {
  fixture
  assert_exit 1 wt create ghost fix T
}

run_tests
```

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/create.test.zsh`
Expected: `command not implemented yet: create`.

- [ ] **Step 3: prompt.zsh (최소) 작성**

`lib/prompt.zsh`:
```zsh
# Interactive prompts. Input comes from WORKYTREE_PROMPT_INPUT (tests) or /dev/tty; prompts are
# written to /dev/tty (or stderr under WORKYTREE_PROMPT_INPUT) so $(...) capture of stdout stays clean.
typeset -gi WT_PROMPT_FD=-1

prompt_available() {
  [[ -n "${WORKYTREE_PROMPT_INPUT:-}" ]] && return 0
  (( WT_YES )) && return 1
  { : < /dev/tty; } 2>/dev/null
}
```

- [ ] **Step 4: lib/cmd/create.zsh 작성**

```zsh
# create_do <project> <repo> <repo_path> <kind> <ticket> <base>
# Prints the summary, adds the worktree, and prints the path as the LAST line.
create_do() {
  local project="$1" repo="$2" repo_path="$3" kind="$4" ticket="$5" base="$6"
  local target branch base_label result
  target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
  branch="$kind/$ticket"
  info "source repo: $repo_path"
  info "target path: $target"
  info "branch name: $branch"
  if [[ -e "$target" ]]; then
    info "base ref: n/a (existing worktree)"
    success "result: reused"; print -r -- "$target"; return 0
  fi
  mkdir -p "${target:h}" || die "failed to create parent directory for $target"
  if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
    info "base ref: n/a (existing branch)"
    git -C "$repo_path" worktree add "$target" "$branch" || die "failed to create worktree"
  else
    info "base ref: $base"
    git -C "$repo_path" worktree add --no-track -b "$branch" "$target" "${base%% *}" || die "failed to create worktree"
  fi
  success "result: created"
  print -r -- "$target"
}

cmd_create() {
  require_config
  local -a pos; pos=("$@")
  (( ${#pos} <= 4 )) || usage_error "usage: workytree create [repo] [kind] [ticket] [base]"
  local repo="" kind="" ticket="" base="" project="" repo_path="" r inferred=""
  inferred="$(infer_current_repo 2>/dev/null)" || inferred=""

  if (( ${#pos} )) && { (( ${#pos} == 4 )) || is_known_repo "${pos[1]}" || [[ -z "$inferred" ]]; }; then
    repo="${pos[1]}"; pos=("${pos[@]:1}")
  fi
  kind="${pos[1]:-}" ticket="${pos[2]:-}" base="${pos[3]:-}"

  if [[ -n "$repo" ]]; then
    r="$(resolve_repo "$repo")" || exit $?
    project="${r%%$'\t'*}" repo_path="${r#*$'\t'}"
  elif [[ -n "$inferred" ]]; then
    project="${inferred%%$'\t'*}"; r="${inferred#*$'\t'}"; repo="${r%%$'\t'*}"; repo_path="${r#*$'\t'}"
    if prompt_available; then
      prompt_confirm "repo: $repo ($repo_path) — use this repo?" y || { repo="" repo_path=""; }
    fi
  fi

  if [[ -z "$repo_path" ]]; then
    prompt_available || usage_error "repo is required: workytree create <repo> <kind> <ticket> [base]"
    create_pick_repo   # sets project repo repo_path (Task 5)
  fi

  if [[ -z "$kind" ]]; then
    prompt_available || usage_error "kind is required: workytree create [repo] <kind> <ticket> [base]"
    prompt_choose "kind" 1 $(config_kinds); kind="$REPLY"
  fi
  if [[ -z "$ticket" ]]; then
    prompt_available || usage_error "ticket is required: workytree create [repo] <kind> <ticket> [base]"
    prompt_input "ticket" ""; ticket="$REPLY"
  fi

  local target; target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
  if [[ -z "$base" && ! -e "$target" ]] && ! git -C "$repo_path" show-ref --verify --quiet "refs/heads/$kind/$ticket"; then
    local auto; auto="$(default_base_ref "$repo_path")" || exit $?
    if prompt_available; then prompt_input "base branch" "$auto"; base="$REPLY"; else base="$auto"; fi
    [[ "$base" == "$auto" ]] && base="$auto (auto-detected)"
  fi

  if prompt_available && [[ ! -e "$target" ]]; then
    dim "──────────────────────────────" >&2
    print -u2 -r -- "repo:    $repo → $repo_path"
    print -u2 -r -- "target:  $target"
    print -u2 -r -- "branch:  $kind/$ticket${base:+  (base: $base)}"
    prompt_confirm "Create?" y || exit 130
  fi
  create_do "$project" "$repo" "$repo_path" "$kind" "$ticket" "$base"
}
```

`create_do`의 `"${base%% *}"`는 `origin/develop (auto-detected)` 라벨에서 실제 ref만 떼어 git에 넘긴다. Task 5 전에는 `prompt_available`이 항상 실패(비대화형)하므로 `prompt_*`/`create_pick_repo`는 호출되지 않는다.

- [ ] **Step 5: 테스트 통과 확인**

Run: `zsh tests/run.zsh`
Expected: `0 failed`.

- [ ] **Step 6: 커밋**

```bash
git add lib/prompt.zsh lib/cmd/create.zsh tests/create.test.zsh
git commit -m "feat: create 명령 (비대화형, cwd repo 추론)"
```

---

### Task 5: prompt.zsh — 대화형 create

**Files:**
- Modify: `lib/prompt.zsh`, `lib/cmd/create.zsh`
- Test: `tests/create_interactive.test.zsh`

**Interfaces:**
- Produces: `prompt_confirm <msg> [y|n]`(rc 0/1; `q`/EOF → exit 130), `prompt_input <msg> [default]`(→ `REPLY`), `prompt_choose <msg> <allow_free 0|1> <items…>`(→ `REPLY`; fzf 있고 `WORKYTREE_PROMPT_INPUT` 없으면 fzf, 아니면 번호 목록), `create_pick_repo`(프로젝트→repo 선택; `project repo repo_path` 설정).

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/create_interactive.test.zsh`:
```zsh
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
  answers "n" "1" "1" "P1" "" ""     # no -> project me -> repo app -> feature -> ticket -> base -> confirm
  wt create >/dev/null 2>&1
  assert_dir "$HOME/wts/app/feature/P1"
}

test_eof_cancels_without_side_effects() {
  fixture; answers "1"
  assert_exit 130 wt create
  assert_not_exists "$HOME/wts"
}

run_tests
```

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/create_interactive.test.zsh`
Expected: `prompt_confirm: command not found` 류로 FAIL.

- [ ] **Step 3: prompt.zsh 완성**

`lib/prompt.zsh`의 `prompt_available` 아래에 추가:
```zsh
_prompt_open() {
  (( WT_PROMPT_FD >= 0 )) && return 0
  exec {WT_PROMPT_FD}< "${WORKYTREE_PROMPT_INPUT:-/dev/tty}" || die "cannot open prompt input"
}
_prompt_say() {
  if [[ -n "${WORKYTREE_PROMPT_INPUT:-}" ]]; then print -n -r -- "$@" >&2; else print -n -r -- "$@" > /dev/tty; fi
}
_prompt_read() {
  _prompt_open
  if ! read -u $WT_PROMPT_FD -r REPLY; then _prompt_say $'\n'; exit 130; fi
  [[ "$REPLY" == q ]] && exit 130
}

# prompt_confirm <msg> [y|n] -> rc 0 yes / 1 no
prompt_confirm() {
  local msg="$1" def="${2:-y}" hint
  [[ "$def" == y ]] && hint="[Y/n]" || hint="[y/N]"
  while true; do
    _prompt_say "$msg $hint "; _prompt_read
    case "${REPLY:l}" in
      "")   [[ "$def" == y ]] && return 0 || return 1 ;;
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
  done
}

# prompt_input <msg> [default] -> REPLY
prompt_input() {
  local msg="$1" def="${2:-}"
  while true; do
    _prompt_say "$msg${def:+ [$def]}: "; _prompt_read
    [[ -z "$REPLY" && -n "$def" ]] && REPLY="$def"
    [[ -n "$REPLY" ]] && return 0
  done
}

# prompt_choose <msg> <allow_free 0|1> <items...> -> REPLY
prompt_choose() {
  local msg="$1" allow_free="$2"; shift 2
  local -a items; items=("$@")
  if (( $+commands[fzf] )) && [[ -z "${WORKYTREE_PROMPT_INPUT:-}" ]]; then
    local -a fz; fz=(--prompt "$msg> " --height 40% --reverse)
    (( allow_free )) && fz+=(--print-query)
    REPLY="$(printf '%s\n' "${items[@]}" | fzf "${fz[@]}" < /dev/tty 2> /dev/tty | tail -1)"
    [[ -n "$REPLY" ]] || exit 130
    return 0
  fi
  local i
  _prompt_say "$msg"$'\n'
  for (( i = 1; i <= ${#items}; i++ )); do _prompt_say "  $i) ${items[$i]}"$'\n'; done
  while true; do
    if (( allow_free )); then _prompt_say "choose [1-${#items}] or type a value: "; else _prompt_say "choose [1-${#items}]: "; fi
    _prompt_read
    if [[ "$REPLY" == <1-> ]] && (( REPLY >= 1 && REPLY <= ${#items} )); then REPLY="${items[$REPLY]}"; return 0; fi
    (( allow_free )) && [[ -n "$REPLY" ]] && return 0
  done
}
```

- [ ] **Step 4: create_pick_repo 추가**

`lib/cmd/create.zsh` 상단(`create_do` 앞)에 추가:
```zsh
# create_pick_repo: interactive project -> repo selection. Sets project, repo, repo_path in caller scope.
create_pick_repo() {
  local -a names
  if [[ -n "$WT_PROJECT_OPT" ]]; then project="$WT_PROJECT_OPT"
  elif (( ${#WT_PROJECTS} > 1 )); then prompt_choose "project" 0 "${WT_PROJECTS[@]}"; project="$REPLY"
  else project="${WT_PROJECTS[1]}"; fi
  names=( ${(f)"$(all_repos "$project" | cut -f1)"} )
  (( ${#names} )) || die "no repos found under project '$project' ($(project_repo_root "$project"))"
  prompt_choose "repo" 0 "${names[@]}"; repo="$REPLY"
  local r; r="$(resolve_repo "$repo" "$project")" || exit $?
  repo_path="${r#*$'\t'}"
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `zsh tests/run.zsh`
Expected: `0 failed`.

- [ ] **Step 6: 커밋**

```bash
git add lib/prompt.zsh lib/cmd/create.zsh tests/create_interactive.test.zsh
git commit -m "feat: 대화형 create 위저드 (프로젝트/repo/kind/ticket/base 선택)"
```

---

### Task 6: `remove`

**Files:**
- Create: `lib/cmd/remove.zsh`
- Test: `tests/remove.test.zsh`

**Interfaces:**
- Consumes: `resolve_repo`, `worktree_path`.
- Produces: `cmd_remove <repo> <kind> <ticket> [--force] [-b|--branch] [-B|--branch-force]`, 헬퍼 `worktree_status <path>`, `has_non_idea_changes <path>`, `has_dirty_submodule <path>`, `has_initialized_submodules <path>`, `dir_is_cruft_only <dir>`(Task 7도 사용).

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/remove.test.zsh`:
```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

fixture() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  wt create app fix T main >/dev/null
  WT="$HOME/wts/app/fix/T"
}

test_remove_clean_worktree() {
  fixture
  assert_exit 0 wt remove app fix T
  assert_not_exists "$WT"
  assert_contains "$(git -C "$HOME/src/app" branch)" "fix/T" "branch kept without -b"
}

test_remove_dirty_requires_force() {
  fixture; print x > "$WT/new.txt"
  local out; out="$(wt remove app fix T 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "--force"
  assert_dir "$WT"
  assert_exit 0 wt remove app fix T --force
  assert_not_exists "$WT"
}

test_remove_idea_only_is_discarded() {
  fixture; mkdir "$WT/.idea"; print x > "$WT/.idea/ws.xml"
  assert_contains "$(wt remove app fix T 2>&1)" "IDE state"
  assert_not_exists "$WT"
}

test_remove_with_branch_flags() {
  fixture
  wt remove app fix T -b >/dev/null
  assert_eq "$(git -C "$HOME/src/app" branch --list fix/T)" ""
  # unmerged branch: -b warns and keeps, -B deletes
  wt create app fix U main >/dev/null
  print y > "$HOME/wts/app/fix/U/f"; git -C "$HOME/wts/app/fix/U" add -A; git -C "$HOME/wts/app/fix/U" commit -qm c
  assert_contains "$(wt remove app fix U -b 2>&1)" "not deleted"
  assert_contains "$(git -C "$HOME/src/app" branch)" "fix/U"
  wt create app fix U >/dev/null
  wt remove app fix U -B >/dev/null
  assert_eq "$(git -C "$HOME/src/app" branch --list fix/U)" ""
}

test_remove_missing_path_and_bad_flag() {
  fixture
  assert_exit 1 wt remove app fix NOPE
  assert_exit 2 wt remove app fix T --bogus
  assert_exit 2 wt remove app
}

run_tests
```

- [ ] **Step 2: 실패 확인**

Run: `zsh tests/remove.test.zsh` → `command not implemented yet: remove`.

- [ ] **Step 3: lib/cmd/remove.zsh 작성**

```zsh
worktree_status() { git -C "$1" status --porcelain --untracked-files=normal 2>/dev/null; }
is_dirty_worktree() { [[ -n "$(worktree_status "$1")" ]]; }

# True if any dirty entry lies outside .idea/ — real work to protect. .idea/ is discardable IDE state.
has_non_idea_changes() {
  local line path
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in R*|C*) return 0 ;; esac
    path="${line:3}"
    case "$path" in .idea/*|.idea) ;; *) return 0 ;; esac
  done < <(worktree_status "$1")
  return 1
}

has_dirty_submodule() {
  git -C "$1" submodule foreach --recursive --quiet \
    'test -z "$(git status --porcelain --untracked-files=normal 2>/dev/null)" || exit 1' >/dev/null 2>&1
  (( $? != 0 ))
}
has_initialized_submodules() {
  [[ -n "$(git -C "$1" submodule foreach --recursive --quiet 'printf "%s\n" "$sm_path"' 2>/dev/null)" ]]
}

# dir_is_cruft_only <dir>: only .idea/, .DS_Store, or nothing at all
dir_is_cruft_only() {
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in */.idea/*) ;; */.DS_Store) ;; *) return 1 ;; esac
  done < <(find "$1" -type f 2>/dev/null)
  return 0
}

remove_branch() {
  local repo_path="$1" branch="$2" force="$3" flag='-d'
  [[ -n "$branch" ]] || { warn "no branch to delete (detached HEAD); skipping"; return 0; }
  (( force )) && flag='-D'
  if git -C "$repo_path" branch "$flag" "$branch" 2>/dev/null; then success "deleted branch: $branch"
  elif (( force )); then warn "failed to delete branch: $branch"
  else warn "branch not deleted (likely unmerged): $branch"; warn "re-run remove with --branch-force (-B) to force-delete it"; fi
}

cmd_remove() {
  require_config
  (( $# >= 3 )) || usage_error "usage: workytree remove <repo> <kind> <ticket> [--force] [-b|--branch] [-B|--branch-force]"
  local repo="$1" kind="$2" ticket="$3"; shift 3
  local force_remove=0 delete_branch=0 force_branch=0 arg
  for arg in "$@"; do
    case "$arg" in
      --force)           force_remove=1 ;;
      --branch|-b)       delete_branch=1 ;;
      --branch-force|-B) delete_branch=1; force_branch=1 ;;
      *) usage_error "unknown flag: $arg" ;;
    esac
  done
  local r project repo_path target branch
  r="$(resolve_repo "$repo")" || exit $?
  project="${r%%$'\t'*}" repo_path="${r#*$'\t'}"
  target="$(worktree_path "$project" "$repo" "$kind" "$ticket")"
  [[ -d "$target" ]] || die "worktree path not found: $target"
  branch="$(git -C "$target" branch --show-current 2>/dev/null || true)"

  info "removing worktree"; print -r -- "  path: $target"; [[ -n "$branch" ]] && print -r -- "  branch: $branch"
  git -C "$target" status --short --branch | sed 's/^/  /'

  local idea_only=0
  if has_non_idea_changes "$target" || has_dirty_submodule "$target"; then
    (( force_remove )) || die "worktree has changes outside .idea/ (or a dirty submodule); use --force to remove"
  elif is_dirty_worktree "$target"; then
    idea_only=1
    warn "worktree only has IDE state under .idea/ — discarding it:"; worktree_status "$target" | sed 's/^/  /'
  fi
  if (( force_remove || idea_only )) || has_initialized_submodules "$target"; then
    git -C "$repo_path" worktree remove --force "$target" || die "failed to remove worktree"
  else
    git -C "$repo_path" worktree remove "$target" || die "failed to remove worktree"
  fi
  git -C "$repo_path" worktree prune 2>/dev/null
  [[ -e "$target" ]] && { warn "worktree dir lingered after remove; deleting leftover: $target"; rm -rf "$target"; }
  success "removed: $target"
  (( delete_branch )) && remove_branch "$repo_path" "$branch" "$force_branch"
  return 0
}
```

- [ ] **Step 4: 테스트 통과 확인** — `zsh tests/run.zsh` → `0 failed`.

- [ ] **Step 5: 커밋**

```bash
git add lib/cmd/remove.zsh tests/remove.test.zsh
git commit -m "feat: remove 명령 (dirty 보호, .idea 자동 폐기, 브랜치 삭제 옵션)"
```

---

### Task 7: `prune [repo]`

**Files:**
- Create: `lib/cmd/prune.zsh`
- Test: `tests/prune.test.zsh`

**Interfaces:**
- Consumes: `resolve_repo`, `all_repos`, `worktree_parent`, `dir_is_cruft_only`.
- Produces: `cmd_prune [repo]`, `prune_repo <project> <repo> <repo_path>`.

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/prune.test.zsh`:
```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

fixture() {
  make_repo "$HOME/src/app"; make_repo "$HOME/src/lib"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

test_prune_removes_cruft_orphans_keeps_real() {
  fixture
  wt create app fix LIVE main >/dev/null
  mkdir -p "$HOME/wts/app/fix/ORPHAN/.idea"; print x > "$HOME/wts/app/fix/ORPHAN/.idea/a.xml"
  mkdir -p "$HOME/wts/app/chore/REAL"; print x > "$HOME/wts/app/chore/REAL/keep.txt"
  local out; out="$(wt prune app 2>&1)"
  assert_eq "$?" 0
  assert_not_exists "$HOME/wts/app/fix/ORPHAN"
  assert_dir "$HOME/wts/app/fix/LIVE"
  assert_dir "$HOME/wts/app/chore/REAL"
  assert_contains "$out" "skipped orphan"
}

test_prune_drops_stale_registration_and_empty_kind_dir() {
  fixture
  wt create app fix GONE main >/dev/null
  rm -rf "$HOME/wts/app/fix/GONE"
  wt prune app >/dev/null
  assert_eq "$(git -C "$HOME/src/app" worktree list | wc -l | tr -d ' ')" "1"
  assert_not_exists "$HOME/wts/app/fix"
}

test_prune_all_repos() {
  fixture
  mkdir -p "$HOME/wts/lib/fix/X"
  local out; out="$(wt prune 2>&1)"
  assert_contains "$out" "pruning worktrees for app"
  assert_contains "$out" "pruning worktrees for lib"
  assert_not_exists "$HOME/wts/lib/fix/X"
}

run_tests
```

- [ ] **Step 2: 실패 확인** — `zsh tests/prune.test.zsh` → not implemented.

- [ ] **Step 3: lib/cmd/prune.zsh 작성**

```zsh
prune_repo() {
  local project="$1" repo="$2" repo_path="$3" repo_wt_root
  repo_wt_root="$(worktree_parent "$project" "$repo")"
  info "pruning worktrees for $repo"
  git -C "$repo_path" worktree prune --verbose 2>&1 | sed 's/^/  /'
  [[ -d "$repo_wt_root" ]] || { dim "  no worktree dir for $repo"; return 0; }

  local -A registered; local wt dir kdir keep found=0
  while IFS= read -r wt; do [[ -n "$wt" ]] && registered[${wt:A}]=1; done < <(
    git -C "$repo_path" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10)}')

  # Candidates are <kind>/<ticket> = depth 2 under the repo's worktree dir.
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    [[ -n "${registered[${dir:A}]:-}" ]] && continue
    found=1
    if dir_is_cruft_only "$dir"; then rm -rf "$dir" && success "  removed orphan: $dir"
    else warn "  skipped orphan with real files (remove manually if intended): $dir"; fi
  done < <(find "$repo_wt_root" -mindepth 2 -maxdepth 2 -type d 2>/dev/null)

  while IFS= read -r kdir; do
    [[ -n "$kdir" ]] || continue
    keep=0
    for wt in "${(@k)registered}"; do [[ "$wt" == "${kdir:A}/"* ]] && { keep=1; break; }; done
    (( keep )) && continue
    dir_is_cruft_only "$kdir" && rm -rf "$kdir"
  done < <(find "$repo_wt_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  (( found )) || dim "  no orphan dirs found"
}

cmd_prune() {
  require_config
  local r n p path
  if (( $# == 1 )); then
    r="$(resolve_repo "$1")" || exit $?
    prune_repo "${r%%$'\t'*}" "$1" "${r#*$'\t'}"; return
  fi
  (( $# == 0 )) || usage_error "usage: workytree prune [repo]"
  all_repos "$WT_PROJECT_OPT" | while IFS=$'\t' read -r n p path; do prune_repo "$p" "$n" "$path"; done
}
```

- [ ] **Step 4: 테스트 통과 확인** — `zsh tests/run.zsh` → `0 failed`.

- [ ] **Step 5: 커밋**

```bash
git add lib/cmd/prune.zsh tests/prune.test.zsh
git commit -m "feat: prune 명령 (repo 생략 시 전체)"
```

---

### Task 8: `project` / `repo` 관리 명령

**Files:**
- Create: `lib/cmd/project.zsh`, `lib/cmd/repo.zsh`
- Test: `tests/manage.test.zsh`

**Interfaces:**
- Consumes: `config_set`, `config_unset`, `config_remove_section`, `project_of_path`, `default_project`.
- Produces: `cmd_project list|add <name> <repo_root> <worktree_root>|remove <name>|default <name>`, `cmd_repo list|add <path> [--name n] [--project p]|remove <name>`. `project add`는 설정 파일이 없어도 동작한다(첫 프로젝트가 default가 됨).

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/manage.test.zsh`:
```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

test_project_add_without_config_sets_default() {
  assert_exit 0 wt project add me ~/src ~/wts
  assert_eq "$(wt config get default_project)" "me"
  assert_eq "$(wt config get project.me.worktree_root)" "$HOME/wts"
  assert_contains "$(wt project list)" "* me"
}

test_project_add_validates() {
  wt project add me ~/src ~/wts >/dev/null
  assert_exit 1 wt project add me ~/x ~/y
  assert_exit 2 wt project add "bad name" ~/x ~/y
  assert_exit 2 wt project add only-two ~/x
}

test_project_default_and_remove() {
  wt project add a ~/a ~/aw >/dev/null; wt project add b ~/b ~/bw >/dev/null
  wt project default b >/dev/null
  assert_eq "$(wt config get default_project)" "b"
  assert_exit 1 wt project default ghost
  wt project remove b >/dev/null
  assert_exit 1 wt config get project.b.repo_root
  assert_eq "$(wt config get default_project)" "a" "default falls back to remaining project"
}

test_repo_add_list_remove() {
  make_repo "$HOME/elsewhere/api"; make_repo "$HOME/src/inside"
  wt project add me ~/src ~/wts >/dev/null
  wt repo add ~/elsewhere/api >/dev/null
  assert_eq "$(wt config get repo.api.project)" "me"
  wt repo add ~/elsewhere/api --name api2 --project me >/dev/null
  assert_contains "$(wt repo list)" "api2"
  assert_exit 1 wt repo add ~/elsewhere/api            # duplicate name
  assert_exit 1 wt repo add ~/nonexistent
  assert_exit 1 wt repo add ~/elsewhere/api --name z --project ghost
  wt repo remove api2 >/dev/null
  assert_exit 1 wt config get repo.api2.path
  assert_eq "$(wt path api)" "$HOME/elsewhere/api"
}

run_tests
```

- [ ] **Step 2: 실패 확인** — `zsh tests/manage.test.zsh` → not implemented.

- [ ] **Step 3: lib/cmd/project.zsh 작성**

```zsh
cmd_project() {
  local sub="${1:-list}"; (( $# )) && shift
  case "$sub" in
    list)
      (( ${#WT_PROJECTS} )) || { warn "no projects (run 'workytree project add <name> <repo_root> <worktree_root>')"; return 0; }
      local p mark def; def="$(default_project)"
      for p in "${WT_PROJECTS[@]}"; do
        [[ "$p" == "$def" ]] && mark="*" || mark=" "
        printf '%s %-16s repo_root=%s  worktree_root=%s\n' "$mark" "$p" "$(project_repo_root "$p")" "$(project_worktree_root "$p")"
      done ;;
    add)
      (( $# == 3 )) || usage_error "usage: workytree project add <name> <repo_root> <worktree_root>"
      local name="$1" rr="$2" wr="$3"
      [[ "$name" == [A-Za-z0-9_-]## ]] || usage_error "invalid project name: $name (use letters, digits, - and _)"
      project_exists "$name" && die "project already exists: $name"
      config_set "project.$name.repo_root" "$rr"
      config_set "project.$name.worktree_root" "$wr"
      [[ -n "${WT_CFG[default_project]:-}" ]] || config_set default_project "$name"
      success "added project $name (repo_root=$rr, worktree_root=$wr)" ;;
    remove)
      (( $# == 1 )) || usage_error "usage: workytree project remove <name>"
      project_exists "$1" || die "unknown project: $1"
      config_remove_section project "$1"
      if [[ "${WT_CFG[default_project]:-}" == "$1" ]]; then
        if (( ${#WT_PROJECTS} )); then config_set default_project "${WT_PROJECTS[1]}"; else config_unset default_project; fi
      fi
      success "removed project $1" ;;
    default)
      (( $# == 1 )) || usage_error "usage: workytree project default <name>"
      project_exists "$1" || die "unknown project: $1"
      config_set default_project "$1"; success "default project: $1" ;;
    *) usage_error "usage: workytree project list|add <name> <repo_root> <worktree_root>|remove <name>|default <name>" ;;
  esac
}
```

- [ ] **Step 4: lib/cmd/repo.zsh 작성**

```zsh
cmd_repo() {
  local sub="${1:-list}"; (( $# )) && shift
  case "$sub" in
    list)
      registered_repos | while IFS=$'\t' read -r n p path; do printf '%s\t%s\t%s\n' "$n" "$p" "$path"; done ;;
    add)
      require_config
      local path="" name="" project="" arg
      while (( $# )); do
        case "$1" in
          --name)    shift; name="${1:?--name requires a value}" ;;
          --project) shift; project="${1:?--project requires a value}" ;;
          -*)        usage_error "unknown flag: $1" ;;
          *)         [[ -z "$path" ]] || usage_error "usage: workytree repo add <path> [--name n] [--project p]"; path="$1" ;;
        esac; shift
      done
      [[ -n "$path" ]] || usage_error "usage: workytree repo add <path> [--name n] [--project p]"
      path="$(expand_path "$path")"; path="${path:A}"
      git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $path"
      [[ -n "$name" ]] || name="${path:t}"
      [[ "$name" == [A-Za-z0-9_.-]## ]] || usage_error "invalid repo name: $name"
      (( ${WT_REPOS[(Ie)$name]} )) && die "repo already registered: $name"
      if [[ -z "$project" ]]; then project="$(project_of_path "$path")" || project="$(default_project)"; fi
      project_exists "$project" || die "unknown project: $project"
      config_set "repo.$name.path" "$path"
      config_set "repo.$name.project" "$project"
      success "registered repo $name → $path (project $project)" ;;
    remove)
      (( $# == 1 )) || usage_error "usage: workytree repo remove <name>"
      (( ${WT_REPOS[(Ie)$1]} )) || die "repo not registered: $1"
      config_remove_section repo "$1"; success "unregistered repo $1" ;;
    *) usage_error "usage: workytree repo list|add <path> [--name n] [--project p]|remove <name>" ;;
  esac
}
```

- [ ] **Step 5: 테스트 통과 확인** — `zsh tests/run.zsh` → `0 failed`.

- [ ] **Step 6: 커밋**

```bash
git add lib/cmd/project.zsh lib/cmd/repo.zsh tests/manage.test.zsh
git commit -m "feat: project/repo 관리 명령"
```

---

### Task 9: `init`

**Files:**
- Create: `lib/cmd/init.zsh`
- Test: `tests/init.test.zsh`

**Interfaces:**
- Consumes: `prompt_*`, `cmd_project add`, `config_set`.
- Produces: `cmd_init [name repo_root worktree_root]`. 인자 3개면 비대화형. 설정이 이미 있으면 안내 후 exit 1(`project add` 사용 유도).

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/init.test.zsh`:
```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"
answers() { printf '%s\n' "$@" > "$TMP_ROOT/answers"; export WORKYTREE_PROMPT_INPUT="$TMP_ROOT/answers"; }

test_init_noninteractive_with_args() {
  assert_exit 0 wt init me ~/src ~/wts
  assert_eq "$(wt config get default_project)" "me"
  assert_eq "$(wt config get project.me.repo_root)" "$HOME/src"
  assert_eq "$(wt config get alias_wt)" "true"
}

test_init_interactive() {
  answers "fd" "$HOME/fd/products" "$HOME/fd/wts" "n"
  wt init >/dev/null 2>&1
  assert_eq "$?" 0
  assert_eq "$(wt config get project.fd.worktree_root)" "$HOME/fd/wts"
  assert_eq "$(wt config get alias_wt)" "false"
}

test_init_refuses_when_config_exists() {
  wt init me ~/src ~/wts >/dev/null
  local out; out="$(wt init me ~/src ~/wts 2>&1)"
  assert_eq "$?" 1
  assert_contains "$out" "project add"
}

test_init_without_args_noninteractive_is_usage_error() { assert_exit 2 wt init; }

run_tests
```

- [ ] **Step 2: 실패 확인** — `zsh tests/init.test.zsh` → not implemented.

- [ ] **Step 3: lib/cmd/init.zsh 작성**

```zsh
cmd_init() {
  (( WT_CONFIG_EXISTS )) && die "config already exists: $WT_CONFIG_FILE — add more with 'workytree project add' or edit with 'workytree config edit'"
  local name rr wr alias_wt=true
  if (( $# == 3 )); then
    name="$1" rr="$2" wr="$3"
  elif (( $# == 0 )); then
    prompt_available || usage_error "usage (non-interactive): workytree init <name> <repo_root> <worktree_root>"
    _prompt_say "workytree setup — a project pairs a repo_root (where your clones live) with a worktree_root."$'\n'
    prompt_input "project name" "${PWD:t}";                         name="$REPLY"
    prompt_input "repo_root (directory containing your repos)" "$HOME/src"; rr="$REPLY"
    prompt_input "worktree_root (where worktrees are created)" "$HOME/worktrees"; wr="$REPLY"
    prompt_confirm "install 'wt' as a short alias for workytree?" y && alias_wt=true || alias_wt=false
  else
    usage_error "usage: workytree init [<name> <repo_root> <worktree_root>]"
  fi
  cmd_project add "$name" "$rr" "$wr"
  config_set alias_wt "$alias_wt"
  success "config written: $WT_CONFIG_FILE"
  dim "next: 'workytree repos' to see discovered repos, 'workytree create' to start"
}
```

- [ ] **Step 4: 테스트 통과 확인** — `zsh tests/run.zsh` → `0 failed`.

- [ ] **Step 5: 커밋**

```bash
git add lib/cmd/init.zsh tests/init.test.zsh
git commit -m "feat: init 명령 (대화형/비대화형 초기 설정)"
```

---

### Task 10: 셸 통합 — `workytree()`/`wt()` 함수와 auto-cd

**Files:**
- Create: `shell/workytree.zsh`
- Test: `tests/shell.test.zsh`

**Interfaces:**
- Produces: sourcing 시 `workytree()` 셸 함수(`create`/`cd`는 마지막 출력 줄로 `builtin cd`, 나머지는 `bin/workytree`로 위임), `wt()`(config `alias_wt`가 false/0/no 가 아니고 `WORKYTREE_ALIAS != 0`이며 `wt`가 미정의일 때만), `WORKYTREE_ROOT`, `WORKYTREE_BIN`. completion 등록 훅 `_workytree_register_completion`(Task 11에서 파일 추가).

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/shell.test.zsh`:
```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"
SHELL_FILE="$WT_TEST_ROOT/shell/workytree.zsh"

# zsh_i <code>: run in an interactive zsh with an isolated ZDOTDIR that sources the integration
zsh_i() {
  export ZDOTDIR="$HOME"
  print -r -- "source '$SHELL_FILE'" > "$ZDOTDIR/.zshrc"
  zsh -i -c "$1" 2>&1
}

fixture() {
  make_repo "$HOME/src/app"
  write_config <<EOF
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

test_functions_defined_and_alias_default_on() {
  fixture
  assert_contains "$(zsh_i 'whence -w workytree wt')" "workytree: function"
  assert_contains "$(zsh_i 'whence -w workytree wt')" "wt: function"
}

test_alias_off_by_config_or_env() {
  fixture; wt config set alias_wt false >/dev/null
  assert_contains "$(zsh_i 'whence -w wt')" "wt: none"
  wt config set alias_wt true >/dev/null
  assert_contains "$(WORKYTREE_ALIAS=0 zsh_i 'whence -w wt')" "wt: none"
}

test_alias_skipped_when_wt_taken() {
  fixture
  print -r -- "wt() { echo mine; }; source '$SHELL_FILE'" > "$HOME/.zshrc"
  local out; out="$(ZDOTDIR="$HOME" zsh -i -c 'wt' 2>&1)"
  assert_contains "$out" "already defined"
  assert_contains "$out" "mine"
}

test_create_cds_into_worktree() {
  fixture
  assert_eq "$(zsh_i 'wt create app fix T main -y >/dev/null; pwd')" "$HOME/wts/app/fix/T"
  assert_eq "$(zsh_i 'wt cd app fix T >/dev/null; pwd')" "$HOME/wts/app/fix/T"
  assert_eq "$(zsh_i 'wt cd app >/dev/null; pwd')" "$HOME/src/app"
}

test_failure_keeps_cwd_and_exit_code() {
  fixture
  local out; out="$(zsh_i "cd $HOME; wt create ghost fix T -y; echo rc=\$?; pwd")"
  assert_contains "$out" "rc=1"
  assert_contains "$out" $'\n'"$HOME"
}

test_noninteractive_wrapper_prints_path() {
  fixture
  local out; out="$(ZDOTDIR=$HOME zsh -c "source '$SHELL_FILE'; workytree create app fix N main -y" | tail -1)"
  assert_eq "$out" "$HOME/wts/app/fix/N"
}

run_tests
```

- [ ] **Step 2: 실패 확인** — `zsh tests/shell.test.zsh` → `no such file: shell/workytree.zsh`.

- [ ] **Step 3: shell/workytree.zsh 작성**

```zsh
# workytree shell integration — source this from ~/.zshrc.
# Defines workytree() (and wt() unless disabled) so `create`/`cd` can change the caller's directory.
typeset -g WORKYTREE_ROOT="${${(%):-%x}:A:h:h}"
typeset -g WORKYTREE_BIN="$WORKYTREE_ROOT/bin/workytree"

workytree() {
  case "${1:-}" in
    create|cd) ;;
    *) "$WORKYTREE_BIN" "$@"; return $? ;;
  esac
  local output exit_code target head
  if [[ "$1" == cd ]]; then output="$("$WORKYTREE_BIN" path "${@:2}")"; else output="$("$WORKYTREE_BIN" "$@")"; fi
  exit_code=$?
  if [[ -n "$output" ]]; then
    target="${output##*$'\n'}"
    head="${output%"$target"}"; head="${head%$'\n'}"
    [[ -n "$head" ]] && print -r -- "$head"
  fi
  (( exit_code == 0 )) || return $exit_code
  if [[ -o interactive && -n "$target" && -d "$target" ]]; then
    builtin cd -- "$target" || return 1
    print -P "%F{70}cd:%f $target"
  elif [[ -n "$target" ]]; then
    print -r -- "$target"
  fi
  return 0
}

_workytree_alias_enabled() {
  [[ "${WORKYTREE_ALIAS:-1}" == 0 ]] && return 1
  local cfg="${WORKYTREE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/workytree/config}"
  [[ -f "$cfg" ]] || return 0
  ! grep -Eq '^[[:space:]]*alias_wt[[:space:]]*=[[:space:]]*(false|0|no)[[:space:]]*(#.*)?$' "$cfg"
}

if _workytree_alias_enabled; then
  if (( $+commands[wt] || $+functions[wt] || $+aliases[wt] )); then
    print -u2 "workytree: 'wt' is already defined; not installing the alias (set 'alias_wt = false' to silence)"
  else
    wt() { workytree "$@"; }
  fi
fi

_workytree_register_completion() {
  (( $+functions[compdef] )) || return 0
  local dir="$WORKYTREE_ROOT/shell/completions"
  [[ -d "$dir" ]] || return 0
  (( ${fpath[(Ie)$dir]} )) || fpath=("$dir" $fpath)
  autoload -Uz _workytree 2>/dev/null || return 0
  compdef _workytree workytree
  (( $+functions[wt] )) && compdef _workytree wt
}
_workytree_register_completion
```

- [ ] **Step 4: 테스트 통과 확인** — `zsh tests/run.zsh` → `0 failed`.

- [ ] **Step 5: 커밋**

```bash
git add shell/workytree.zsh tests/shell.test.zsh
git commit -m "feat: 셸 통합 (workytree/wt 함수, auto-cd, alias 옵트아웃)"
```

---

### Task 11: 자동완성 — `__complete` + `_workytree`

**Files:**
- Create: `lib/cmd/complete.zsh`, `shell/completions/_workytree`
- Test: `tests/complete.test.zsh`

**Interfaces:**
- Produces: `cmd___complete commands|projects|repos|kinds <repo>|tickets <repo> <kind>|branches <repo>` — 한 줄에 하나씩 후보 출력. 완성 파일은 이 출력만 사용한다(경로 하드코딩 없음).

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/complete.test.zsh`:
```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

fixture() {
  make_repo "$HOME/src/app"
  write_config <<EOF
kinds = feature,fix
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
  wt create app fix T1 main >/dev/null; wt create app fix T2 main >/dev/null
}

test_complete_sources() {
  fixture
  assert_contains "$(wt __complete commands)" "create"
  assert_eq "$(wt __complete projects)" "me"
  assert_eq "$(wt __complete repos)" "app"
  assert_contains "$(wt __complete kinds app)" "fix"
  assert_contains "$(wt __complete kinds app)" "feature"
  assert_eq "$(wt __complete tickets app fix | tr '\n' ' ')" "T1 T2 "
  assert_contains "$(wt __complete branches app)" "main"
  assert_exit 2 wt __complete bogus
}

test_completion_file_parses() {
  assert_exit 0 zsh -n "$WT_TEST_ROOT/shell/completions/_workytree"
}

run_tests
```

- [ ] **Step 2: 실패 확인** — `zsh tests/complete.test.zsh` → not implemented.

- [ ] **Step 3: lib/cmd/complete.zsh 작성**

```zsh
# Candidate sources for shell completion. One candidate per line; never fails loudly.
cmd___complete() {
  local what="${1:-}"; (( $# )) && shift
  case "$what" in
    commands) print -l init create remove prune list repos path cd project repo config help ;;
    projects) print -l -- "${WT_PROJECTS[@]}" ;;
    repos)    (( WT_CONFIG_EXISTS )) && all_repos "$WT_PROJECT_OPT" | cut -f1 ;;
    kinds)
      local r parent
      if [[ -n "${1:-}" ]] && r="$(resolve_repo "$1" 2>/dev/null)"; then
        parent="$(worktree_parent "${r%%$'\t'*}" "$1")"
        [[ -d "$parent" ]] && find "$parent" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort
      fi
      config_kinds | tr ' ' '\n' ;;
    tickets)
      local r parent
      [[ -n "${1:-}" && -n "${2:-}" ]] || return 0
      r="$(resolve_repo "$1" 2>/dev/null)" || return 0
      parent="$(worktree_parent "${r%%$'\t'*}" "$1" "$2")"
      [[ -d "$parent" ]] && find "$parent" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort ;;
    branches)
      local r
      [[ -n "${1:-}" ]] || return 0
      r="$(resolve_repo "$1" 2>/dev/null)" || return 0
      git -C "${r#*$'\t'}" branch --all --format='%(refname:short)' 2>/dev/null | sed 's#^remotes/##' | awk '!seen[$0]++' ;;
    *) usage_error "usage: workytree __complete commands|projects|repos|kinds <repo>|tickets <repo> <kind>|branches <repo>" ;;
  esac
}
```

`kinds`는 기존 worktree 디렉터리 이름 + 설정 `kinds`를 합쳐 출력한다(중복은 completion이 흡수).

- [ ] **Step 4: shell/completions/_workytree 작성**

```zsh
#compdef workytree wt

_workytree_src() { workytree __complete "$@" 2>/dev/null; }

_workytree() {
  local -a cmds
  cmds=( ${(f)"$(_workytree_src commands)"} )
  local curcontext="$curcontext" state line
  typeset -A opt_args
  _arguments -C \
    '--project[limit to a project]:project:->projects' \
    '(-y --yes)'{-y,--yes}'[skip confirmations]' \
    '--no-color[disable colors]' \
    '1:command:->cmd' '*::arg:->args' && return
  case "$state" in
    projects) _values project ${(f)"$(_workytree_src projects)"}; return ;;
    cmd) _describe -t commands 'workytree command' cmds; return ;;
  esac
  local sub="${line[1]}"
  case "$sub" in
    create|remove|path|cd|list|prune)
      case $CURRENT in
        1) _values repo ${(f)"$(_workytree_src repos)"} ;;
        2) [[ $sub == list || $sub == prune ]] || _values kind ${(f)"$(_workytree_src kinds "${line[2]}")"} ;;
        3) [[ $sub == list || $sub == prune ]] || _values ticket ${(f)"$(_workytree_src tickets "${line[2]}" "${line[3]}")"} ;;
        4) [[ $sub == create ]] && _values base ${(f)"$(_workytree_src branches "${line[2]}")"} ;;
      esac
      [[ $sub == remove ]] && _values -w flag --force --branch -b --branch-force -B ;;
    project) (( CURRENT == 1 )) && _values sub list add remove default || _values project ${(f)"$(_workytree_src projects)"} ;;
    repo)    (( CURRENT == 1 )) && _values sub list add remove || _files -/ ;;
    config)  (( CURRENT == 1 )) && _values sub path get set edit ;;
  esac
}
_workytree "$@"
```

`shell/workytree.zsh`의 `_workytree_register_completion`이 이 파일을 `fpath`에 넣는다. `_arguments`의 `*::arg:->args`는 서브커맨드 뒤 인자를 `line`에 모으므로 `CURRENT`는 서브커맨드 기준 1부터 센다.

- [ ] **Step 5: 테스트 통과 확인** — `zsh tests/run.zsh` → `0 failed`.

- [ ] **Step 6: 커밋**

```bash
git add lib/cmd/complete.zsh shell/completions/_workytree tests/complete.test.zsh
git commit -m "feat: zsh 자동완성 (__complete 후보 소스 기반)"
```

---

### Task 12: `install.sh` + README

**Files:**
- Create: `install.sh`, `README.md`
- Test: `tests/install.test.zsh`

**Interfaces:**
- Produces: `install.sh [--prefix DIR]` — `WORKYTREE_INSTALL_DIR`(기본 `~/.local/share/workytree`)에 clone/`git pull`(이미 저장소 안에서 실행되면 그 경로를 그대로 사용), `~/.local/bin/workytree` symlink, `~/.zshrc`에 source 줄 추가(백업 생성, 중복 방지).

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/install.test.zsh`:
```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

test_install_from_checkout_links_and_registers() {
  print '# existing' > "$HOME/.zshrc"
  WORKYTREE_INSTALL_DIR="$WT_TEST_ROOT" sh "$WT_TEST_ROOT/install.sh" >/dev/null 2>&1
  assert_eq "$?" 0
  assert_eq "$(readlink "$HOME/.local/bin/workytree")" "$WT_TEST_ROOT/bin/workytree"
  assert_eq "$(grep -c 'shell/workytree.zsh' "$HOME/.zshrc")" "1"
  assert_contains "$(cat "$HOME/.zshrc")" "# existing"
  assert_eq "$(ls "$HOME"/.zshrc.bak-* | wc -l | tr -d ' ')" "1"
  # idempotent
  WORKYTREE_INSTALL_DIR="$WT_TEST_ROOT" sh "$WT_TEST_ROOT/install.sh" >/dev/null 2>&1
  assert_eq "$(grep -c 'shell/workytree.zsh' "$HOME/.zshrc")" "1"
  assert_eq "$("$HOME/.local/bin/workytree" --version | cut -d' ' -f1)" "workytree"
}

run_tests
```

- [ ] **Step 2: 실패 확인** — `zsh tests/install.test.zsh` → `install.sh: not found`.

- [ ] **Step 3: install.sh 작성**

```sh
#!/bin/sh
# workytree installer. Usage: curl -fsSL <raw-url>/install.sh | sh   (or: sh install.sh from a checkout)
set -eu
REPO_URL="${WORKYTREE_REPO_URL:-https://github.com/Ahngbeom/workytree.git}"
INSTALL_DIR="${WORKYTREE_INSTALL_DIR:-$HOME/.local/share/workytree}"
BIN_DIR="${WORKYTREE_BIN_DIR:-$HOME/.local/bin}"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"

if [ -x "$INSTALL_DIR/bin/workytree" ]; then
  if [ -d "$INSTALL_DIR/.git" ] && [ -z "${WORKYTREE_INSTALL_DIR:-}" ]; then
    echo "workytree: updating $INSTALL_DIR"; git -C "$INSTALL_DIR" pull -q --ff-only || true
  fi
else
  echo "workytree: cloning into $INSTALL_DIR"
  git clone -q "$REPO_URL" "$INSTALL_DIR"
fi

mkdir -p "$BIN_DIR"
ln -sfn "$INSTALL_DIR/bin/workytree" "$BIN_DIR/workytree"
chmod +x "$INSTALL_DIR/bin/workytree"
echo "workytree: linked $BIN_DIR/workytree"

SOURCE_LINE="[ -s \"$INSTALL_DIR/shell/workytree.zsh\" ] && source \"$INSTALL_DIR/shell/workytree.zsh\""
touch "$ZSHRC"
if grep -Fq "shell/workytree.zsh" "$ZSHRC"; then
  echo "workytree: $ZSHRC already sources the shell integration"
else
  cp "$ZSHRC" "$ZSHRC.bak-$(date +%Y%m%d-%H%M%S)"
  printf '\n# workytree shell integration\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
  echo "workytree: added shell integration to $ZSHRC (backup created)"
fi

case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "workytree: note — add $BIN_DIR to your PATH" ;; esac
echo "workytree: done. Open a new shell, then run: workytree init"
```

- [ ] **Step 4: README.md 작성**

```markdown
# workytree

Git worktree manager with project-scoped roots and an interactive `create`.
`workytree` is the command; `wt` is installed as a short alias (opt out with `alias_wt = false`).

## Install (zsh)

    curl -fsSL https://raw.githubusercontent.com/Ahngbeom/workytree/main/install.sh | sh
    exec zsh
    workytree init

Requires zsh 5.8+ and git 2.31+. `fzf` is used for pickers when present.

## Concepts

A **project** pairs a `repo_root` (directory containing your clones, scanned recursively) with a
`worktree_root`. Worktrees are created at `<worktree_root>/<repo>/<kind>/<ticket>` on branch `<kind>/<ticket>`.

    ~/.config/workytree/config
    ─────────────────────────
    default_project = work
    alias_wt = true
    kinds = feature,fix,chore,hotfix,refactor

    [project work]
    repo_root     = ~/work/products
    worktree_root = ~/work/worktrees
    scan_depth    = 3

    [repo legacy]            # optional explicit registration
    path    = ~/elsewhere/legacy-api
    project = work

## Usage

    wt create                       # interactive: project → repo → kind → ticket → base → confirm
    wt create fix PROJ-1             # inside a repo: confirm repo, then create
    wt create server fix PROJ-1      # explicit repo
    wt create server fix PROJ-1 origin/develop -y
    wt cd server fix PROJ-1
    wt list [repo] · wt repos · wt path [repo [kind [ticket]]]
    wt remove server fix PROJ-1 [--force] [-b|-B]
    wt prune [repo]
    wt project add <name> <repo_root> <worktree_root>
    wt repo add <path> [--name n] [--project p]
    wt config get|set|edit|path

Repo names are resolved in order: registered `[repo]` → scan of every project's `repo_root` →
current directory. Ambiguous names across projects need `--project <name>`.

## Development

    zsh tests/run.zsh
```

- [ ] **Step 5: 테스트 통과 확인** — `chmod +x install.sh; zsh tests/run.zsh` → `0 failed`.

- [ ] **Step 6: 커밋**

```bash
git add install.sh README.md tests/install.test.zsh
git commit -m "feat: install.sh 와 README"
```

---

### Task 13: 실환경 스모크 (사용자 홈, 읽기 전용 검증)

**Files:** 없음(변경 없음). 새 설정 파일은 `WORKYTREE_CONFIG`로 임시 경로에 둔다.

- [ ] **Step 1: 기존 Acme 레이아웃이 그대로 인식되는지 확인**

```bash
export WORKYTREE_CONFIG=/private/tmp/claude-501/-Users-bahn-orca-workspaces-workytree-commercialization/2076afd8-4baa-4702-9a35-d8d0dde56c55/scratchpad/wt-config
bin/workytree project add acme ~/Acme/products ~/Acme/workspace/worktrees
bin/workytree config set project.acme.scan_depth 4
bin/workytree repos                       # acme-server, acme-front, … 가 나와야 함
bin/workytree list acme-server         # 기존 worktree 목록이 그대로 보여야 함
bin/workytree path acme-server fix proj-9316
```
Expected: `oldwt repos`/`oldwt list acme-server`와 동일한 repo/worktree 집합.

- [ ] **Step 2: 결과를 요약해 사용자에게 보고** (생성/삭제는 하지 않는다)

---

## Self-Review

- **Spec coverage**: §2 설정/해석 순서 → Task 2·3; §3 구조/설치/alias → Task 10·12; §4 명령 → Task 3~9, 11; §5 대화형 → Task 5; §6 오류 처리 → Task 3(중복/미존재), 6(remove 안전장치), 7(prune); §7 테스트 → 각 태스크 + `WORKYTREE_PROMPT_INPUT` 시뮬레이션(Task 5), 셸 통합(Task 10). §8 범위 밖 항목은 계획에 없음(의도). `--no-color`는 Task 1에서 소비.
- **Placeholder scan**: 없음. 테스트 기대값은 구현 출력과 일치하도록 계획 안에서 직접 조정했다.
- **Type consistency**: `resolve_repo`는 항상 `project<TAB>path`; 호출부는 `${r%%$'\t'*}`/`${r#*$'\t'}`로 분리. `infer_current_repo`는 3필드. `prompt_choose <msg> <allow_free> items…` 시그니처가 Task 5·9·create_pick_repo 전부 일치. `worktree_parent <project> <repo> [kind]`는 Task 3·7·11에서 동일하게 사용.

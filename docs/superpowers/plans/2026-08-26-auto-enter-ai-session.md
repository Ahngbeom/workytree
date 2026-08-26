# AI 세션 자동 실행 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `wt create` 직후 새 워크트리 안에서 AI 코딩 에이전트를 옵션으로 실행한다.

**Architecture:** `bin/workytree`는 "실행할 명령"을 결정해 셸 래퍼가 만든 runfile에 argv를 한 줄에 하나씩 기록하고, 셸 래퍼가 `cd` 후 그 배열을 그대로 실행한다. CLI는 여전히 아무것도 실행하지 않고 `cd`하지 않으며, stdout의 "마지막 줄 = 경로" 계약도 그대로다. 옵션 제안 목록은 새 `[agent <name>]` config 섹션에 담기고, 기존 `kinds` 패턴(제안 목록 + 자유 입력)을 그대로 재사용한다.

**Tech Stack:** zsh 5.9, git, 선택적 `fzf`. 외부 의존성 추가 없음.

**Spec:** `docs/superpowers/specs/2026-08-26-auto-enter-ai-session-design.md`

## Global Constraints

- **zsh만 사용.** 새 런타임/패키지 의존성을 추가하지 않는다. `fzf`는 있으면 쓰고 없으면 번호 메뉴로 떨어지는 기존 동작을 따른다.
- **`eval` 금지.** argv는 CLI가 `${(z)...}`로 토큰화해 한 줄에 하나씩 runfile에 쓰고, 래퍼는 배열로 읽어 `"${cmd[@]}"`로 실행한다. 결과적으로 **빈 문자열 인자는 지원하지 않는다.**
- **stdout 계약 불변.** `create`의 stdout 마지막 줄은 항상 워크트리 경로다. 이 기능은 stdout에 아무것도 추가하지 않는다. 사용자에게 보이는 메시지는 전부 `warn`(stderr) 또는 `/dev/tty`(프롬프트)로 나간다.
- **AI 세션 실패는 절대 `create`를 실패시키지 않는다.** 에이전트 부재, runfile 부재, 인터뷰 취소, 쓰기 실패 — 전부 exit 0이고 워크트리는 남는다.
- **`bin/workytree`는 `cd`하지 않고 대화형 프로그램을 실행하지 않는다.** 기존 불변식이다.
- **테스트 픽스처 관례:** repo 이름은 `app`/`acme`, 티켓은 `PROJ-1` 형식을 쓴다. 고용주 내부 식별자를 절대 넣지 않는다 (저장소가 공개되어 있다).
- **기본값은 off.** 이 기능이 꺼져 있을 때 `wt create`의 동작은 한 바이트도 달라지지 않아야 한다.
- 검증 명령: `zsh tests/run.zsh`

---

### Task 1: config 파서가 `[agent <name>]` 섹션을 인식한다

**Files:**
- Modify: `lib/config.zsh:24-25` (배열 선언), `:81` (`_config_load_fail` 리셋), `:87` (`config_load` 리셋), `:133-149` (섹션 파싱), `:156-160` (키 저장), `:171` (`_config_split_key`), `:182-186` (`config_get`), `:288` (`_config_write`), `:345` (`config_remove_section`)
- Test: `tests/config.test.zsh`

**Interfaces:**
- Consumes: 없음 (첫 태스크)
- Produces:
  - `WT_AGENTS` — `typeset -ga`, 정의된 agent 섹션 이름 배열
  - `WT_ACFG` — `typeset -gA`, 키는 `<agent>.<key>`, 값은 원문 문자열
  - `config_get agent.<name>.<key>` — 값 출력, 미설정 시 rc 1
  - `config_set agent.<name>.<key> <value>` — 섹션 내 제자리 기록

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/config.test.zsh` 끝에 추가:

```zsh
test_agent_section_parses_and_get_works() {
  write_config <<'EOF'
[project fd]
repo_root = ~/a
worktree_root = ~/b

[agent claude]
command = claude
ask = permission_mode,model
model = opus,sonnet
EOF
  assert_eq "$(wt config get agent.claude.command)" "claude"
  assert_eq "$(wt config get agent.claude.ask)" "permission_mode,model"
  assert_eq "$(wt config get agent.claude.model)" "opus,sonnet"
  assert_exit 1 wt config get agent.claude.nope
}

test_duplicate_agent_section_rejected() {
  write_config <<'EOF'
[agent claude]
command = claude

[agent claude]
command = other
EOF
  local out rc
  out="$(wt config get agent.claude.command 2>&1)"; rc=$?
  assert_eq "$rc" 3 "duplicate [agent] is a config-state failure"
  assert_contains "$out" "duplicate [agent claude]"
}

test_config_set_writes_agent_key_in_place() {
  write_config <<'EOF'
# keep me
[agent claude]
command = claude
EOF
  wt config set agent.claude.model opus >/dev/null
  assert_eq "$(wt config get agent.claude.model)" "opus"
  assert_eq "$(wt config get agent.claude.command)" "claude"
  assert_contains "$(<"$XDG_CONFIG_HOME/workytree/config")" "# keep me"
}

test_agent_section_does_not_leak_into_projects_or_repos() {
  write_config <<'EOF'
[project fd]
repo_root = ~/a
worktree_root = ~/b

[agent claude]
command = claude
EOF
  config_load
  assert_eq "${#WT_PROJECTS}" 1
  assert_eq "${#WT_REPOS}" 0
  assert_eq "${#WT_AGENTS}" 1
  assert_eq "${WT_AGENTS[1]}" "claude"
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `zsh tests/config.test.zsh`
Expected: FAIL — `config parse error at ...: [agent claude]`

- [ ] **Step 3: 배열 선언과 리셋 추가**

`lib/config.zsh:24-25`를 교체:

```zsh
typeset -gA WT_CFG WT_PCFG WT_RCFG WT_ACFG
typeset -ga WT_PROJECTS WT_REPOS WT_AGENTS
```

`_config_load_fail` 본문(`:81`)을 교체:

```zsh
  WT_CFG=() WT_PCFG=() WT_RCFG=() WT_ACFG=() WT_PROJECTS=() WT_REPOS=() WT_AGENTS=()
```

`config_load`의 리셋 줄(`:87`)을 같은 내용으로 교체:

```zsh
  WT_CFG=() WT_PCFG=() WT_RCFG=() WT_ACFG=() WT_PROJECTS=() WT_REPOS=() WT_AGENTS=()
```

- [ ] **Step 4: 섹션 파싱을 3-way로 확장**

`lib/config.zsh:133-149`의 블록 전체를 교체:

```zsh
    if [[ "$line" =~ '^[[:space:]]*\[[[:space:]]*(project|repo|agent)[[:space:]]+([^]]*)\][[:space:]]*$' ]]; then
      sect_type="$match[1]"
      sect_name="${${match[2]##[[:space:]]#}%%[[:space:]]#}"
      case "$sect_type" in
        project)
          if (( ${WT_PROJECTS[(Ie)$sect_name]} )); then
            _config_load_fail "duplicate [project $sect_name] at $WT_CONFIG_FILE:$lineno"; return 1
          fi
          WT_PROJECTS+=("$sect_name") ;;
        repo)
          if (( ${WT_REPOS[(Ie)$sect_name]} )); then
            _config_load_fail "duplicate [repo $sect_name] at $WT_CONFIG_FILE:$lineno"; return 1
          fi
          WT_REPOS+=("$sect_name") ;;
        agent)
          if (( ${WT_AGENTS[(Ie)$sect_name]} )); then
            _config_load_fail "duplicate [agent $sect_name] at $WT_CONFIG_FILE:$lineno"; return 1
          fi
          WT_AGENTS+=("$sect_name") ;;
      esac
      seen_keys=()
      continue
    fi
```

- [ ] **Step 5: 키 저장 분기 추가**

`lib/config.zsh:156-160`의 `case "$sect_type"` 블록에 한 줄 추가:

```zsh
      case "$sect_type" in
        "")      WT_CFG[$key]="$value" ;;
        project) WT_PCFG[$sect_name.$key]="$value" ;;
        repo)    WT_RCFG[$sect_name.$key]="$value" ;;
        agent)   WT_ACFG[$sect_name.$key]="$value" ;;
      esac
```

- [ ] **Step 6: 점표기 키와 config_get 확장**

`lib/config.zsh:171`의 패턴을 교체:

```zsh
    project.*.*|repo.*.*|agent.*.*)
```

같은 함수의 usage 메시지(`:173`)도 갱신:

```zsh
    *.*) usage_error "invalid config key: $key (use <key>, project.<name>.<key>, repo.<name>.<key>, agent.<name>.<key>)" ;;
```

`config_get`의 `case "$REPLY_TYPE"`(`:182-186`)에 한 줄 추가:

```zsh
    agent)   (( ${+WT_ACFG[$REPLY_NAME.$REPLY_KEY]} )) || return 1; v="${WT_ACFG[$REPLY_NAME.$REPLY_KEY]}" ;;
```

- [ ] **Step 7: 쓰기 경로의 섹션 정규식 2곳 확장**

`lib/config.zsh:288`(`_config_write` 안)과 `:345`(`config_remove_section` 안)의 정규식을 각각 교체 — 두 줄 모두 동일한 문자열이다:

```zsh
      if [[ "$line" =~ '^[[:space:]]*\[[[:space:]]*(project|repo|agent)[[:space:]]+([^]]*)\][[:space:]]*$' ]]; then
```

파일 상단 주석(`:1`)의 형식 설명도 갱신한다:

```zsh
# Single point of config-file I/O. Format: INI-like; "[project <name>]" / "[repo <name>]" /
# "[agent <name>]" sections, "key = value" lines, "#" comments (whole line, or after
```

- [ ] **Step 8: 테스트 통과 확인**

Run: `zsh tests/config.test.zsh`
Expected: PASS (신규 4건 포함, 기존 케이스 전부 유지)

- [ ] **Step 9: 전체 스위트 회귀 확인**

Run: `zsh tests/run.zsh`
Expected: 전부 PASS

- [ ] **Step 10: 커밋**

```bash
git add lib/config.zsh tests/config.test.zsh
git commit -m "feat(config): parse [agent <name>] sections

Third section type alongside project/repo, reached through the same
duplicate-detection and same write path -- config_set agent.x.y patches in
place and preserves comments like every other key.

Verified before the change that [agent x] was a hard parse error (exit 3),
so no existing config can contain one."
```

---

### Task 2: 에이전트 프로필 해석과 PATH 탐색

**Files:**
- Create: `lib/agent.zsh`
- Test: `tests/agent.test.zsh` (신규)

**Interfaces:**
- Consumes: Task 1의 `WT_AGENTS`, `WT_ACFG`; 기존 `WT_CFG`, `WT_PCFG`, `warn`
- Produces:
  - `ai_setting <project> <key>` — project 값 → 전역 값 순으로 출력, 없으면 rc 1
  - `ai_session_mode <project>` — `off|ask|always` 중 하나를 항상 출력
  - `ai_profile_get <agent> <key>` — 프로필 값 출력, 없으면 rc 1
  - `ai_agent_command <agent>` — 실행 명령 문자열 출력 (기본값 = agent 이름)
  - `ai_have_command <name>` — PATH에 있으면 rc 0
  - `ai_resolve_agent <project>` — 에이전트 이름 출력, 없으면 rc 1
  - `WT_AI_BUILTIN` (`typeset -gA`), `WT_AI_PROBE_ORDER` (`typeset -ga`)

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/agent.test.zsh` 생성:

```zsh
#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

# Resolution/detection are pure functions over already-loaded config state, so they are
# reached the same way tests/config.test.zsh reaches library internals: source the modules
# and call them in-process. No CLI round-trip needed until Task 4.
source "$WT_TEST_ROOT/lib/ui.zsh"
source "$WT_TEST_ROOT/lib/config.zsh"
source "$WT_TEST_ROOT/lib/prompt.zsh"
source "$WT_TEST_ROOT/lib/agent.zsh"

# fake_agent <name...>: put executables on PATH so detection sees them. They are never run
# by bin/workytree -- it only ever WRITES the command into the runfile.
fake_agent() {
  mkdir -p "$HOME/fakebin"
  local n
  for n in "$@"; do
    cat > "$HOME/fakebin/$n" <<EOF
#!/bin/sh
echo "AGENT-RAN name=$n pwd=\$PWD args=\$*"
EOF
    chmod +x "$HOME/fakebin/$n"
  done
  export PATH="$HOME/fakebin:$PATH"
}

test_setting_prefers_project_over_global() {
  write_config <<'EOF'
ai_agent = claude

[project work]
repo_root = ~/a
worktree_root = ~/b
ai_agent = codex
EOF
  config_load
  assert_eq "$(ai_setting work ai_agent)" "codex"
  assert_eq "$(ai_setting other ai_agent)" "claude"
  assert_exit 1 ai_setting work nope
}

test_session_mode_defaults_off_and_rejects_garbage() {
  write_config <<'EOF'
[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  assert_eq "$(ai_session_mode w)" "off"

  write_config <<'EOF'
ai_session = always

[project w]
repo_root = ~/a
worktree_root = ~/b
ai_session = ask
EOF
  config_load
  assert_eq "$(ai_session_mode w)" "ask"
  assert_eq "$(ai_session_mode other)" "always"

  write_config <<'EOF'
ai_session = maybe

[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  assert_eq "$(ai_session_mode w 2>/dev/null)" "off" "invalid value falls back to off"
  assert_contains "$(ai_session_mode w 2>&1 >/dev/null)" "invalid ai_session"
}

test_builtin_claude_profile_available_without_config() {
  write_config <<'EOF'
[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  assert_eq "$(ai_profile_get claude ask)" "permission_mode,model,teammate_mode"
  assert_eq "$(ai_profile_get claude teammate_mode)" "auto,tmux,iterm2,in-process"
  assert_eq "$(ai_agent_command claude)" "claude"
  assert_eq "$(ai_agent_command aider)" "aider" "no profile -> command is the name itself"
  assert_exit 1 ai_profile_get aider ask
}

test_user_agent_section_replaces_builtin_wholesale() {
  write_config <<'EOF'
[agent claude]
ask = model
model = opus
EOF
  config_load
  assert_eq "$(ai_profile_get claude ask)" "model"
  assert_exit 1 ai_profile_get claude teammate_mode "user section replaces, never merges"
  assert_eq "$(ai_agent_command claude)" "claude" "command absent -> section name"
}

test_resolve_agent_prefers_explicit_then_probe_order() {
  write_config <<'EOF'
[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  assert_exit 1 ai_resolve_agent w "nothing on PATH -> no agent"

  fake_agent codex aider
  assert_eq "$(ai_resolve_agent w)" "codex" "probe order puts codex before aider"

  write_config <<'EOF'
ai_agent = aider

[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  assert_eq "$(ai_resolve_agent w)" "aider" "explicit ai_agent wins over probe order"
}

run_tests
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `zsh tests/agent.test.zsh`
Expected: FAIL — `no such file or directory: .../lib/agent.zsh`

- [ ] **Step 3: `lib/agent.zsh` 작성**

```zsh
# AI 세션 실행 결정. 이 파일은 결정만 내린다 -- 에이전트를 실행하지도, cd하지도 않는다.
# 실행은 셸 래퍼(shell/workytree.zsh)가 runfile을 읽어서 한다. bin/workytree가 순수
# CLI라는 불변식은 이 기능에서도 깨지지 않는다.

# 내장 프로필. `claude`에 대해서만 둔다 -- 다른 CLI의 플래그를 검증 없이 여기 박는 것은
# 노후화 부채이고, 프로필 없는 에이전트는 인터뷰 없이 그냥 실행되므로 여전히 동작한다.
#
# `teammate_mode`는 `claude --help`에 표시되지 않는 비공개 플래그다. 허용값은 실측으로
# 확인했다(`claude --teammate-mode __bogus__`가 "Allowed choices are auto, tmux, iterm2,
# in-process"를 출력). 예고 없이 사라질 수 있으므로 목록을 여기 두되, 사용자가
# [agent claude] 섹션 한 블록으로 통째로 덮어쓸 수 있게 한다.
typeset -gA WT_AI_BUILTIN
WT_AI_BUILTIN=(
  'claude.command'         'claude'
  'claude.ask'             'permission_mode,model,teammate_mode'
  'claude.permission_mode' 'plan,acceptEdits,auto,bypassPermissions,dontAsk,manual'
  'claude.model'           'opus,sonnet,fable'
  'claude.effort'          'low,medium,high,xhigh,max'
  'claude.teammate_mode'   'auto,tmux,iterm2,in-process'
)

# ai_agent 미설정 시 PATH에서 이 순서로 첫 히트를 쓴다.
typeset -ga WT_AI_PROBE_ORDER
WT_AI_PROBE_ORDER=(claude codex gemini cursor-agent aider)

# ai_setting <project> <key>: project 값 -> 전역 값. 둘 다 없으면 rc 1.
# repo 단위는 두지 않는다 -- [repo] 섹션은 명시 등록한 저장소에만 존재하므로, 스캔으로
# 발견된 저장소는 그 계층을 쓸 수 없어 규칙이 비대칭해진다.
ai_setting() {
  local project="$1" key="$2"
  if [[ -n "$project" ]] && (( ${+WT_PCFG[$project.$key]} )); then
    print -r -- "${WT_PCFG[$project.$key]}"; return 0
  fi
  (( ${+WT_CFG[$key]} )) || return 1
  print -r -- "${WT_CFG[$key]}"
}

# ai_session_mode <project>: 항상 off|ask|always 중 하나를 출력한다. 알 수 없는 값은
# stderr 경고 후 off -- 오타 하나가 create 자체를 못 쓰게 만들면 안 된다(spec §8).
ai_session_mode() {
  local v
  v="$(ai_setting "$1" ai_session)" || v=off
  [[ -z "$v" ]] && v=off
  case "$v" in
    off|ask|always) print -r -- "$v" ;;
    *) warn "ignoring invalid ai_session value: $v (expected off|ask|always)"; print -r -- off ;;
  esac
}

# ai_profile_get <agent> <key>: 프로필 값. 없으면 rc 1.
# 사용자가 [agent <name>]을 정의하면 내장 프로필을 통째로 대체한다 -- 키 단위 병합이
# 아니다. 병합은 "내장 목록에서 항목 하나를 빼고 싶다"를 표현할 수 없다.
ai_profile_get() {
  local name="$1" key="$2"
  if (( ${WT_AGENTS[(Ie)$name]} )); then
    (( ${+WT_ACFG[$name.$key]} )) || return 1
    print -r -- "${WT_ACFG[$name.$key]}"; return 0
  fi
  (( ${+WT_AI_BUILTIN[$name.$key]} )) || return 1
  print -r -- "${WT_AI_BUILTIN[$name.$key]}"
}

# ai_agent_command <agent>: 실행 명령 문자열. `command` 키가 없으면 에이전트 이름 자체.
ai_agent_command() { ai_profile_get "$1" command || print -r -- "$1"; }

# ai_have_command <name>: PATH에 실행 가능한 파일이 있는가.
# `whence -p`는 PATH를 직접 훑어 별칭/함수/빌트인을 건너뛰고 외부 명령만 찾는다. zsh의
# `${+commands[$1]}` 조회도 실측 결과 동일하게 동작한다 -- PATH 앞에 디렉터리를 새로
# 붙이면 rehash 없이도 즉시 반영된다(이 대목은 bash의 `hash -r` 요구와 다른 zsh 고유
# 동작이며, 과거 이 주석은 반대로 적혀 있었다). 두 표현이 여기서는 동등하므로, "PATH에서
# 이 이름을 찾는다"는 의도를 이름 그대로 드러내는 `whence -p`를 쓴다.
ai_have_command() { whence -p -- "$1" >/dev/null 2>&1; }

# ai_resolve_agent <project>: 쓸 에이전트 이름. 없으면 rc 1.
# 명시된 ai_agent는 PATH 확인 없이 그대로 반환한다 -- 존재하지 않는다는 진단은
# 호출자(ai_maybe_offer)가 "사용자가 직접 지정했는데 없다"는 문맥과 함께 내야 한다.
ai_resolve_agent() {
  local project="$1" explicit cand
  if explicit="$(ai_setting "$project" ai_agent)" && [[ -n "$explicit" ]]; then
    print -r -- "$explicit"; return 0
  fi
  for cand in "${WT_AI_PROBE_ORDER[@]}"; do
    ai_have_command "$cand" && { print -r -- "$cand"; return 0; }
  done
  return 1
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `zsh tests/agent.test.zsh`
Expected: PASS (6건)

- [ ] **Step 5: 전체 스위트 회귀 확인**

`bin/workytree`는 `lib/*.zsh`를 glob으로 source하므로 `lib/agent.zsh`는 자동으로 로드된다. 이 파일은 source 시점에 다른 모듈의 함수를 호출하지 않으므로(배열 대입만 한다) 알파벳 순서상 먼저 로드되어도 안전하다.

Run: `zsh tests/run.zsh`
Expected: 전부 PASS

- [ ] **Step 6: 커밋**

```bash
git add lib/agent.zsh tests/agent.test.zsh
git commit -m "feat(agent): resolve agent profile and detect one on PATH

Built-in profile for claude only. Other CLIs' flags are not baked in -- an
agent with no profile still works, it just runs without an interview.

A user [agent <name>] section replaces the built-in wholesale rather than
merging: a key-by-key merge cannot express 'drop one entry from the built-in
list', so a user wanting a shorter ask list could never get one.

teammate_mode's values were confirmed by probing an invalid value; the flag
is hidden from claude --help and may change, which is why the list lives in
overridable config rather than in this file alone."
```

---

### Task 3: 옵션 인터뷰와 argv 조립

**Files:**
- Modify: `lib/agent.zsh` (`ai_build_argv` 추가)
- Test: `tests/agent.test.zsh`

**Interfaces:**
- Consumes: Task 2의 `ai_agent_command`, `ai_profile_get`; 기존 `prompt_available`, `prompt_confirm`, `prompt_choose`
- Produces:
  - `ai_build_argv <agent> <mode>` — argv를 **한 줄에 하나씩 stdout으로** 출력. 사용자가 거절하거나 취소하면 rc != 0. **반드시 명령 치환 안에서 호출해야 한다** (아래 Step 3 주석 참조).

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/agent.test.zsh`의 `run_tests` 앞에 추가:

```zsh
# answers <line...>: WORKYTREE_PROMPT_INPUT용 응답 파일을 만들고 경로를 REPLY_ANSWERS에 둔다.
typeset -g REPLY_ANSWERS=""
answers() { REPLY_ANSWERS="$TMP_ROOT/answers"; print -l -- "$@" > "$REPLY_ANSWERS"; }

test_build_argv_maps_underscores_to_flags_and_omits_skips() {
  write_config <<'EOF'
[project w]
repo_root = ~/a
worktree_root = ~/b
EOF
  config_load
  # ask = permission_mode,model,teammate_mode
  #   permission_mode: 1=(skip) 2=plan 3=acceptEdits 4=auto 5=bypassPermissions 6=dontAsk 7=manual
  #   model:           1=(skip) 2=opus 3=sonnet 4=fable
  #   teammate_mode:   1=(skip) 2=auto 3=tmux 4=iterm2 5=in-process
  answers 2 1 3
  local out
  out="$(WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" ai_build_argv claude always 2>/dev/null)"
  assert_eq "$out" $'claude\n--permission-mode\nplan\n--teammate-mode\ntmux'
}

test_build_argv_accepts_free_text_outside_the_list() {
  write_config <<'EOF'
[agent claude]
ask = model
model = opus,sonnet
EOF
  config_load
  answers "claude-fable-5"
  local out
  out="$(WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" ai_build_argv claude always 2>/dev/null)"
  assert_eq "$out" $'claude\n--model\nclaude-fable-5'
}

test_build_argv_skips_ask_entries_with_no_value_list() {
  write_config <<'EOF'
[agent claude]
ask = model,nonexistent_option
model = opus
EOF
  config_load
  answers 2
  local out
  out="$(WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" ai_build_argv claude always 2>/dev/null)"
  assert_eq "$out" $'claude\n--model\nopus' "an ask entry with no key is skipped, not an error"
}

test_build_argv_without_prompts_returns_bare_command() {
  write_config <<'EOF'
[agent claude]
command = claude --bare
ask = model
model = opus
EOF
  config_load
  local out
  out="$(WT_YES=1 ai_build_argv claude always 2>/dev/null)"
  assert_eq "$out" $'claude\n--bare' "-y skips the interview; command string is tokenized"
}

test_build_argv_ask_mode_declined_returns_nonzero() {
  write_config <<'EOF'
[agent claude]
ask = model
model = opus
EOF
  config_load
  answers n
  local out rc
  out="$(WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" ai_build_argv claude ask 2>/dev/null)"; rc=$?
  assert_eq "$rc" 1 "declining the confirm is a refusal, not a crash"
  assert_eq "$out" ""
}

test_build_argv_cancel_kills_only_the_subshell() {
  write_config <<'EOF'
[agent claude]
ask = model
model = opus
EOF
  config_load
  answers q
  local out rc
  out="$(WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" ai_build_argv claude always 2>/dev/null)"; rc=$?
  assert_eq "$rc" 130 "q propagates prompt.zsh's exit 130 out of the substitution"
  assert_eq "$out" "" "and the caller is still alive to see it"
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `zsh tests/agent.test.zsh`
Expected: FAIL — `command not found: ai_build_argv`

- [ ] **Step 3: `ai_build_argv` 구현**

`lib/agent.zsh` 끝에 추가:

```zsh
# ai_build_argv <agent> <mode>: 실행할 argv를 한 줄에 하나씩 stdout으로 출력한다.
# 사용자가 ask 모드에서 거절하면 rc 1.
#
# 호출자는 반드시 명령 치환으로 감싸야 한다: `out="$(ai_build_argv "$name" "$mode")"`.
# lib/prompt.zsh의 취소 경로는 `exit 130`을 직접 호출하는데(:21, :22, :57), 이 인터뷰는
# 워크트리가 이미 만들어진 *뒤에* 돌기 때문에 그 exit가 프로세스 전체에 닿으면 CLI가
# 경로를 찍어놓고도 130으로 끝나고, 셸 래퍼는 `(( exit_code == 0 ))` 검사에서 걸려 cd를
# 건너뛴다 -- 즉 워크트리는 생겼는데 사용자는 거기 못 가는 최악의 결과가 된다. 명령
# 치환은 서브셸이므로 그 exit가 서브셸에서 멈추고 부모는 rc만 받는다(실측 확인). 이
# 배치 하나로 prompt.zsh를 한 줄도 고치지 않고 spec §5.2("취소해도 워크트리는 남고
# exit 0")를 만족한다.
ai_build_argv() {
  local name="$1" mode="$2" cmd ask values opt
  local -a argv opts
  cmd="$(ai_agent_command "$name")"
  argv=( ${(z)cmd} )

  if prompt_available; then
    if [[ "$mode" == ask ]]; then
      prompt_confirm "open a $name session here?" y || return 1
    fi
    if ask="$(ai_profile_get "$name" ask)" && [[ -n "$ask" ]]; then
      opts=( ${(s:,:)ask} )
      for opt in "${opts[@]}"; do
        # spec §3.1: ask가 섹션에 없는 키를 가리키면 오류가 아니라 건너뛰기. 내장
        # 프로필을 부분적으로 흉내 낸 설정이 config 전체를 못 쓰게 만드는 쪽이 나쁘다.
        values="$(ai_profile_get "$name" "$opt")" || continue
        [[ -n "$values" ]] || continue
        # allow_free=1 -- 목록에 없는 값도 타이핑할 수 있다. 이것이 남의 CLI 플래그
        # 목록이 낡았을 때를 조용한 실패가 아닌 가벼운 불편으로 낮추는 장치다.
        prompt_choose "${opt//_/-}" 1 "(skip)" ${(s:,:)values}
        [[ "$REPLY" == "(skip)" ]] && continue
        argv+=( "--${opt//_/-}" "$REPLY" )
      done
    fi
  fi

  print -l -- "${argv[@]}"
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `zsh tests/agent.test.zsh`
Expected: PASS (12건)

- [ ] **Step 5: 커밋**

```bash
git add lib/agent.zsh tests/agent.test.zsh
git commit -m "feat(agent): interview the user and assemble the agent argv

Reuses prompt_choose with allow_free=1 -- the same shape kinds already has:
a suggestion list you can type past. That is what keeps a stale flag list a
mild inconvenience instead of a silent failure.

Callers MUST wrap this in a command substitution. prompt.zsh cancels with a
bare 'exit 130', and this interview runs AFTER the worktree exists -- letting
that reach the process would print the path and then exit 130, which makes the
shell wrapper skip the cd. The worktree would exist with no way to land in it.
A substitution confines the exit to a subshell; measured, not assumed."
```

---

### Task 4: 실행 게이트와 runfile 기록, `--ai` 플래그

**Files:**
- Modify: `lib/agent.zsh` (`ai_maybe_offer` 추가), `lib/cmd/create.zsh:96-99` (플래그 파싱), `:149` (호출 추가), `bin/workytree:24` (usage 한 줄)
- Test: `tests/agent.test.zsh`

**Interfaces:**
- Consumes: Task 2·3의 `ai_session_mode`, `ai_resolve_agent`, `ai_agent_command`, `ai_have_command`, `ai_build_argv`, `ai_setting`
- Produces:
  - `ai_maybe_offer <project> <forced:0|1>` — 게이트를 통과하면 `$WORKYTREE_AI_RUNFILE`에 argv를 기록한다. 항상 rc 0.
  - `workytree create ... --ai` — 이번 실행에 한해 세션을 켜는 플래그

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/agent.test.zsh`의 `run_tests` 앞에 추가:

```zsh
# 여기서부터는 CLI 왕복 테스트다. fixture는 tests/create.test.zsh와 같은 모양을 쓴다.
cli_fixture() {
  make_repo "$HOME/src/app"
  write_config <<'EOF'
[project me]
repo_root = ~/src
worktree_root = ~/wts
EOF
}

test_default_off_writes_nothing_to_the_runfile() {
  cli_fixture; fake_agent claude
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main -y >/dev/null 2>&1
  assert_dir "$HOME/wts/app/fix/PROJ-1"
  assert_eq "$(<"$rf")" "" "ai_session defaults to off"
}

test_ai_flag_writes_runfile_and_create_still_prints_path_last() {
  cli_fixture; fake_agent claude
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  local out
  out="$(WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main --ai -y 2>/dev/null)"
  assert_eq "${out##*$'\n'}" "$HOME/wts/app/fix/PROJ-1" "stdout contract is untouched"
  assert_eq "$(<"$rf")" "claude"
}

test_ai_session_always_needs_no_flag() {
  cli_fixture; fake_agent claude
  wt config set ai_session always >/dev/null
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main -y >/dev/null 2>&1
  assert_eq "$(<"$rf")" "claude"
}

test_project_ai_session_overrides_global() {
  cli_fixture
  fake_agent claude
  write_config <<'EOF'
ai_session = always

[project me]
repo_root = ~/src
worktree_root = ~/wts
ai_session = off
EOF
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main -y >/dev/null 2>&1
  assert_eq "$(<"$rf")" "" "project 'off' beats global 'always'"
}

test_interview_answers_reach_the_runfile() {
  cli_fixture; fake_agent claude
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  # Create? 확인 -> permission-mode(2=plan) -> model(1=skip) -> teammate-mode(3=tmux)
  answers y 2 1 3
  WORKYTREE_AI_RUNFILE="$rf" WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" \
    wt create app fix PROJ-1 main --ai >/dev/null 2>&1
  assert_eq "$(<"$rf")" $'claude\n--permission-mode\nplan\n--teammate-mode\ntmux'
}

test_cancelled_interview_keeps_the_worktree_and_exits_zero() {
  cli_fixture; fake_agent claude
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  answers y q
  local rc
  WORKYTREE_AI_RUNFILE="$rf" WORKYTREE_PROMPT_INPUT="$REPLY_ANSWERS" \
    wt create app fix PROJ-1 main --ai >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 0 "cancelling the interview never fails create"
  assert_dir "$HOME/wts/app/fix/PROJ-1"
  assert_eq "$(<"$rf")" ""
}

test_missing_runfile_warns_but_create_succeeds() {
  cli_fixture; fake_agent claude
  local out rc
  out="$(wt create app fix PROJ-1 main --ai -y 2>&1)"; rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "shell integration"
  assert_dir "$HOME/wts/app/fix/PROJ-1"
}

test_explicit_agent_missing_from_path_warns() {
  cli_fixture
  wt config set ai_agent nosuchagent >/dev/null
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  local out rc
  out="$(WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main --ai -y 2>&1)"; rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "nosuchagent"
  assert_eq "$(<"$rf")" ""
}

test_no_agent_anywhere_is_silent() {
  cli_fixture
  local rf="$TMP_ROOT/runfile"; : > "$rf"
  local out
  out="$(WORKYTREE_AI_RUNFILE="$rf" wt create app fix PROJ-1 main --ai -y 2>&1)"
  assert_eq "$(<"$rf")" ""
  assert_eq "${out#*shell integration}" "$out" "no runfile warning -- the runfile was given"
  assert_dir "$HOME/wts/app/fix/PROJ-1"
}

test_dashdash_lets_ai_be_a_literal_positional() {
  cli_fixture
  local out rc
  out="$(wt create -- --ai fix PROJ-1 main -y 2>&1)"; rc=$?
  assert_eq "$rc" 1 "'--ai' after -- is a repo name, and there is no such repo"
  assert_contains "$out" "--ai"
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `zsh tests/agent.test.zsh`
Expected: FAIL — `--ai`가 repo 이름으로 해석되어 "unknown repo" 류의 오류

- [ ] **Step 3: `ai_maybe_offer` 구현**

`lib/agent.zsh` 끝에 추가:

```zsh
# ai_maybe_offer <project> <forced:0|1>: create가 성공한 뒤 호출된다. 게이트를 모두
# 통과하면 $WORKYTREE_AI_RUNFILE에 argv를 기록한다.
#
# 이 함수는 항상 rc 0이다. AI 세션을 못 띄운 것은 create의 실패가 아니다 -- 워크트리는
# 만들어졌고, 그것이 이 명령의 계약이다(spec §8). 진단은 전부 warn(stderr)으로 나가므로
# "stdout 마지막 줄 = 경로"도 그대로다.
ai_maybe_offer() {
  local project="$1"
  local -i forced=$2
  local mode name cmd first out

  if (( forced )); then mode=always; else mode="$(ai_session_mode "$project")"; fi
  [[ "$mode" == off ]] && return 0

  if [[ -z "${WORKYTREE_AI_RUNFILE:-}" ]]; then
    warn "ai session skipped: shell integration required"
    warn "source shell/workytree.zsh from your shell config and use 'wt'/'workytree'"
    return 0
  fi

  name="$(ai_resolve_agent "$project")" || return 0
  cmd="$(ai_agent_command "$name")"
  first="${${(z)cmd}[1]}"
  if ! ai_have_command "$first"; then
    # 자동 탐색은 PATH에 있는 것만 고르므로 여기 오면 사용자가 직접 지정한 경우다.
    # 지정한 이름이 없다는 사실은 조용히 넘기면 안 된다.
    warn "ai session skipped: '$first' not found on PATH"
    return 0
  fi

  out="$(ai_build_argv "$name" "$mode")" || return 0
  [[ -n "$out" ]] || return 0
  print -r -- "$out" > "$WORKYTREE_AI_RUNFILE" \
    || warn "ai session skipped: could not write $WORKYTREE_AI_RUNFILE"
  return 0
}
```

- [ ] **Step 4: `cmd_create`에 `--ai` 배선**

`lib/cmd/create.zsh:96-99`를 교체:

```zsh
cmd_create() {
  require_config
  local -a pos
  local -i want_ai=0 saw_dashdash=0
  local arg
  # `--ai`만 걸러내고 나머지 dash-prefixed 토큰은 지금까지처럼 positional로 남긴다.
  # remove가 하듯 모든 `-*`를 usage error로 만들면 오늘 통과하던 입력이 깨진다 --
  # 이 태스크의 범위가 아니다. `--`는 리터럴 `--ai`를 repo 이름으로 넘기는 탈출구다.
  for arg in "$@"; do
    if (( saw_dashdash )); then pos+=("$arg"); continue; fi
    case "$arg" in
      --)   saw_dashdash=1 ;;
      --ai) want_ai=1 ;;
      *)    pos+=("$arg") ;;
    esac
  done
  (( ${#pos} <= 4 )) || usage_error "usage: workytree create [repo] [kind] [ticket] [base] [--ai]"
```

`lib/cmd/create.zsh:149`의 마지막 줄 뒤에 한 줄 추가:

```zsh
  create_do "$project" "$repo" "$repo_path" "$kind" "$ticket" "$base_ref" "$base_label"
  ai_maybe_offer "$project" "$want_ai"
}
```

- [ ] **Step 5: usage 문자열 갱신**

`bin/workytree:24`를 교체:

```
  workytree create [repo] [kind] [ticket] [base] [--ai]   create (or reuse) a worktree; asks for missing args
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `zsh tests/agent.test.zsh`
Expected: PASS (22건)

- [ ] **Step 7: 전체 스위트 회귀 확인**

Run: `zsh tests/run.zsh`
Expected: 전부 PASS. 특히 `tests/create.test.zsh`가 그대로 통과해야 한다 — 기본값 off이므로 기존 동작은 변하지 않는다.

- [ ] **Step 8: 커밋**

```bash
git add lib/agent.zsh lib/cmd/create.zsh bin/workytree tests/agent.test.zsh
git commit -m "feat(create): --ai writes the agent command to the wrapper's runfile

Three gates: opted in (--ai or ai_session != off), a runfile was provided,
and the agent exists on PATH. Every failure past that point is a warn on
stderr and exit 0 -- the worktree was created, which is what create promises.

--ai is filtered in cmd_create rather than parse_global_opts: it only means
anything for create, and a global option would be silently ignored by every
other subcommand. Only --ai is extracted; other dash-prefixed tokens stay
positional exactly as they are today, so nothing that parses now stops
parsing. -- escapes a literal --ai."
```

---

### Task 5: 셸 래퍼가 runfile을 만들고, cd 후 실행한다

**Files:**
- Modify: `shell/workytree.zsh:55-73`
- Test: `tests/shell.test.zsh`

**Interfaces:**
- Consumes: Task 4가 기록하는 `$WORKYTREE_AI_RUNFILE`의 줄 단위 argv
- Produces: 없음 (최종 소비자)

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/shell.test.zsh`의 `run_tests` 앞에 추가:

```zsh
# fake_claude: PATH에 놓일 가짜 에이전트. 실행되면 자기 cwd와 인자를 찍는다 -- 래퍼가
# cd를 *먼저* 하고 나서 실행하는지를 이걸로 확인한다.
fake_claude() {
  mkdir -p "$HOME/fakebin"
  cat > "$HOME/fakebin/claude" <<'EOF'
#!/bin/sh
echo "AGENT-RAN pwd=$PWD args=$*"
EOF
  chmod +x "$HOME/fakebin/claude"
  export PATH="$HOME/fakebin:$PATH"
}

test_create_ai_runs_the_agent_inside_the_new_worktree() {
  fixture; fake_claude
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main --ai -y')"
  assert_contains "$out" "AGENT-RAN"
  assert_contains "$out" "pwd=$HOME/wts/app/fix/PROJ-1"
}

test_create_without_ai_runs_nothing() {
  fixture; fake_claude
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main -y')"
  assert_eq "${out#*AGENT-RAN}" "$out" "no --ai, no agent"
  assert_contains "$out" "cd: $HOME/wts/app/fix/PROJ-1"
}

test_agent_exit_code_does_not_fail_create() {
  fixture
  mkdir -p "$HOME/fakebin"
  print -r -- '#!/bin/sh' > "$HOME/fakebin/claude"
  print -r -- 'exit 3'   >> "$HOME/fakebin/claude"
  chmod +x "$HOME/fakebin/claude"
  export PATH="$HOME/fakebin:$PATH"
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main --ai -y; echo "rc=$?"')"
  assert_contains "$out" "rc=0" "the worktree was created; the agent's own exit is not create's"
}

test_runfile_is_removed_after_the_run() {
  fixture; fake_claude
  local out
  out="$(zsh_i 'wt create app fix PROJ-1 main --ai -y; ls "${TMPDIR:-/tmp}" | grep -c "^workytree-ai\." || true')"
  assert_contains "$out" "AGENT-RAN"
  assert_eq "${out##*$'\n'}" "0" "no runfile left behind"
}
```

`fixture`는 이 파일에 이미 있으므로 그대로 쓴다.

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `zsh tests/shell.test.zsh`
Expected: FAIL — `AGENT-RAN`이 출력에 없음 (래퍼가 runfile을 만들지 않으므로 CLI가 "shell integration required"를 경고하고 끝난다)

- [ ] **Step 3: 래퍼 구현**

`shell/workytree.zsh:55-73`(`local output exit_code target head`부터 `return 0`까지)을 교체:

```zsh
  # AI 세션 실행 채널. bin/workytree는 실행하지 않고 "무엇을 실행할지"만 이 파일에
  # 적는다 -- CLI가 순수하게 남는 대신, 대화형 에이전트에 필요한 TTY는 여기서 온다.
  # 파일은 이 함수가 만들고 이 함수가 지운다: CLI가 직접 mktemp하면 누가 언제 지우는지가
  # 불분명해지고, CLI가 죽었을 때 파일이 남는다.
  #
  # zsh에서 함수 안에 건 EXIT 트랩은 그 함수에 국소적이며 함수가 반환할 때 실행된다 --
  # 에이전트는 함수 안에서 돌므로 트랩은 그 뒤에 터진다. rm -f는 멱등하므로 아래에서
  # 이미 지운 뒤 한 번 더 불려도 무해하다.
  local runfile=""
  if [[ "$sub" == create ]]; then
    runfile="$(command mktemp "${TMPDIR:-/tmp}/workytree-ai.XXXXXX" 2>/dev/null)" || runfile=""
    [[ -n "$runfile" ]] && trap 'command rm -f -- "$runfile"' EXIT
  fi

  local output exit_code target head
  if [[ -n "$runfile" ]]; then
    output="$(WORKYTREE_AI_RUNFILE="$runfile" "$WORKYTREE_BIN" "${call_args[@]}")"
  else
    output="$("$WORKYTREE_BIN" "${call_args[@]}")"
  fi
  exit_code=$?
  # Split "everything except the last line" from "the last line" without a `path`/`fpath`
  # local (R16: `path` is tied to $PATH in zsh, even as a local). Works for empty output, a
  # single-line output (target only), and multi-line output (info lines + target).
  if [[ -n "$output" ]]; then
    target="${output##*$'\n'}"
    head="${output%"$target"}"; head="${head%$'\n'}"
    [[ -n "$head" ]] && print -r -- "$head"
  fi
  (( exit_code == 0 )) || return $exit_code
  if [[ -o interactive && -n "$target" && -d "$target" ]]; then
    builtin cd -- "$target" || return 1
    print -P "%F{70}cd:%f $target"
    # 실행은 cd 뒤다 -- 에이전트는 새 워크트리를 cwd로 봐야 한다. exec가 아니라 일반
    # 호출이므로 에이전트를 끝내면 사용자는 그 워크트리 안의 셸로 돌아온다.
    if [[ -n "$runfile" && -s "$runfile" ]]; then
      local -a ai_cmd; ai_cmd=( ${(f)"$(<"$runfile")"} )
      command rm -f -- "$runfile"
      (( ${#ai_cmd} )) && "${ai_cmd[@]}"
    fi
  elif [[ -n "$target" ]]; then
    print -r -- "$target"
  fi
  # 에이전트가 0이 아닌 코드로 끝나도 create는 성공이다 -- 워크트리는 만들어졌고
  # 그 사실은 이미 사용자에게 보고됐다.
  return 0
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `zsh tests/shell.test.zsh`
Expected: PASS (신규 4건 포함)

- [ ] **Step 5: 전체 스위트 회귀 확인**

Run: `zsh tests/run.zsh`
Expected: 전부 PASS

- [ ] **Step 6: 커밋**

```bash
git add shell/workytree.zsh tests/shell.test.zsh
git commit -m "feat(shell): run the agent from the runfile after the cd

The wrapper owns the runfile's whole lifetime -- mktemp before the call, a
function-local EXIT trap to remove it, and an explicit rm right before the
agent runs so a long session does not sit on a stale temp file.

Read as an array with \${(f)}, invoked as \"\${ai_cmd[@]}\" -- no eval, so a
config value can never widen into arbitrary execution. The agent's own exit
status is discarded: the worktree was created and reported, and that is what
create promises."
```

---

### Task 6: 완성 후보와 문서

**Files:**
- Modify: `shell/completions/_workytree:52-62`, `README.md`
- Test: 수동 확인 + 기존 `tests/complete.test.zsh` 회귀

**Interfaces:**
- Consumes: Task 4의 `--ai` 플래그
- Produces: 없음

- [ ] **Step 1: 완성 후보에 `--ai` 추가**

`shell/completions/_workytree:61` 바로 앞(`remove`의 `_values` 줄 앞)에 추가:

```zsh
      # create's only flag; like remove's, it may appear anywhere among the positionals
      # (lib/cmd/create.zsh), so offer it at every position rather than gating on $idx.
      [[ $sub == create ]] && _values -w flag --ai
```

- [ ] **Step 2: 완성 회귀 확인**

Run: `zsh tests/complete.test.zsh`
Expected: PASS — 이 파일은 `workytree __complete`의 출력만 검사하고 `_workytree`를 실행하지 않으므로 영향받지 않아야 한다.

- [ ] **Step 3: README에 사용법 절 추가**

`README.md`의 `## Usage` 절 끝(`wt config get|set|edit|path` 줄 다음)에 한 줄 추가:

```
    wt create --ai fix PROJ-1       # create, cd, then open an AI session there
```

`## Usage` 절과 `## Exit codes` 절 사이에 새 절을 추가:

```markdown
## AI sessions (opt-in)

`create` can hand the new worktree straight to an AI coding agent. It is **off by
default**; nothing about `wt create` changes until you turn it on.

    wt create --ai fix PROJ-1        # this run only
    wt config set ai_session always  # every run

The agent runs in your current shell, in the new worktree, in the foreground — quit it
and you are back in that worktree. This only works through the shell integration (`wt`,
or `workytree` as the function this repo installs); calling `bin/workytree` directly
prints a warning and still creates the worktree.

| key | scope | meaning |
| --- | --- | --- |
| `ai_session` | global, `[project]` | `off` (default), `ask` (confirm first), `always` |
| `ai_agent` | global, `[project]` | which agent to run; unset means auto-detect |

Auto-detection takes the first of `claude`, `codex`, `gemini`, `cursor-agent`, `aider`
found on your `PATH`. `--ai` overrides `ai_session` for one run and skips the `ask`
confirmation.

Before launching, workytree offers the agent's useful options as menus — the same
suggestion-list-plus-free-text shape `kinds` already uses, so you can always type a value
that isn't listed. What gets asked comes from an `[agent <name>]` section:

    [agent claude]
    command         = claude
    ask             = permission_mode,model,teammate_mode
    permission_mode = plan,acceptEdits,auto,bypassPermissions,dontAsk,manual
    model           = opus,sonnet,fable
    effort          = low,medium,high,xhigh,max
    teammate_mode   = auto,tmux,iterm2,in-process

`ask` chooses which options are asked about and in what order — `effort` above is defined
but not asked until you add it to `ask`. A key's `_` becomes `-` and gains a `--` prefix,
so `permission_mode` builds `--permission-mode <value>`. Choosing `(skip)` omits the flag.

workytree ships exactly the block above as the built-in profile for `claude`. Writing your
own `[agent claude]` section **replaces it wholesale** rather than merging, so you can
shorten a list, not just extend it. An agent with no profile (`ai_agent = aider`) simply
runs with no interview.

`-y`/`--yes` skips the interview entirely and runs the bare `command`. Cancelling the
interview (`q`) leaves the worktree in place and exits 0 — a session that did not open is
never a failed `create`.
```

- [ ] **Step 4: README의 "Known limitations"에 두 항목 추가**

`## Known limitations` 목록 끝에 추가:

```markdown
- **`teammate_mode` rides an undocumented `claude` flag.** `--teammate-mode` does not
  appear in `claude --help`; its allowed values (`auto`, `tmux`, `iterm2`, `in-process`)
  were found by probing an invalid one. It can change or disappear in any `claude`
  release, and when it does the assembled command fails at launch. That is survivable
  precisely because the list lives in config: drop `teammate_mode` from `ask` in your own
  `[agent claude]` section and you are unblocked without waiting for a workytree release.
- **AI session arguments cannot be empty strings.** The command is handed to the shell
  wrapper one argv element per line and read back with `${(f)}`, which is what lets
  workytree avoid `eval` on a config-supplied string entirely. The cost is that
  `--flag ""` cannot be expressed in an `[agent]` profile.
```

- [ ] **Step 5: 문서와 실제 동작이 일치하는지 손으로 확인**

```bash
zsh tests/run.zsh
grep -n 'ai_session\|ai_agent\|\[agent' README.md | head -20
```
Expected: 스위트 전부 PASS, README에 두 키와 `[agent]` 섹션이 모두 언급됨

- [ ] **Step 6: 커밋**

```bash
git add shell/completions/_workytree README.md
git commit -m "docs: document opt-in AI sessions and their two sharp edges

Both limitations are consequences of deliberate choices, so they are written
next to each other: teammate_mode rides a flag hidden from claude --help (and
the config-overridable list is the mitigation, not an oversight), and empty
string arguments are unsupported because avoiding eval on config-supplied
strings was worth more than expressing --flag \"\"."
```

---

## 자체 리뷰

**Spec 커버리지**

| Spec 절 | 구현 태스크 |
| --- | --- |
| §2 runfile 채널 | Task 4 (기록), Task 5 (소비) |
| §2.2 소유권 / runfile 부재 시 경고 | Task 4 Step 3, Task 5 Step 3 |
| §2.3 argv 전달, eval 배제 | Task 3 Step 3, Task 5 Step 3 |
| §2.4 exec 아닌 일반 호출 | Task 5 Step 3 |
| §3.1 `[agent]` 섹션, `ask` 규칙 3종 | Task 1 (파싱), Task 2 (`command` 기본값), Task 3 (미존재 키 건너뛰기) |
| §3.2 `_`→`-` 매핑 | Task 3 Step 3 |
| §3.3 내장 프로필, 통째 교체 | Task 2 Step 3 |
| §3.4 `teammate_mode` 위험 문서화 | Task 2 Step 3 주석, Task 6 Step 4 |
| §4.1 project → 전역 우선순위 | Task 2 (`ai_setting`) |
| §4.2 PATH 탐색 순서 | Task 2 (`ai_resolve_agent`) |
| §4.3 프로필 미매칭 시 인터뷰 없음 | Task 2 (`ai_agent_command` 기본값), Task 3 (`ask` 부재 시 건너뜀) |
| §4.4 3중 게이트, `--ai`가 `off`를 덮음 | Task 4 Step 3–4 |
| §5 인터뷰, `(skip)`, 자유 입력 | Task 3 |
| §5.1 비대화형 경로 | Task 3 (`prompt_available`) |
| §5.2 취소 시 exit 0 | Task 3 (명령 치환 배치), Task 4 (테스트) |
| §6 변경 대상 6개 파일 | Task 1·2·3·4·5·6 전부 |
| §7 테스트 4종 | Task 1(config), 2·3·4(agent), 5(shell) |
| §8 오류 표 5행 | Task 4 Step 1의 테스트 5건이 각 행에 1:1 대응 |

**플레이스홀더 스캔:** 없음. 모든 코드 단계에 실제 코드가 들어 있다.

**타입/이름 일관성:** `ai_setting`, `ai_session_mode`, `ai_profile_get`, `ai_agent_command`,
`ai_have_command`, `ai_resolve_agent`, `ai_build_argv`, `ai_maybe_offer` — Task 2에서 정의된
이름이 Task 3·4에서 그대로 쓰인다. 배열 이름 `WT_ACFG`/`WT_AGENTS`는 Task 1에서 정의되고
Task 2의 `ai_profile_get`에서만 읽힌다. `WORKYTREE_AI_RUNFILE`은 Task 4가 읽고 Task 5가 쓴다.

**범위:** 단일 기능, 6개 태스크, 각 태스크가 독립적으로 테스트 가능하고 자체 커밋으로 끝난다.

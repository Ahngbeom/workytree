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
# AI session launch decisions. This file only decides -- it never execs an agent or cd's
# anywhere. Execution happens in the shell wrapper (shell/workytree.zsh), which reads the
# runfile. bin/workytree's invariant of being a pure CLI stays intact for this feature too.

# Built-in profile. Kept for `claude` only -- baking another CLI's flags in here without
# verifying them is aging debt, and an agent with no profile still works: it just runs
# without an interview.
#
# `teammate_mode` is an undocumented flag not shown in `claude --help`. Its allowed values
# were confirmed by probing (`claude --teammate-mode __bogus__` prints "Allowed choices are
# auto, tmux, iterm2, in-process"). It could disappear without notice, so the list lives
# here, but a user can override it wholesale with one [agent claude] section.
typeset -gA WT_AI_BUILTIN
WT_AI_BUILTIN=(
  'claude.command'         'claude'
  'claude.ask'             'permission_mode,model,teammate_mode'
  'claude.permission_mode' 'plan,acceptEdits,auto,bypassPermissions,dontAsk,manual'
  'claude.model'           'opus,sonnet,fable'
  'claude.effort'          'low,medium,high,xhigh,max'
  'claude.teammate_mode'   'auto,tmux,iterm2,in-process'
)

# When ai_agent is unset, use the first PATH hit in this order.
typeset -ga WT_AI_PROBE_ORDER
WT_AI_PROBE_ORDER=(claude codex gemini cursor-agent aider)

# ai_setting <project> <key>: project value -> global value. rc 1 if neither is set.
# No repo-level tier: a [repo] section only exists for explicitly registered repos, so a
# repo discovered by scanning could never use that tier -- the rule would apply
# asymmetrically.
ai_setting() {
  local project="$1" key="$2"
  if [[ -n "$project" ]] && (( ${+WT_PCFG[$project.$key]} )); then
    print -r -- "${WT_PCFG[$project.$key]}"; return 0
  fi
  (( ${+WT_CFG[$key]} )) || return 1
  print -r -- "${WT_CFG[$key]}"
}

# ai_session_mode <project>: always prints one of off|ask|always. An unrecognized value
# warns on stderr and falls back to off -- a single typo must never make create itself
# unusable (spec §8).
ai_session_mode() {
  local v
  v="$(ai_setting "$1" ai_session)" || v=off
  [[ -z "$v" ]] && v=off
  case "$v" in
    off|ask|always) print -r -- "$v" ;;
    *) warn "ignoring invalid ai_session value: $v (expected off|ask|always)"; print -r -- off ;;
  esac
}

# ai_profile_get <agent> <key>: profile value. rc 1 if unset.
# When a user defines [agent <name>], it replaces the built-in profile wholesale -- not a
# key-by-key merge. A merge cannot express "I want to drop one entry from the built-in
# list."
ai_profile_get() {
  local name="$1" key="$2"
  if (( ${WT_AGENTS[(Ie)$name]} )); then
    (( ${+WT_ACFG[$name.$key]} )) || return 1
    print -r -- "${WT_ACFG[$name.$key]}"; return 0
  fi
  (( ${+WT_AI_BUILTIN[$name.$key]} )) || return 1
  print -r -- "${WT_AI_BUILTIN[$name.$key]}"
}

# ai_agent_command <agent>: the command string to run. The agent's own name if there is no
# `command` key.
ai_agent_command() { ai_profile_get "$1" command || print -r -- "$1"; }

# ai_have_command <name>: is there an executable file on PATH?
# `whence -p` scans PATH directly, skipping aliases/functions/builtins and finding only
# external commands. zsh's `${+commands[$1]}` lookup was measured to behave identically --
# prepending a new directory to PATH takes effect immediately, with no rehash needed (this
# is zsh-specific behavior that differs from bash's `hash -r` requirement, and this comment
# used to say the opposite). The two spellings are equivalent here, so `whence -p` is used
# because its name states the intent directly: "look this name up on PATH."
ai_have_command() { whence -p -- "$1" >/dev/null 2>&1; }

# ai_resolve_agent <project>: the agent name to use. rc 1 if none.
# An explicitly set ai_agent is returned as-is, with no PATH check -- the diagnostic for "it
# doesn't exist" belongs to the caller (ai_maybe_offer), which can give it with the context
# that the user named it explicitly.
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
# ai_build_argv <agent> <mode>: prints the argv to run, one word per line, on stdout.
# rc 1 if the user declines in ask mode.
#
# The caller MUST wrap this in a command substitution: `out="$(ai_build_argv "$name" "$mode")"`.
# lib/prompt.zsh's cancel path calls `exit 130` directly (:21, :22, :57), and this interview
# runs *after* the worktree already exists -- if that exit reached the whole process, the
# CLI would print the path and still end with 130, and the shell wrapper's
# `(( exit_code == 0 ))` check would then skip the cd -- the worst possible outcome: the
# worktree exists but the user can't get to it. A command substitution runs in a subshell,
# so that exit stops in the subshell and the parent only sees the rc (measured directly).
# This one arrangement satisfies spec §5.2 ("cancelling still leaves the worktree and exits
# 0") without touching a single line of prompt.zsh.
#
# R16: never name a local `argv` -- zsh binds `argv` to the function's own positional
# parameters, so `argv=(...)` silently rebinds $1/$2/$@ for the rest of the call. Harmless
# here only because name/mode are captured into scalars before the rebind and nothing after
# reads a positional; renamed to out_argv so the next edit doesn't inherit the landmine.
ai_build_argv() {
  local name="$1" mode="$2" cmd ask values opt
  local -a out_argv opts
  cmd="$(ai_agent_command "$name")"
  out_argv=( ${(z)cmd} )

  if prompt_available; then
    if [[ "$mode" == ask ]]; then
      prompt_confirm "open a $name session here?" y || return 1
    fi
    if ask="$(ai_profile_get "$name" ask)" && [[ -n "$ask" ]]; then
      opts=( ${(s:,:)ask} )
      for opt in "${opts[@]}"; do
        # spec §3.1: when ask names a key the section doesn't have, skip it rather than
        # error. It's worse for a config that partially mimics the built-in profile to make
        # the whole config unusable.
        values="$(ai_profile_get "$name" "$opt")" || continue
        [[ -n "$values" ]] || continue
        # allow_free=1 -- a value outside the list can still be typed. This is what turns a
        # stale upstream CLI flag list into a mild inconvenience instead of a silent
        # failure.
        prompt_choose "${opt//_/-}" 1 "(skip)" ${(s:,:)values}
        [[ "$REPLY" == "(skip)" ]] && continue
        out_argv+=( "--${opt//_/-}" "$REPLY" )
      done
    fi
  fi

  print -l -- "${out_argv[@]}"
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
# ai_maybe_offer <project> <forced:0|1>: called after create has already succeeded. If
# every gate passes, writes argv to $WORKYTREE_AI_RUNFILE.
#
# This function is always rc 0. Failing to launch an AI session is not a failure of create --
# the worktree was created, and that's this command's contract (spec §8). Every diagnostic
# goes out via warn (stderr), so "last stdout line = the path" still holds.
ai_maybe_offer() {
  local project="$1"
  local -i forced=$2
  local mode name cmd first out
  local -a cmd_words

  if (( forced )); then mode=always; else mode="$(ai_session_mode "$project")"; fi
  [[ "$mode" == off ]] && return 0

  if [[ -z "${WORKYTREE_AI_RUNFILE:-}" ]]; then
    warn "ai session skipped: shell integration required"
    warn "source shell/workytree.zsh from your shell config and use 'wt'/'workytree'"
    return 0
  fi

  name="$(ai_resolve_agent "$project")" || return 0
  cmd="$(ai_agent_command "$name")"
  # NOT `${${(z)cmd}[1]}`: when (z)-splitting yields exactly one word, that nested-subscript
  # form silently indexes the ORIGINAL scalar by character instead of the split array by
  # element (verified: cmd="nosuchagent" -> "n", not "nosuchagent"; cmd="claude --bare" ->
  # "claude" is fine because two words happen to dodge the collapse). Single-word commands are
  # the common case, so this would misdetect nearly every real agent. Building the array first
  # and indexing that avoids the collapse entirely.
  cmd_words=( ${(z)cmd} )
  first="${cmd_words[1]}"
  if ! ai_have_command "$first"; then
    # Auto-detection only ever picks something already on PATH, so reaching here means the
    # user named this agent explicitly. That the name they gave doesn't exist must not pass
    # by silently.
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
  # Only `--ai` is filtered out; every other dash-prefixed token still stays positional, as
  # it always has. Making every `-*` a usage error the way remove does would break input
  # that passes today -- that's out of scope for this task. `--` is the escape hatch for
  # passing a literal `--ai` as a repo name.
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
  # AI-session launch channel. bin/workytree never runs the agent itself -- it only writes
  # "what to run" into this file. That keeps the CLI pure, while the TTY an interactive
  # agent needs comes from here instead. The file is created by this function and removed
  # by this function: if the CLI did its own mktemp, who removes it and when would become
  # unclear, and the file would be left behind whenever the CLI process died.
  #
  # An EXIT trap set inside a zsh function is local to that function and fires when the
  # function returns -- the agent runs inside this function, so the trap fires after it.
  # rm -f is idempotent, so the explicit removal below and the trap firing again afterward
  # (already gone) is harmless.
  #
  # The trap body must bind $runfile's VALUE now, not defer its expansion to when the trap
  # fires: `trap 'cmd "$runfile"' EXIT` (single quotes) leaves the variable reference intact
  # in the trap string, and zsh only expands it at fire time -- by then this function has
  # already returned and its `local runfile` has gone out of scope, so the trap runs with an
  # EMPTY value and deletes nothing. `${(q)runfile}` interpolates the value immediately, into
  # a shell-quoted literal safe to re-parse later, so the trap still targets the right path
  # even after `runfile` no longer exists. Plain double quotes (`trap "cmd $runfile" EXIT`)
  # would expand at the right time but NOT re-quote -- `$TMPDIR` is user-controlled (mktemp
  # is rooted at it), so a space or quote character in that path would either split into
  # extra words or break the trap string outright; `${(q)}` is what makes the substitution
  # safe against that.
  local runfile=""
  if [[ "$sub" == create ]]; then
    runfile="$(command mktemp "${TMPDIR:-/tmp}/workytree-ai.XXXXXX" 2>/dev/null)" || runfile=""
    [[ -n "$runfile" ]] && trap "command rm -f -- ${(q)runfile}" EXIT
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
    # Run after the cd -- the agent must see the new worktree as its cwd. A plain call, not
    # exec, so quitting the agent returns the user to a shell inside that worktree.
    if [[ -n "$runfile" && -s "$runfile" ]]; then
      local -a ai_cmd; ai_cmd=( ${(f)"$(<"$runfile")"} )
      command rm -f -- "$runfile"
      (( ${#ai_cmd} )) && "${ai_cmd[@]}"
    fi
  elif [[ -n "$target" ]]; then
    print -r -- "$target"
  fi
  # create still succeeds even if the agent exits nonzero -- the worktree was created, and
  # that fact was already reported to the user.
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

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
        # spec §3.1: ask가 섹션에 없는 키를 가리키면 오류가 아니라 건너뛰기. 내장
        # 프로필을 부분적으로 흉내 낸 설정이 config 전체를 못 쓰게 만드는 쪽이 나쁘다.
        values="$(ai_profile_get "$name" "$opt")" || continue
        [[ -n "$values" ]] || continue
        # allow_free=1 -- 목록에 없는 값도 타이핑할 수 있다. 이것이 남의 CLI 플래그
        # 목록이 낡았을 때를 조용한 실패가 아닌 가벼운 불편으로 낮추는 장치다.
        prompt_choose "${opt//_/-}" 1 "(skip)" ${(s:,:)values}
        [[ "$REPLY" == "(skip)" ]] && continue
        out_argv+=( "--${opt//_/-}" "$REPLY" )
      done
    fi
  fi

  print -l -- "${out_argv[@]}"
}

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

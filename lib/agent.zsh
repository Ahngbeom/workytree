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

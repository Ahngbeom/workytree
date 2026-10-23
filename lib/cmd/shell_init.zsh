# cmd___shell-init: one line, "ai=0|1 alias=0|1 config=ok|error", parsed by shell/workytree.zsh.
cmd___shell-init() {
  local ai=0 alias_on=1 cfg=ok
  [[ -n "$WT_CONFIG_LOAD_ERROR" ]] && cfg=error
  ai_configured_anywhere && ai=1
  [[ "${${WT_CFG[alias_wt]:-}:l}" == (false|0|no) ]] && alias_on=0
  print -r -- "ai=$ai alias=$alias_on config=$cfg"
}

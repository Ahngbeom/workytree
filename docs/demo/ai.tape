Source docs/demo/common.tape

Hide
Type "source docs/demo/setup.zsh --demo-bare --ai && PROMPT='%F{39}%~%f %F{244}❯%f ' && clear" Enter
Wait+Line@20s /^~.*❯/
Sleep 1.5s
Show

Type "wt create web feature CHAT-5" Sleep 400ms Enter
Wait+Screen /base branch/
Sleep 1s Enter
Wait+Screen /Create\?/
Sleep 1s Enter
Wait+Screen /open a codex session here\?/
Sleep 1.2s Enter
Wait+Screen /demo agent/
Sleep 4s

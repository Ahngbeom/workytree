Source docs/demo/common.tape

Hide
Type "source docs/demo/setup.zsh && PROMPT='%F{39}%~%f %F{244}❯%f ' && clear" Enter
Wait+Line@20s /^~.*❯/
Sleep 1.5s
Show

Type "wt status --offline" Sleep 400ms Enter
Sleep 3s
Sleep 2s Down Sleep 1.5s Down Sleep 1.5s Down Sleep 1.5s
Ctrl+S Sleep 2.5s
Ctrl+S Sleep 1.5s
Type "SEARCH" Sleep 2s Enter
Wait+Line@20s /^~.*❯/
Sleep 800ms Type "pwd" Sleep 400ms Enter
Sleep 3s

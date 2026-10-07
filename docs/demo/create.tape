Source docs/demo/common.tape

Hide
Type "source docs/demo/setup.zsh --demo-bare && PROMPT='%F{39}%~%f %F{244}❯%f ' && clear" Enter
Wait+Line@20s /^~.*❯/
Sleep 1.5s
Show

Type "cd ~/work/products/api" Sleep 300ms Enter
Sleep 800ms
Type "wt create fix PAY-42" Sleep 400ms Enter
Wait+Screen /use this repo\?/
Sleep 1.2s Enter
Wait+Screen /base branch/
Sleep 1.2s Enter
Wait+Screen /Create\?/
Sleep 1s Right Sleep 800ms Left Sleep 800ms Enter
Wait+Screen /result: created/
Sleep 1s Type "git branch --show-current" Sleep 400ms Enter
Wait+Screen /(?m)^fix\/PAY-42$/
Sleep 3s

Source docs/demo/common.tape

Hide
Type "source docs/demo/setup.zsh && PROMPT='%F{39}%~%f %F{244}❯%f ' && clear" Enter
Wait+Line@20s /^~.*❯/
Sleep 1.5s
Show

Type "cd ~/work/worktrees/api/fix/LOGIN-3" Sleep 300ms Enter
Sleep 800ms
Type "wt remove --to ~/work/products/api" Sleep 400ms Enter
Wait+Screen /remove the worktree you are in/
Sleep 1.2s Enter
Wait+Screen /delete local branch/
Sleep 1s Right Sleep 800ms Left Sleep 800ms Enter
Wait+Screen /Proceed\?/
Sleep 1.2s Enter
Wait+Screen /removed/
Sleep 3s

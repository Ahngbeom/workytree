# Source from the repository root: builds a throwaway sandbox and points this shell at it.
# The recordings in docs/demo/*.tape run inside it; nothing outside the sandbox is touched.
WT_DEMO_REPO="${WT_DEMO_REPO:-$PWD}"
WT_DEMO_ROOT="${WORKYTREE_DEMO_ROOT:-${TMPDIR:-/tmp}/workytree-demo}"
[[ -f "$WT_DEMO_REPO/bin/workytree" ]] || { print -u2 "run from the workytree checkout"; return 1; }
[[ "${WT_DEMO_ROOT:t}" == workytree-demo* ]] || { print -u2 "WORKYTREE_DEMO_ROOT must be named workytree-demo*: $WT_DEMO_ROOT"; return 1; }
rm -rf "$WT_DEMO_ROOT"
mkdir -p "$WT_DEMO_ROOT/home"
WT_DEMO_ROOT="${WT_DEMO_ROOT:A}"   # /tmp is a symlink on macOS; the prompt's ~ needs the real path


export HOME="$WT_DEMO_ROOT/home" XDG_CONFIG_HOME="$WT_DEMO_ROOT/home/.config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.com
export GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.com
unset WORKYTREE_CONFIG WORKYTREE_ALIAS

# A stand-in agent so `create --ai` has something to launch.
mkdir -p "$HOME/bin"
cat > "$HOME/bin/codex" <<'AGENT'
#!/bin/sh
printf '\n  codex (demo agent) started in %s\n\n' "$PWD"
AGENT
chmod +x "$HOME/bin/codex"
export PATH="$HOME/bin:$WT_DEMO_REPO/bin:$PATH"


() {
  local r
  for r in api web mobile; do
    git init -q --bare "$WT_DEMO_ROOT/remotes/$r.git"
    git -C "$HOME" init -q -b main "work/products/$r"
    print "# $r" > "$HOME/work/products/$r/README.md"
    git -C "$HOME/work/products/$r" add -A
    GIT_COMMITTER_DATE=2026-09-01T10:00:00 git -C "$HOME/work/products/$r" commit -qm init
    git -C "$HOME/work/products/$r" remote add origin "$WT_DEMO_ROOT/remotes/$r.git"
    git -C "$HOME/work/products/$r" push -q -u origin main
    git -C "$HOME/work/products/$r" remote set-head origin main
  done
}

mkdir -p "$XDG_CONFIG_HOME/workytree"
cat > "$XDG_CONFIG_HOME/workytree/config" <<CFG
default_project = work
alias_wt = true
kinds = feature,fix,chore,hotfix,refactor

[project work]
repo_root     = ~/work/products
worktree_root = ~/work/worktrees
CFG
# --ai: offer an AI session after create, through an agent with no option menus.
(( ${@[(Ie)--ai]} )) && { workytree config set ai_session ask && workytree config set ai_agent codex; } >/dev/null 2>&1

source "$WT_DEMO_REPO/shell/workytree.zsh"

# Worktrees in every state `wt status` distinguishes; --demo-bare starts without them.
if (( ! ${@[(Ie)--demo-bare]} )); then
  () {
    local wts="$HOME/work/worktrees" gd
    workytree create -y api feature PAY-12 >/dev/null 2>&1
    print "draft" > "$wts/api/feature/PAY-12/payment.ts"          # uncommitted → !

    workytree create -y api fix LOGIN-3 >/dev/null 2>&1           # nothing of its own → ✓

    workytree create -y web feature SEARCH-7 >/dev/null 2>&1
    git -C "$wts/web/feature/SEARCH-7" commit -q --allow-empty -m "search box"   # unpushed → !

    workytree create -y web chore deps >/dev/null 2>&1
    GIT_COMMITTER_DATE=2026-07-01T09:00:00 git -C "$wts/web/chore/deps" commit -q --allow-empty -m "bump deps"
    git -C "$wts/web/chore/deps" push -q -u origin chore/deps 2>/dev/null
    gd="$(git -C "$wts/web/chore/deps" rev-parse --absolute-git-dir)"
    touch -t 202607010900 "$gd/index" "$gd/HEAD" "$gd/logs/HEAD"  # untouched for months → ●

    git -C "$HOME/work/products/mobile" branch hotfix/CRASH-9     # branch without a worktree
    mkdir -p "$wts/mobile/fix/OLD-1" && print leftover > "$wts/mobile/fix/OLD-1/notes.txt"  # orphan dir
  }
fi

cd "$HOME"

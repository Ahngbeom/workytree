# workytree

[![ci](https://github.com/Ahngbeom/workytree/actions/workflows/ci.yml/badge.svg)](https://github.com/Ahngbeom/workytree/actions/workflows/ci.yml)

Git worktree manager with project-scoped roots and an interactive `create`.
`workytree` is the command; `wt` is installed as a short alias for interactive shell use
(opt out with `alias_wt = false`, or `WORKYTREE_ALIAS=0` for the current shell).

## Install (zsh)

Clone this repository yourself, then run the installer from the checkout:

    git clone <this-repository-url> workytree
    cd workytree
    sh install.sh
    exec zsh
    workytree init

`sh install.sh`, run from inside a checkout (as above), detects that it's running from one
(`bin/workytree`, `lib/`, and `shell/` sitting next to `install.sh`) and installs straight from
it — no network access and no `WORKYTREE_INSTALL_DIR` needed. It symlinks
`~/.local/bin/workytree` onto the checkout and adds one `source` line to `~/.zshrc` — backing
the file up first (`.zshrc.bak-<timestamp>`) and never adding the line twice. It is safe to
re-run.

The one-liner below clones the repository and runs the installer directly — the same clone
path this repository's `install-smoke` CI job exercises against every commit:

    curl -fsSL https://raw.githubusercontent.com/Ahngbeom/workytree/main/install.sh | sh
    exec zsh
    workytree init

Once published, running it against an already-installed copy at the default location
(`~/.local/share/workytree`) updates that copy in place (`git pull --ff-only`) rather than
re-cloning.

Tested with zsh 5.9 and git 2.50.1. `fzf` is used for the `create` picker screens when it is
on your `PATH`; without it, `create` falls back to a numbered-menu prompt.

## Concepts

A **project** pairs a `repo_root` (a directory scanned recursively, up to `scan_depth` levels
deep, default 3) with a `worktree_root`. Worktrees are created at
`<worktree_root>/<repo>/<kind>/<ticket>` on branch `<kind>/<ticket>`.

**`scan_depth` has a hard, silent cutoff.** A repo nested deeper than `scan_depth` levels
below `repo_root` is not found by `repos`, `path`, or `create` — and nothing tells you it was
skipped; it simply never appears, the same as if it didn't exist. The default (3) means a repo
at `repo_root/a/b/c` is found but one at `repo_root/a/b/c/d` is not. If your own layout nests
repos deeper than that, raise `scan_depth` for that project explicitly (`scan_depth = 5`, or
whatever your deepest repo needs) or register the deep repo directly with `workytree repo add`.

    ~/.config/workytree/config
    ─────────────────────────
    default_project = work
    alias_wt = true
    kinds = feature,fix,chore,hotfix,refactor

    [project work]
    repo_root     = ~/work/products
    worktree_root = ~/work/worktrees
    scan_depth    = 3

    [repo legacy]            # optional explicit registration, e.g. a clone outside repo_root
    path    = ~/elsewhere/legacy-api
    project = work

## Usage

    wt create                       # interactive: project → repo → kind → ticket → base → confirm
    wt create fix PROJ-1             # inside a repo: confirm repo, then create
    wt create server fix PROJ-1      # explicit repo
    wt create server fix PROJ-1 origin/develop -y
    wt cd server fix PROJ-1
    wt list [repo] · wt repos · wt path [repo [kind [ticket]]]
    wt remove server fix PROJ-1 [--force] [-b|-B]
    wt prune [repo]
    wt project add <name> <repo_root> <worktree_root>
    wt repo add <path> [--name n] [--project p]
    wt config get|set|edit|path
    wt create --ai fix PROJ-1       # create, cd, then open an AI session there

Repo names are resolved in order: registered `[repo]` alias → scan of every project's
`repo_root` → current directory. Ambiguous names across projects need `--project <name>`; two
repos sharing a basename *within the same project* can't be disambiguated with `--project` (they're
already in it) — register the one you want under a distinct alias with `workytree repo add
<path> --name <alias>` instead.
`--project`, `--yes`/`-y`, and `--no-color` are global options and are accepted in any
position on the command line.

## AI sessions (opt-in)

`create` can hand the new worktree straight to an AI coding agent. It is **off by
default**: no agent is offered, prompted for, or launched until you turn it on, and the
temp file the wrapper would launch it through is not created either. See "Known
limitations" below.

    wt create --ai fix PROJ-1        # this run only
    wt config set ai_session always  # every run

The agent runs in your current shell, in the new worktree, in the foreground — quit it
and you are back in that worktree. This only works through the shell integration (`wt`,
or `workytree` as the function this repo installs). Calling `bin/workytree` directly still
creates the worktree either way, but never launches an agent: with AI sessions off (the
default) that's silent, and with them turned on (`ai_session` other than `off`, or `--ai`)
it instead prints a warning explaining why nothing launched.

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
shorten a list, not just extend it. An agent with no profile (`ai_agent = aider`) has no
options to build menus from, but that alone doesn't skip the interview: under
`ai_session = ask` it still asks "open a $name session here?" before running, with just
no per-option menus after it; only `ai_session = always` (or `--ai`) runs it straight away.

`-y`/`--yes` skips the interview entirely and runs the bare `command`. Cancelling the
interview (`q`) leaves the worktree in place and exits 0 — a session that did not open is
never a failed `create`.

## Exit codes

| code | meaning |
| --- | --- |
| 0 | success |
| 1 | general error — a bad argument value (unknown repo/project, unmerged branch without `-B`, ...), or `init` refusing because a valid config already exists |
| 2 | usage error — malformed command line: wrong number of arguments, an unknown flag |
| 3 | a problem with the config **file's state** — not merely "no config". Covers: no config file; a config that fails to parse (duplicate section/key, an unparseable line); a config file that is unreadable or not a regular file; a `[project]` missing `repo_root` or `worktree_root`; a `repo_root`/`worktree_root` that is relative, `/`, or a strict ancestor of `$HOME`; and a config directory that isn't writable |
| 130 | interactive prompt was cancelled (`q` or EOF) |

Two rough edges are known and deliberately not smoothed over here: `resolve_repo`'s "unsafe
repo name" refusal and `prune`'s aggregate multi-repo failure both exit 1, where 3 would be
more consistent with the table above.

## Known limitations

These were found during development and deliberately left as-is; you will hit one of them
before you hit a bug.

- **`remove` deletes gitignored files without warning.** `remove` decides whether a worktree
  is safe to delete by asking git (`git status`) whether it's dirty. Anything gitignored —
  `.env`, `node_modules`, build output — is invisible to `git status` by definition, so a
  worktree holding nothing but gitignored files reads as perfectly clean and `remove` deletes
  it outright: exit 0, no `--force` needed, no confirmation, no mention of what was inside.
  This matches `git worktree remove`'s own behavior and is not a bug workytree fixes — but a
  `.env` that exists nowhere else is gone the moment you run `remove`. Back up anything
  gitignored you care about before removing a worktree.
- **Bare repos are not discovered.** The `repo_root` scan looks for a `.git` entry (file or
  directory) one level inside each candidate directory, so a bare repo (e.g. `project.git`,
  which has no `.git` of its own) is silently absent from `repos`, `path`, and every other
  form of repo resolution. "Bare repo + worktrees" is a common layout — if you use it, register
  the bare repo explicitly with `workytree repo add <path-to-bare.git>`.
- **A repo reachable only through a symlink is not discovered**, and neither is a repo that
  sits exactly *at* `repo_root` itself rather than in a subdirectory below it. The scan does
  not follow symlinks and only looks strictly inside `repo_root`. Use `workytree repo add` to
  register either case explicitly.
- **Positional ambiguity in `create`.** `create [repo] [kind] [ticket] [base]` treats the
  first positional as the repo name whenever it matches a known repo. If you have a repo
  literally named e.g. `fix`, then `wt create fix T1 main` resolves to repo=`fix`,
  kind=`T1`, ticket=`main` — not "kind fix, ticket T1". Pass all four positionals, or run
  `create` from inside the repo (or interactively), to sidestep the ambiguity.
- **One incomplete `[project]` section rejects the whole config** for any command that needs
  it (`create`, `list`, `path`, `prune`, `repos`, ...) — but `config path`, `config get`,
  `config set`, and `config edit` keep working even then, so the config stays repairable
  through the CLI itself (`workytree config set project.<name>.worktree_root <path>`).
- **`wt` alias adoption.** If you hand-write a `wt` shell function whose body happens to be
  identical to the one workytree installs, it is treated as workytree's own and silently
  reasserted every time you re-source your shell config.
- **`config_remove_section` can orphan a preceding comment.** Removing a `[project ...]` or
  `[repo ...]` section deletes the header and its keys but leaves any comment line that was
  written directly above it in place; a later `project add`/`repo add` that appends a new
  section can end up with that orphaned comment sitting right above it, looking like it
  describes the new (unrelated) section.
- **`repo add` accepts any git working directory, not only a canonical clone** — pointing it
  at a `git worktree` directory registers that worktree itself under its own name. It also
  derives the registered name from a symlink's *resolved target*, not the symlink name you
  typed, when `--name` isn't given.
- **`teammate_mode` rides an undocumented `claude` flag.** `--teammate-mode` does not
  appear in `claude --help`; its allowed values (`auto`, `tmux`, `iterm2`, `in-process`)
  were found by probing an invalid one. It can change or disappear in any `claude`
  release, and when it does the assembled command fails at launch. That is survivable
  precisely because the list lives in config: drop `teammate_mode` from `ask` in your own
  `[agent claude]` section and you are unblocked without waiting for a workytree release.
- **An `[agent]` profile's `command` is tokenized like a shell command line, not read as free
  text.** It is handed to the shell wrapper one argv element per line and read back with
  `${(f)}`, which is what lets workytree avoid `eval` on a config-supplied string entirely —
  but getting there means the value goes through `${(z)}`/`${(Q)}` first, with the usual
  shell-quoting rules: wrap a multi-word value in double quotes (`command = claude --sys "be
  brief"`) or escape a literal space with a backslash (`hello\ there`) to keep it as one
  argument; either way the quotes/backslash are stripped before the agent sees it. An
  *unquoted* backslash is consumed by the tokenizer as an escape character (`command = claude
  --bare C:\path` delivers `C:path`, backslash gone) — but a backslash inside single or double
  quotes survives like any other character: both `command = claude --bare 'C:\path\to'` and
  `command = claude --bare "C:\path\to"` deliver `C:\path\to` intact. A `$'...'`-quoted control
  character is a sharper edge: `command = claude --bare $'a\nb' --after` turns `$'a\nb'` into a
  real newline, and because the runfile format is one argv element per line, that newline reads
  back as a second element — the agent receives four arguments (`--bare`, `a`, `b`, `--after`)
  instead of the three the config author wrote. And **arguments cannot be empty strings**:
  `--flag ""` cannot be expressed in an `[agent]` profile.
- **The AI-session launch channel is armed on every `create`, even with the feature off.**
  **Turning AI sessions on takes effect in the next shell.** The wrapper works out whether
  you have enabled them once, when your shell config sources it — answering that question
  costs a CLI call, and it needs the answer before every `create` — so a shell that was
  already running keeps the answer it started with. `workytree config set ai_session
  ask|always` says so when you run it; `--ai` works immediately in any shell, and turning
  sessions back **off** is honored immediately too, because the CLI re-reads `ai_session` on
  every run. This is the same trade-off `alias_wt` makes.

- **While AI sessions are on, a repository's `post-checkout` hook can interfere with the
  launch.** The wrapper creates a temp file under `$TMPDIR` named `workytree-ai.XXXXXX`,
  and after the `cd` it runs whatever that file contains. Only opted-in runs create one
  (`--ai`, or `ai_session` set to `ask`/`always` somewhere in your config), so a user who
  never enables the feature has no such file for anything to find. When you have enabled
  it, a hook — which runs inside `git worktree add`, before the launch — can locate the
  file by globbing and put its own command there.

  This is not new code execution: a `post-checkout` hook already runs arbitrary code as you
  on every `create`, feature or no feature. What changes is the context, from an unattended
  captured subprocess to the foreground shell you are about to type into. It also cannot be
  closed by hiding the path or the descriptor — on Linux a same-user process can read
  another's exec-time environment through `/proc/<pid>/environ` and reach its open files
  through `/proc/<pid>/fd` — so the channel existing only for opted-in runs is the property
  workytree can actually offer, not a step toward a stronger one.

## Development

    zsh tests/run.zsh

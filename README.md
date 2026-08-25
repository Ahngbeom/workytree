# workytree

Git worktree manager with project-scoped roots and an interactive `create`.
`workytree` is the command; `wt` is installed as a short alias for interactive shell use
(opt out with `alias_wt = false`, or `WORKYTREE_ALIAS=0` for the current shell).

## Install (zsh)

    curl -fsSL https://raw.githubusercontent.com/Ahngbeom/workytree/main/install.sh | sh
    exec zsh
    workytree init

`install.sh` clones (or, on a repeat run against the same install directory, updates) into
`~/.local/share/workytree`, symlinks `~/.local/bin/workytree` onto it, and adds one `source`
line to `~/.zshrc` — backing the file up first (`.zshrc.bak-<timestamp>`) and never adding the
line twice. It is safe to re-run.

Tested with zsh 5.9 and git 2.50.1. `fzf` is used for the `create` picker screens when it is
on your `PATH`; without it, `create` falls back to a numbered-menu prompt.

## Concepts

A **project** pairs a `repo_root` (a directory scanned recursively, up to `scan_depth` levels
deep, default 3) with a `worktree_root`. Worktrees are created at
`<worktree_root>/<repo>/<kind>/<ticket>` on branch `<kind>/<ticket>`.

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

Repo names are resolved in order: registered `[repo]` alias → scan of every project's
`repo_root` → current directory. Ambiguous names across projects need `--project <name>`.
`--project`, `--yes`/`-y`, and `--no-color` are global options and are accepted in any
position on the command line.

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

## Development

    zsh tests/run.zsh

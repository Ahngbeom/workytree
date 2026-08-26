# workytree

[![ci](https://github.com/Ahngbeom/workytree/actions/workflows/ci.yml/badge.svg)](https://github.com/Ahngbeom/workytree/actions/workflows/ci.yml)
(the badge renders as a broken image until this repository is public — GitHub does not serve it unauthenticated)

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
path this repository's `install-smoke` CI job exercises against every commit. It will work
once this repository is public; **it does not work yet**, because the repository is private
and an unauthenticated `curl` against it 404s today:

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

Repo names are resolved in order: registered `[repo]` alias → scan of every project's
`repo_root` → current directory. Ambiguous names across projects need `--project <name>`; two
repos sharing a basename *within the same project* can't be disambiguated with `--project` (they're
already in it) — register the one you want under a distinct alias with `workytree repo add
<path> --name <alias>` instead.
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

## Development

    zsh tests/run.zsh

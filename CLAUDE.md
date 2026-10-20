# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Revo is an agent-first multi-repo workspace manager — a fork of [Mars](https://github.com/dean0x/mars)
with additions that make coding agents more effective across repositories.

It is written in Bash (3.2+, macOS compatible) with no external dependencies
beyond `git` (and optionally `gh` for `revo pr` and `revo issue`).

### Relationship to Mars

Mars provides the workspace layer: `init`, `add`, `clone`, `status`, `sync`,
`branch`, `checkout`, `list`. Revo keeps all of those and adds:

- **`revo context`** — scans cloned repos and generates configured root-level
  agent files (`AGENTS.md`, `CLAUDE.md`, or both) that give coding agents a
  full picture of the workspace (frameworks, routes, dependency order, active
  feature briefs, tracker provider, and a built-in revo command reference).
- **`revo detect`** — bootstraps a workspace around git repos that already
  exist in the current directory (the "I have a folder full of clones" case)
  without prompts, then runs `revo context --auto`. It shares the repo
  detection code with `revo init` (`_init_detect_repos` in `init.sh`).
- **`revo feature <name>`** — creates a coordinated `feature/<name>` branch
  across repos and writes `.revo/features/<name>.md` as shared context.
- **`revo commit`**, **`revo push`**, **`revo pr`** — coordinated commit,
  push, and GitHub PR creation across matching repos.
- **`revo issue`** — list and create GitHub issues across repos when
  `tracker.provider` is `github`.
- **`revo workspace`** — isolated full copies of the repos under
  `.revo/workspaces/<name>/` with optional database cloning.

There is deliberately no `revo exec`. Mars had one; it was removed as an
arbitrary shell surface and `test/test_integration.sh` asserts it stays gone.
- **`depends_on`** field in `revo.yaml` — drives the dependency order in the
  generated agent files.

Revo also diverges from Mars on two existing commands:

- **`revo init`** auto-detects existing git repos in the current directory
  (and in `repos/`), adds them to `revo.yaml` with smart tag categorization,
  links root-level repos into `repos/` via relative symlinks, and runs
  `revo context` immediately. The workspace name prompt now defaults to the
  cwd basename so init can run non-interactively.
- **`revo clone`** always regenerates the workspace agent files after a
  successful clone batch (not just on first clone).

`revo.yaml` is the primary config file. `mars.yaml` is still honored as a
fallback for migration.

## Design Principles

- **Zero dependencies** — pure bash 3.2, plus `git` and optionally `gh`.
  Do not add jq, python, node, etc.
- **Agent-first** — commands should make coding agents more effective.
  Context generation, feature workspaces, and coordinated PRs all exist to
  give the agent a better picture and a cleaner workflow.
- **Workspace over orchestration** — Revo does not build, deploy, or run
  tests across repos. That belongs to the projects themselves. Revo manages
  the *shape* of the workspace.

## Commands

```bash
# Build bundled distribution (MUST run before committing source changes)
./build.sh              # Output: dist/revo (committed for easy installation)

# Run in development mode
./revo <command>        # Sources from lib/ directory

# Run tests (custom bash harness, no framework)
bash test/test_yaml.sh
bash test/test_config.sh
bash test/test_scan.sh
bash test/test_db.sh
bash test/test_workspace.sh
bash test/test_integration.sh
```

## Architecture

### Two Operating Modes
- **Development**: `./revo` sources files from `lib/` subdirectories
- **Distribution**: `dist/revo` is a single bundled file with all code inlined

### Module Structure
```
lib/
├── ui.sh           # Terminal UI (colors, spinners, prompts, tables)
├── yaml.sh         # revo.yaml parser (not general-purpose YAML)
├── config.sh       # Workspace detection and config loading
├── git.sh          # Git wrapper with output capture
├── scan.sh         # Per-repo framework/language/route detection (for revo context)
├── db.sh           # Database clone/drop for workspace isolation (postgres/mongodb/mysql)
└── commands/
    ├── init.sh       # workspace commands (init auto-detects existing repos)
    ├── detect.sh     # bootstrap revo around an existing folder of clones
    ├── add.sh
    ├── clone.sh      # always regenerates agent files after a clone batch
    ├── list.sh
    ├── status.sh
    ├── sync.sh
    ├── branch.sh
    ├── checkout.sh
    ├── context.sh    # agent-first commands (new in Revo)
    ├── feature.sh
    ├── commit.sh
    ├── push.sh
    ├── pr.sh
    ├── issue.sh
    └── workspace.sh  # workspace / workspaces commands
```

### Key Patterns

**Output Capture Pattern** — Git operations capture output in globals:
```bash
GIT_OUTPUT=""
GIT_ERROR=""
if git_clone "$url" "$path"; then
    # success: use GIT_OUTPUT
else
    # failure: use GIT_ERROR
fi
```

**Bash 3.2 Compatibility** — No associative arrays, uses parallel indexed arrays:
```bash
YAML_REPO_URLS=()
YAML_REPO_PATHS=()
YAML_REPO_TAGS=()
YAML_REPO_DEPS=()
```

**Tag Filtering** — Comma-separated tags with string matching:
```bash
[[ ",$tags," == *",$filter_tag,"* ]]
```

**Command Pattern** — Each command is `cmd_<name>()` in its own file under `lib/commands/`.

**No subshells for writes** — `revo context` writes directly to agent files
instead of building a string in a piped `while` loop, because subshells lose
global variable updates in bash 3.2.

### Configuration Format (revo.yaml)
```yaml
version: 1
workspace:
  name: "project-name"
  exclude: [latest.dump]       # optional: extra workspace copy excludes
agents:
  files: [AGENTS.md, CLAUDE.md]
tracker:
  provider: github
  linear:
    team: ""
    project: ""
repos:
  - url: git@github.com:org/shared-types.git
    tags: [shared]
  - url: git@github.com:org/backend.git
    path: api                    # optional custom path
    tags: [backend, api]
    depends_on: [shared-types]   # Revo-only: dependency ordering
    exclude: [/storage]          # optional: extra copy excludes for this repo
    include: [.vscode]           # optional: drop default excludes for this repo
    database:                    # optional: local DB to clone per workspace
      type: postgres             # postgres | mongodb | mysql
      name: myapp_dev            # local database name
  - url: git@github.com:org/frontend.git
    tags: [frontend]
    depends_on: [backend]
defaults:
  branch: main
```

`depends_on` is optional. It references other repos by their path basename
(derived from the URL unless overridden by `path`). It drives the topological
sort in the generated agent files and has no effect on clone/sync order.

`agents.files` controls which root-level instruction files are generated.
`tracker.provider` controls whether tracker work is routed to GitHub issues,
Linear MCP/app, or no tracker.

`workspace.exclude` and per-repo `exclude`/`include` tune what
`revo workspace` copies. The effective list is the built-in defaults
(`WORKSPACE_DEFAULT_EXCLUDES` in `lib/commands/workspace.sh`), then
`workspace.exclude`, then the repo's `exclude`, minus the repo's `include`.
An `include` entry removes every exclude entry with the same name, ignoring
leading and trailing slashes (`include: [tmp]` drops `/tmp/`); it does not
re-include a sub-path of an excluded folder. Patterns follow `.gitignore`
rules: `name` matches at any depth, a leading or middle `/` anchors to the
repo root, a trailing `/` matches directories only, and `*`/`?` glob within a
name. Use inline lists and quote globs (`["*.sqlite3"]`). After the copy,
tracked files under excluded paths (`tmp/.keep`, `log/.keep`) are restored
from the source, and a size report warns about any top-level directory over
100 MB. Both copy paths (rsync and the find fallback) read the one
`WORKSPACE_EXCLUDES` array, so keep new defaults in that list only.

`database` is optional. When present, `revo workspace` clones the named
database to a workspace-scoped copy (e.g., `myapp_dev_ws_feature_name`)
and drops it on `revo workspace --delete` or `--clean`. The DB CLI tools
(`psql`/`mongodump`/`mysql`) must be installed; DB errors are non-fatal.

## Implementation Constraints

- Return exit codes, never throw (bash has no exceptions)
- Avoid subshells where possible (breaks global variable updates)
- Check return codes explicitly and propagate errors
- Use `ui_step_error()`/`ui_step_done()` for user feedback
- Tests use `/tmp/revo/` for temporary files
- Clone operations run sequentially with per-repo spinner feedback
- `revo context` must be idempotent (safe to re-run)

## Release Process

Releases are manual. GitHub Actions never runs in this repo (it is a fork of
dean0x/mars and workflows on forks stay disabled until enabled in the Actions
tab, which has not been done), so a tag push publishes nothing. Follow the
"Release Process" section in `CONTRIBUTING.md` step by step: bump
`package.json`, `REVO_VERSION` in `revo`, and `REVO_VERSION` in `build.sh`;
add a `CHANGELOG.md` entry; run `./build.sh` and the tests; commit; tag
`vX.Y.Z` (three parts, `v` prefix); push `main` and the tag; `npm login` if
`npm whoami` fails; `npm publish --access public`; confirm with
`npm view @revotools/cli version`. Never run `npm publish` or push without
Marcus asking for that release.

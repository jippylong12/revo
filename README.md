# Revo

[![npm](https://img.shields.io/npm/v/@revotools/cli)](https://www.npmjs.com/package/@revotools/cli)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Revo is a Claude-first multi-repo workspace manager. You install it, point it at your repos, and then talk to Claude — Claude reads a generated `CLAUDE.md` that maps the entire workspace (frameworks, dependencies, routes, active features) and uses revo commands to work across repos: creating isolated workspaces, committing, pushing, opening PRs, and closing everything out when done.

The intended workflow is: **set up once, then stay in Claude.** You shouldn't need to memorize revo commands — Claude knows them. Just say what you want done.

## Install and Set Up

```bash
npm install -g @revotools/cli

cd ~/code/my-project        # your folder of repos (or an empty directory)
revo init                   # auto-detects existing repos, writes CLAUDE.md
```

That's it. Open Claude Code in the workspace directory and start talking.

## Talk to Claude

Once the workspace is set up, you work through Claude:

```
> "use revo to add this repo: git@github.com:org/backend.git with tags backend,api"

> "use revo workspace and work on issue #12"

> "create a feature for the new auth flow across backend and frontend"

> "commit everything and open PRs"

> /revo:closeout
```

Claude reads the generated `CLAUDE.md`, understands the repo layout and dependencies, and uses revo commands to execute. You stay in the conversation — revo handles the cross-repo coordination underneath.

### Claude Code Skills

Revo ships with Claude Code skills that you can invoke directly:

- **`/revo:closeout`** — wraps up a workspace: merges branches back to main, cleans up the workspace, drops test databases, summarizes and closes linked GitHub issues

## What Revo Does

### Workspace isolation

`revo workspace <name>` creates a full independent copy of your repos with a `feature/<name>` branch. Edit freely — nothing touches the original. When databases are configured, it clones those too.

```bash
revo workspace auth-overhaul
# Path: /Users/you/project/.revo/workspaces/auth-overhaul
# Database: myapp_dev_ws_auth_overhaul (postgres)
# cd /Users/you/project/.revo/workspaces/auth-overhaul
```

### Database cloning

Add `database:` to repos in `revo.yaml` and workspaces automatically clone the database on create, drop it on delete:

```yaml
repos:
  - url: git@github.com:org/backend.git
    tags: [backend]
    database:
      type: postgres       # postgres | mongodb | mysql
      name: myapp_dev
```

Or via CLI: `revo add <url> --database postgres:myapp_dev`

### Context generation

`revo init` (on an existing workspace) scans every repo and writes a `CLAUDE.md` that tells Claude:
- Per-repo: language, framework, API routes, package name, Docker status
- Dependency order (topological sort from `depends_on`)
- Active workspaces with paths and database names
- Active features with links to `.revo/features/*.md`
- Workflow instructions so Claude knows how to use revo

### Coordinated operations

All commands work across repos in one shot, with `--tag` filtering:

```bash
revo commit "wire up auth endpoint"    # commit all dirty repos
revo push                              # push all branches
revo pr "Auth endpoint"                # coordinated PRs via gh CLI
revo sync --tag backend                # pull latest on backend repos
revo exec "npm test" --tag frontend    # run tests on frontend repos
```

### Auto-logged feature tracking

When you `revo commit` inside a workspace, it auto-appends to `.revo/features/<name>.md` — timestamp, message, repos, and SHAs. The closeout skill reads this instead of re-discovering from git.

## Commands

| Command | Description |
|---------|-------------|
| `revo init` | Initialize workspace or regenerate CLAUDE.md (idempotent) |
| `revo add <url> [options]` | Add a repo (`--tags`, `--depends-on`, `--database type:name`) |
| `revo clone [--tag TAG]` | Clone configured repos |
| `revo feature <name>` | Create feature branch + context file across repos |
| `revo workspace <name>` | Create isolated workspace with DB cloning |
| `revo workspace list` | List active workspaces |
| `revo commit <msg>` | Commit across dirty repos |
| `revo push` | Push branches across repos |
| `revo pr <title>` | Create coordinated PRs via `gh` |
| `revo issue list\|create` | List/create GitHub issues across repos |
| `revo status` | Branch and dirty state across repos |
| `revo sync` | Pull latest changes |
| `revo branch <name>` | Create branch across repos |
| `revo checkout <branch>` | Checkout branch across repos |
| `revo exec "<cmd>"` | Run command in each repo |
| `revo list` | List configured repos |

All commands accept `--tag TAG` to target a subset of repos.

## Configuration

```yaml
version: 1
workspace:
  name: "my-project"
repos:
  - url: git@github.com:org/shared-types.git
    tags: [shared]
  - url: git@github.com:org/backend.git
    tags: [backend, api]
    depends_on: [shared-types]
    database:
      type: postgres
      name: myapp_dev
  - url: git@github.com:org/frontend.git
    tags: [frontend]
    depends_on: [backend]
defaults:
  branch: main
```

## Credits

Fork of [Mars](https://github.com/dean0x/mars) by [@dean0x](https://github.com/dean0x). Pure bash 3.2+, no dependencies beyond `git` (and `gh` for PRs/issues).

## License

MIT

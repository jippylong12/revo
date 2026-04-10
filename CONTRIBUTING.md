# Contributing to Revo

## Development Setup

Clone the repo and run directly in development mode:

```bash
git clone https://github.com/marcus.salinas/revo.git
cd revo
./revo init  # Sources from lib/ directory
```

## Project Structure

```
revo/
├── revo                   # Main CLI entry point
├── lib/
│   ├── ui.sh              # Terminal UI (colors, spinners, prompts, tables)
│   ├── yaml.sh            # revo.yaml parser
│   ├── config.sh          # Workspace detection and config loading
│   ├── git.sh             # Git wrapper with output capture
│   ├── scan.sh            # Framework/language detection (for revo context)
│   └── commands/          # Command implementations
│       ├── init.sh        # Mars-inherited commands
│       ├── clone.sh
│       ├── status.sh
│       ├── branch.sh
│       ├── checkout.sh
│       ├── sync.sh
│       ├── exec.sh
│       ├── add.sh
│       ├── list.sh
│       ├── context.sh     # Revo-specific commands
│       ├── feature.sh
│       ├── commit.sh
│       ├── push.sh
│       └── pr.sh
├── build.sh               # Build bundled distribution
├── install.sh             # Curl installer
├── dist/                  # Bundled distribution (committed)
└── test/                  # Test suite
```

## Architecture

### Two Operating Modes

- **Development**: `./revo` sources files from `lib/` subdirectories
- **Distribution**: `dist/revo` is a single bundled file with all code inlined

### Fork Relationship

Revo is a fork of [Mars](https://github.com/dean0x/mars). The workspace
primitives (init/add/clone/status/sync/branch/checkout/exec/list) are Mars's;
Revo adds the Claude-first commands (`context`, `feature`, `commit`, `push`,
`pr`) and the `depends_on` field in `revo.yaml`. Upstream Mars bug fixes can
usually be cherry-picked in from `lib/ui.sh`, `lib/yaml.sh`, `lib/config.sh`,
`lib/git.sh`, and the Mars-inherited commands.

### Key Patterns

**Output Capture** — Git operations capture output in globals:

```bash
GIT_OUTPUT=""
GIT_ERROR=""
if git_clone "$url" "$path"; then
    # success: use GIT_OUTPUT
else
    # failure: use GIT_ERROR
fi
```

**Bash 3.2 Compatibility** — No associative arrays; uses parallel indexed arrays:

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

**No subshells for writes** — `revo context` writes directly to CLAUDE.md
instead of building a string in a piped `while` loop, because subshells lose
global variable updates in bash 3.2.

### Implementation Constraints

- Bash 3.2+ (macOS default) — no associative arrays, no `readarray`
- Return exit codes, never throw (bash has no exceptions)
- Avoid subshells where possible (breaks global variable updates)
- Check return codes explicitly and propagate errors
- Use `ui_step_error()`/`ui_step_done()` for user feedback
- No runtime dependencies beyond `git` (and optionally `gh` for `revo pr`)

## Running Tests

```bash
bash test/test_yaml.sh
bash test/test_config.sh
bash test/test_integration.sh
```

Tests use `/tmp/revo/` for temporary files. The integration suite invokes
`revo` via `bash ../revo` so it does not require the executable bit.

## Building

```bash
./build.sh    # Output: dist/revo
```

**Important:** `dist/revo` is committed to the repo for easy installation.
Always run `./build.sh` before committing changes to source files.

## Pull Requests

- Run all tests before submitting
- Run `./build.sh` and include the updated `dist/revo`
- Maintain bash 3.2 compatibility (test on macOS if possible)
- Follow existing code patterns (output capture, parallel arrays, command pattern)

## Release Process

1. Update version in `package.json`, `revo`, and `build.sh`
2. Commit: `git commit -am "Bump version to X.Y.Z"`
3. Tag: `git tag vX.Y.Z`
4. Push: `git push origin main --tags`

CI automatically handles:

- Run tests
- Verify tag version matches `package.json`
- Create GitHub Release with `dist/revo` binary attached
- Publish to npm (`revo-cli`)

### Required Secrets (Maintainers)

| Secret | Purpose |
|--------|---------|
| `NPM_TOKEN` | npm publish access token |

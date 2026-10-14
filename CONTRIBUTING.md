# Contributing to Revo

## Development Setup

Clone the repo and run directly in development mode:

```bash
git clone https://github.com/jippylong12/revo.git
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
│       ├── init.sh        # Mars-inherited commands (init now auto-detects existing repos)
│       ├── detect.sh      # Bootstrap revo around a folder of existing clones
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
`pr`, `detect`) and the `depends_on` field in `revo.yaml`. Note that
`init.sh` and `clone.sh` have diverged from Mars: `cmd_init` now auto-detects
existing git repos and writes a Claude-first `CLAUDE.md`, and `cmd_clone`
always regenerates the workspace context after a clone batch. Upstream Mars
bug fixes for `lib/ui.sh`, `lib/yaml.sh`, `lib/config.sh`, `lib/git.sh`, and
the unmodified commands can still be cherry-picked.

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
bash test/test_scan.sh
bash test/test_workspace.sh
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

Releases are published manually from a maintainer's machine. The repo is a
fork of dean0x/mars, and GitHub keeps Actions workflows switched off on forks
until someone enables them in the Actions tab. That has never been done, so
`.github/workflows/release.yml` does not run on a tag push and no release has
ever shipped through it. Every published version came from `npm publish` run
locally. Keep it that way unless you deliberately enable Actions and add the
`NPM_TOKEN` secret.

1. Bump the version in all three places (they must match the tag exactly):
   `package.json`, `REVO_VERSION` in `revo`, and `REVO_VERSION` in `build.sh`.
2. Add a `CHANGELOG.md` entry and run `./build.sh` so `dist/revo` carries the
   new version. Run the full test suite as described above.
3. Commit: `git commit -am "Release X.Y.Z: short summary"`
4. Tag with the full three-part version: `git tag vX.Y.Z` (`v2.1` is wrong,
   `v2.1.0` is right).
5. Push: `git push origin main` then `git push origin vX.Y.Z`. Avoid
   `--tags`; old local tags that differ from the remote get rejected and
   clutter the output.
6. Log in to npm if `npm whoami` fails (saved tokens expire):
   `npm login`
7. Publish: `npm publish --access public`
8. Confirm: `npm view @revotools/cli version`
9. Optional GitHub Release with the binary attached:
   `gh release create vX.Y.Z dist/revo --generate-notes --title "vX.Y.Z"`
10. Install the new version locally:
    `npm install -g @revotools/cli@X.Y.Z && revo --version`

Checklist before step 7: `grep -n "X.Y.Z" package.json revo build.sh` prints
three lines.

### Why the release workflow is still in the repo

`release.yml` is kept as the reference automation. If a maintainer ever
wants tag-driven releases: open the Actions tab once, enable workflows on
the fork, add an `NPM_TOKEN` repository secret, and then a `vX.Y.Z` tag push
runs tests, checks the tag against `package.json`, creates the GitHub
Release, and publishes to npm. Until then, the steps above are the only
release path.

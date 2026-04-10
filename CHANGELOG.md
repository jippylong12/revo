# Changelog

## [0.5.0] - 2026-04-09

### Added
- `revo issue list` — wraps `gh issue list` across every repo in the
  workspace. Defaults to open issues, supports `--tag`, `--state`,
  `--label`, `--limit`. Pass `--json` to emit a flat JSON array (each
  entry has a `repo` field) so Claude or jq can filter cross-repo issue
  state without traversing a nested map.
- `revo issue create` — wraps `gh issue create`. Two modes:
  - `--repo NAME` for an explicit single-repo create.
  - `--tag TAG` to create the same issue in every repo with that tag,
    automatically cross-referencing each issue's body with the URLs of
    its sibling issues (same Pass-2 link pattern as `revo pr`).
  Optional `--feature NAME` appends the created issue links to
  `.revo/features/<NAME>.md` and references the brief from each issue
  body, so a single command produces linked issues + an updated feature
  brief in one shot.
- The auto-generated `CLAUDE.md` block now documents `revo issue
  list/create` so Claude Code discovers them when working in a revo
  workspace.

## [0.4.0] - 2026-04-09

### Fixed
- `revo init`, `revo detect`, `revo context`, and `revo clone` no longer
  clobber a pre-existing root-level `CLAUDE.md` or `.gitignore`. Previously,
  running revo in a directory that already had user content would silently
  overwrite both files.
  - `.gitignore`: revo's required entries (`repos/`, `.revo/`) are now merged
    into the existing file via a new `config_ensure_gitignore` helper. Only
    missing entries are appended; existing entries are left untouched.
  - `CLAUDE.md`: the auto-generated workspace context is now wrapped in
    `<!-- BEGIN revo:auto -->` / `<!-- END revo:auto -->` HTML-comment
    markers. On regeneration, only the marker block is replaced — content
    above and below the markers is preserved verbatim. If the file has no
    markers yet, the auto block is appended at the end with a separator.

### Changed
- `revo init` no longer double-writes `CLAUDE.md`. The onboarding placeholder
  is only written when the workspace root has no `CLAUDE.md` at all; when
  repos are detected, `cmd_context` handles the file directly with its
  marker-based splice.

## [0.3.0] - 2026-04-09

### Added
- `revo detect` — bootstraps a workspace around git repos that already exist
  in the current directory. Auto-tags by category (frontend/backend) based
  on package contents and links root-level repos into `repos/` via relative
  symlinks.
- `revo init` now auto-detects existing git repos in the current directory
  (and in `repos/`), adds them to `revo.yaml` with smart tag categorization,
  links root-level repos into `repos/`, and runs `revo context` immediately.
  When run in an empty directory it writes a Claude-first onboarding
  `CLAUDE.md` so the agent can start helping right away.
- `revo init` no longer requires a workspace name — pressing enter defaults
  to the current directory's basename, so `init` can run non-interactively.
- `revo context` now lists `.revo/features/*.md` briefs under an
  `## Active Features` section in the generated `CLAUDE.md`.
- `revo context` now appends a `## Workspace Tool: revo` section with a
  setup, daily-workflow, tag filtering, and feature workflow reference so
  Claude Code can rediscover the available commands without leaving the
  file.
- Extended framework detection in `lib/scan.sh`:
  - Node.js: React Native, Expo, Angular (in addition to existing
    Next/Nuxt/Remix/SvelteKit/Astro/Vite/NestJS/Fastify/Express/Hono/React/Vue/Svelte)
  - Java/Kotlin (Gradle), Java (Maven), Ruby (with Rails/Sinatra
    detection), Swift (Package.swift)

### Changed
- `revo clone` now always regenerates the workspace `CLAUDE.md` after a
  successful clone batch (previously only on first clone, when `CLAUDE.md`
  did not yet exist). The internal helper renamed from
  `context_autogenerate_if_missing` to `context_regenerate_silent`.

## [0.2.0] - 2026-04-09

Renamed the project from **Mars** to **Revo** and added Claude-first commands.

### Added
- `revo context` — scans cloned repos and generates a root-level `CLAUDE.md`
  with framework/language/routes per repo and a topologically-sorted dependency order
- `revo feature <name>` — creates a coordinated `feature/<name>` branch across
  matching repos and writes `.revo/features/<name>.md` as shared context
- `revo commit <msg>` — commits across dirty repos with a shared message
- `revo push` — pushes current branch across repos, auto-setting upstream
- `revo pr <title>` — creates coordinated GitHub PRs via `gh` CLI with
  cross-reference bodies linking all related PRs
- `depends_on` field in `revo.yaml` — drives the dependency order in the
  generated CLAUDE.md via Kahn-style topological sort
- `--depends-on` flag on `revo add`
- `lib/scan.sh` — per-repo framework/language/route detection (Node.js,
  Python, Go, Rust)
- Auto-generation of workspace `CLAUDE.md` on first successful `revo clone`
- `.revo/features/` directory for feature context files (gitignored)

### Changed
- Renamed binary: `mars` → `revo`
- Renamed config file: `mars.yaml` → `revo.yaml` (with `mars.yaml` fallback
  for migration from Mars)
- Renamed globals: `MARS_*` → `REVO_*`
- Renamed npm package: `@dean0x/mars` → `revo-cli`
- `revo init` now also adds `.revo/` to `.gitignore`
- Repository moved to `jippylong12/revo`; Mars remains upstream

### Migration from Mars

Existing Mars workspaces keep working — Revo still finds `mars.yaml` if
`revo.yaml` is not present. To fully migrate:

```bash
git mv mars.yaml revo.yaml
echo '.revo/' >> .gitignore
revo context    # generate CLAUDE.md
```

---

## Mars history (upstream, for reference)

See [dean0x/mars](https://github.com/dean0x/mars) for Mars's changelog.
Relevant upstream versions inherited by Revo 0.2.0:

### [0.1.2] - 2026-02-21 (Mars)
- Sequential clone with per-repo spinner
- Fixed exec argument parsing
- Table column alignment with ANSI-aware padding
- SIGPIPE trap for clean piped output

### [0.1.1] - 2026-02-19 (Mars)
- Install script downloads from GitHub Releases
- README overhaul with demo GIF

### [0.1.0] - 2026-02-16 (Mars)
- Initial workspace manager: `init`, `add`, `clone`, `list`, `status`,
  `branch`, `checkout`, `sync`, `exec`
- Tag-based filtering
- Clack-style terminal UI

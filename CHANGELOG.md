# Changelog

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

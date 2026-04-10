#!/usr/bin/env bash
# Revo CLI - init command
# Initializes a workspace and auto-detects existing git repos in the current
# directory (and in repos/), so that running `revo init` in a folder you
# already populated with clones bootstraps a usable workspace immediately.

# Suggest tags for an auto-detected repo based on its package contents.
# Always returns the repo name as a tag, plus an optional category tag
# (frontend/backend) when one can be inferred. Skips the category when it
# would be a duplicate of the name.
_init_auto_tags() {
    local dir="$1"
    local name="$2"
    local category=""

    if [[ -f "$dir/package.json" ]]; then
        if grep -qE '"(next|nuxt|react|vue|svelte|@angular/core|astro|@remix-run/react|@sveltejs/kit|expo|react-native)"' "$dir/package.json" 2>/dev/null; then
            category="frontend"
        elif grep -qE '"(express|fastify|hono|@nestjs/core|nestjs|koa)"' "$dir/package.json" 2>/dev/null; then
            category="backend"
        fi
    elif [[ -f "$dir/go.mod" ]] || [[ -f "$dir/Cargo.toml" ]] || [[ -f "$dir/pom.xml" ]] || [[ -f "$dir/build.gradle" ]] || [[ -f "$dir/build.gradle.kts" ]]; then
        category="backend"
    elif [[ -f "$dir/pyproject.toml" ]] || [[ -f "$dir/requirements.txt" ]]; then
        category="backend"
    fi

    if [[ -n "$category" ]] && [[ "$category" != "$name" ]]; then
        printf '%s, %s' "$name" "$category"
    else
        printf '%s' "$name"
    fi
}

# Scan for git repos in the current directory and in repos/.
# Sets _INIT_FOUND_DIRS to a newline-separated list of repo paths.
_INIT_FOUND_DIRS=""
_init_scan_existing() {
    _INIT_FOUND_DIRS=""

    local d
    for d in */; do
        d="${d%/}"
        [[ "$d" == "repos" ]] && continue
        [[ "$d" == ".revo" ]] && continue
        if [[ -d "$d/.git" ]]; then
            if [[ -z "$_INIT_FOUND_DIRS" ]]; then
                _INIT_FOUND_DIRS="$d"
            else
                _INIT_FOUND_DIRS="$_INIT_FOUND_DIRS"$'\n'"$d"
            fi
        fi
    done

    if [[ -d "repos" ]]; then
        for d in repos/*/; do
            d="${d%/}"
            if [[ -d "$d/.git" ]]; then
                if [[ -z "$_INIT_FOUND_DIRS" ]]; then
                    _INIT_FOUND_DIRS="$d"
                else
                    _INIT_FOUND_DIRS="$_INIT_FOUND_DIRS"$'\n'"$d"
                fi
            fi
        done
    fi
}

# Write a Claude-first onboarding CLAUDE.md if and only if the workspace
# root has no CLAUDE.md yet. Existing files are left alone — `revo context`
# will append its marker-wrapped auto block once repos are added.
_init_write_claude_md() {
    local out="$REVO_WORKSPACE_ROOT/CLAUDE.md"

    if [[ -f "$out" ]]; then
        return 0
    fi

    cat > "$out" << 'EOF'
# Workspace managed by revo

This is a multi-repo workspace managed by revo.
revo is installed and available in the terminal.

## Quick reference

### If repos are not yet added
The user may give you repo URLs or descriptions. Use these commands to set up:

```bash
revo add <git-url> --tags <tag1,tag2> [--depends-on <repo-name>]
revo clone
revo context    # regenerates this file with full repo details
```

Example:
```bash
revo add git@github.com:org/shared.git --tags shared,types
revo add git@github.com:org/backend.git --tags backend,api --depends-on shared
revo add git@github.com:org/frontend.git --tags frontend,web --depends-on backend
revo clone
```

### If repos are already set up
Use `revo status` to see all repos, branches, and dirty state.

## Available commands
- `revo status` — branch and dirty state across all repos
- `revo sync` — pull latest across all repos
- `revo feature <name>` — create feature branch across all repos
- `revo commit "msg"` — commit all dirty repos with same message
- `revo push` — push all repos
- `revo pr "title"` — create coordinated PRs via gh CLI
- `revo exec "cmd" --tag <tag>` — run command in filtered repos
- `revo context` — regenerate this file after repos change
- `revo add <url> --tags <t> --depends-on <d>` — add a repo

### Tag filtering
All commands support `--tag <tag>` to target specific repos:

```bash
revo exec "npm test" --tag frontend
revo sync --tag backend
revo branch hotfix --tag api
```

## Working in this workspace
- Repos are in the repos/ subdirectory (or as configured in revo.yaml)
- Edit files across repos/ directly — you have full access
- When making cross-repo changes, follow the dependency order below
- Check .revo/features/ for active feature briefs
- Use revo commands instead of manually running git in each repo

## Dependency order
<!-- revo context will fill this in once repos are cloned -->
Run `revo context` after cloning to populate repo details and dependency order.
EOF

    ui_step_done "Created CLAUDE.md (Claude reads this automatically)"
}

cmd_init() {
    local workspace_name=""

    # Already initialized? Just regenerate context.
    if [[ -f "revo.yaml" ]] || [[ -f "mars.yaml" ]]; then
        cmd_context "$@"
        return $?
    fi

    ui_intro "Revo - Claude-first Multi-Repo Workspace"

    # Default workspace name to current directory basename so init can run
    # non-interactively. The user can still override by typing a value.
    local default_name
    default_name=$(basename "$PWD")
    ui_step "Workspace name?"
    printf '%s  ' "$(ui_bar)"
    read -r workspace_name || true
    if [[ -z "$workspace_name" ]]; then
        workspace_name="$default_name"
    fi

    ui_step_done "Workspace:" "$workspace_name"
    ui_bar_line

    # Initialize the on-disk config.
    if ! config_init "$workspace_name"; then
        ui_step_error "Failed to initialize workspace"
        return 1
    fi

    ui_step_done "Created revo.yaml"
    ui_step_done "Created .gitignore"
    ui_step_done "Created repos/ directory"

    # Auto-detect existing git repos in the current directory.
    _init_scan_existing
    local detected_count=0
    if [[ -n "$_INIT_FOUND_DIRS" ]]; then
        local dir name remote tags path
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            name=$(basename "$dir")
            remote=$(cd "$dir" && git remote get-url origin 2>/dev/null || true)
            if [[ -z "$remote" ]]; then
                ui_step_error "Skipping $name (no git remote)"
                continue
            fi

            path="$name"

            # If the repo lives at the workspace root (not under repos/),
            # link it into repos/ so the rest of revo's data model — which
            # always resolves $REVO_REPOS_DIR/$path — works without copying
            # or moving files.
            if [[ "$dir" != repos/* ]]; then
                if [[ ! -e "repos/$name" ]]; then
                    ln -s "../$name" "repos/$name"
                fi
            fi

            tags=$(_init_auto_tags "$dir" "$name")
            local branch
            branch=$(git_default_branch "$dir")
            yaml_add_repo "$remote" "$path" "$tags" "" "$branch"
            ui_step_done "Detected:" "$name → $remote (branch: $branch)"
            detected_count=$((detected_count + 1))
        done <<< "$_INIT_FOUND_DIRS"

        if [[ $detected_count -gt 0 ]]; then
            config_save
            ui_info "$(ui_dim "Edit revo.yaml to adjust tags or add depends_on relationships")"
        fi
    fi

    # If we detected repos, hand off to cmd_context — it now wraps its output
    # in BEGIN/END markers and preserves any user content in CLAUDE.md, so we
    # don't need the onboarding placeholder. When no repos were detected,
    # write the placeholder so Claude has something to read.
    if [[ $detected_count -gt 0 ]]; then
        ui_bar_line
        cmd_context
        return 0
    fi

    _init_write_claude_md

    ui_outro "Workspace initialized! Run 'revo add <url>' to add repositories."
    return 0
}

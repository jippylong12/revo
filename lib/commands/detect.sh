#!/usr/bin/env bash
# Revo CLI - detect command
# Bootstraps a workspace around git repos that already exist in the current
# directory. Use this when you have a parent folder full of clones and want
# revo to wrap them without re-cloning.

cmd_detect() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                printf 'Usage: revo detect\n\n'
                printf 'Auto-detect git repositories in the current directory and\n'
                printf 'bootstrap a revo workspace around them. Generates revo.yaml\n'
                printf 'and CLAUDE.md from what it finds.\n'
                return 0
                ;;
            *)
                ui_step_error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [[ -f "revo.yaml" ]] || [[ -f "mars.yaml" ]]; then
        ui_step_error "Workspace already initialized — run 'revo context' to regenerate CLAUDE.md"
        return 1
    fi

    ui_intro "Revo - Detect Existing Repositories"
    ui_step "Scanning for git repos..."

    # Initialize the workspace using the cwd basename. This sets
    # REVO_WORKSPACE_ROOT/REVO_CONFIG_FILE/REVO_REPOS_DIR and writes an empty
    # revo.yaml + .gitignore.
    local default_name
    default_name=$(basename "$PWD")
    if ! config_init "$default_name"; then
        ui_step_error "Failed to initialize workspace"
        return 1
    fi

    local found=0
    local d name remote category tags

    for d in */; do
        d="${d%/}"
        [[ "$d" == "repos" ]] && continue
        [[ "$d" == ".revo" ]] && continue
        [[ -d "$d/.git" ]] || continue

        name="$d"
        remote=$(cd "$d" && git remote get-url origin 2>/dev/null || echo "local://$d")

        # Auto-categorize from package contents.
        category=""
        if [[ -f "$d/package.json" ]]; then
            if grep -qE '"(next|nuxt|react|vue|svelte|@angular/core|astro|@remix-run/react|@sveltejs/kit|expo|react-native)"' "$d/package.json" 2>/dev/null; then
                category="frontend"
            elif grep -qE '"(express|fastify|hono|@nestjs/core|nestjs|koa)"' "$d/package.json" 2>/dev/null; then
                category="backend"
            fi
        elif [[ -f "$d/go.mod" ]] || [[ -f "$d/Cargo.toml" ]] || [[ -f "$d/pom.xml" ]] || [[ -f "$d/build.gradle" ]] || [[ -f "$d/build.gradle.kts" ]]; then
            category="backend"
        elif [[ -f "$d/pyproject.toml" ]] || [[ -f "$d/requirements.txt" ]]; then
            category="backend"
        fi

        if [[ -n "$category" ]] && [[ "$category" != "$name" ]]; then
            tags="$name, $category"
        else
            tags="$name"
        fi

        # Link the root-level repo into repos/ so the rest of revo's data
        # model (which always resolves $REVO_REPOS_DIR/$path) works.
        if [[ ! -e "repos/$name" ]]; then
            ln -s "../$name" "repos/$name"
        fi

        yaml_add_repo "$remote" "$name" "$tags" ""
        ui_step_done "Found:" "$name ($remote)"
        found=$((found + 1))
    done

    if [[ -d "repos" ]]; then
        for d in repos/*/; do
            d="${d%/}"
            [[ -d "$d/.git" ]] || continue
            name=$(basename "$d")
            # Skip repos already added via symlink in the loop above.
            local already=0
            local i
            for ((i = 0; i < YAML_REPO_COUNT; i++)); do
                if [[ "$(yaml_get_path "$i")" == "$name" ]]; then
                    already=1
                    break
                fi
            done
            [[ $already -eq 1 ]] && continue
            remote=$(cd "$d" && git remote get-url origin 2>/dev/null || echo "local://$d")
            yaml_add_repo "$remote" "$name" "$name" ""
            ui_step_done "Found:" "$name ($remote)"
            found=$((found + 1))
        done
    fi

    if [[ $found -eq 0 ]]; then
        rm -f "$REVO_CONFIG_FILE"
        ui_step_error "No git repos found in current directory. Use 'revo init' instead."
        ui_outro_cancel "Nothing to detect"
        return 1
    fi

    config_save
    ui_step_done "Detected $found repository(ies)"
    ui_info "$(ui_dim "Edit revo.yaml to adjust tags or add depends_on relationships")"
    ui_bar_line

    cmd_context
    return 0
}

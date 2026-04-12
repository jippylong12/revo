#!/usr/bin/env bash
# Revo CLI - workspace / workspaces commands
# Full-copy workspaces under .revo/workspaces/<name>/. Unlike git worktrees
# these copy *everything* — .env, node_modules, build artifacts — so Claude
# can start work immediately with zero bootstrap. Hardlinks are used where
# possible so the cost is near-zero on APFS/HFS+ and Linux.

# --- helpers ---

# Sanitize a workspace name: lowercase, hyphens for spaces, drop anything
# that isn't [a-z0-9_-]. Keeps the resulting name safe to use as both a
# directory name and a git branch suffix.
_workspace_sanitize_name() {
    local raw="$1"
    local lowered
    lowered=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    lowered=$(printf '%s' "$lowered" | tr ' ' '-')
    # Replace anything not a-z0-9-_ with -
    lowered=$(printf '%s' "$lowered" | sed 's/[^a-z0-9_-]/-/g')
    # Collapse runs of - and trim leading/trailing -
    lowered=$(printf '%s' "$lowered" | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')
    printf '%s' "$lowered"
}

# Verify .revo/ is in the workspace .gitignore. Workspaces hardlink-copy
# everything, including .env files, so this is a hard requirement to avoid
# accidentally committing secrets via the parent git repo (if any).
# Returns 0 if safe, 1 if .revo/ is not gitignored.
_workspace_verify_gitignore_safe() {
    local gitignore="$REVO_WORKSPACE_ROOT/.gitignore"

    # If the workspace root isn't itself a git repo, there's nothing to
    # accidentally commit into. Treat as safe.
    if [[ ! -d "$REVO_WORKSPACE_ROOT/.git" ]]; then
        return 0
    fi

    if [[ ! -f "$gitignore" ]]; then
        return 1
    fi

    # Match `.revo/`, `.revo`, `/.revo/`, `/.revo` — any of those works
    awk '
        { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
        $0 == ".revo" || $0 == ".revo/" || $0 == "/.revo" || $0 == "/.revo/" { found = 1; exit }
        END { exit !found }
    ' "$gitignore"
}

# Copy a source repo into the workspace. Tries hardlinks first
# (`cp -RLl`), falls back to a regular recursive copy. Always follows
# symlinks so init-style symlinked repos are materialized as real
# directories inside the workspace.
#
# Real copy for all files (true isolation), then hardlink only heavy
# immutable directories (node_modules, .venv, vendor, etc.) to save disk.
# Usage: _workspace_copy_repo "src" "dest"
# Returns: 0 on success
_workspace_copy_repo() {
    local src="$1"
    local dest="$2"

    # Make sure parent exists, dest does not
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest" 2>/dev/null

    # Real copy — every file is independent (true workspace isolation).
    # Ignore broken symlinks (cp -RL fails on them); copy what we can.
    cp -RL "$src" "$dest" 2>/dev/null
    if [[ ! -d "$dest" ]]; then
        return 1
    fi

    # Replace heavy immutable directories with hardlinked copies to save disk.
    # These directories are never edited directly — they're rebuilt by package
    # managers, so hardlinks are safe here. If hardlink fails, keep the real copy.
    local hardlink_dirs="node_modules .venv venv vendor .gradle build/node_modules target .next .nuxt __pycache__ .dart_tool Pods"
    local dir_name
    for dir_name in $hardlink_dirs; do
        local src_dir="$src/$dir_name"
        local dest_dir="$dest/$dir_name"
        if [[ -d "$src_dir" ]] && [[ -d "$dest_dir" ]]; then
            local backup="$dest_dir.__revo_bak"
            mv "$dest_dir" "$backup"
            if cp -RLl "$src_dir" "$dest_dir" 2>/dev/null; then
                rm -rf "$backup"
            else
                # Hardlink failed — restore the real copy
                rm -rf "$dest_dir" 2>/dev/null
                mv "$backup" "$dest_dir"
            fi
        fi
    done

    return 0
}

# Print mtime in seconds-since-epoch for a path. Handles BSD (macOS) and
# GNU (Linux) stat. Prints 0 if both fail.
_workspace_mtime() {
    local path="$1"
    local mtime
    if mtime=$(stat -f %m "$path" 2>/dev/null); then
        printf '%s' "$mtime"
        return 0
    fi
    if mtime=$(stat -c %Y "$path" 2>/dev/null); then
        printf '%s' "$mtime"
        return 0
    fi
    printf '0'
}

# Format an age in seconds as a short, human string ("2h", "3d", ...).
_workspace_format_age() {
    local secs="$1"
    if [[ -z "$secs" ]] || [[ "$secs" -le 0 ]]; then
        printf 'just now'
        return
    fi
    if [[ "$secs" -lt 60 ]]; then
        printf '%ds' "$secs"
    elif [[ "$secs" -lt 3600 ]]; then
        printf '%dm' $((secs / 60))
    elif [[ "$secs" -lt 86400 ]]; then
        printf '%dh' $((secs / 3600))
    else
        printf '%dd' $((secs / 86400))
    fi
}

# Iterate the immediate subdirectories of a workspace dir that look like
# git repos. Prints one path per line.
# Usage: _workspace_repo_dirs "/abs/.revo/workspaces/foo"
_workspace_repo_dirs() {
    local ws_dir="$1"
    local d
    for d in "$ws_dir"/*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"
        if [[ -d "$d/.git" ]] || [[ -f "$d/.git" ]]; then
            printf '%s\n' "$d"
        fi
    done
}

# Returns 0 if the workspace has any repo with unpushed commits or
# uncommitted changes. Used by --delete to require --force.
_workspace_has_local_work() {
    local ws_dir="$1"
    local d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        # Dirty working tree?
        if [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]]; then
            return 0
        fi
        # Any commits not present on any remote ref?
        local unpushed
        unpushed=$(git -C "$d" log --oneline --not --remotes 2>/dev/null | head -n 1)
        if [[ -n "$unpushed" ]]; then
            return 0
        fi
    done <<< "$(_workspace_repo_dirs "$ws_dir")"
    return 1
}

# Returns 0 if every repo in the workspace has its current branch merged
# into the workspace default branch (local or origin/<default>).
# Workspaces with no repo dirs are not considered merged.
_workspace_all_merged() {
    local ws_dir="$1"
    local default_branch="$2"
    local any=0
    local d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        any=1
        # Try local default branch first, then origin/<default>
        if git -C "$d" merge-base --is-ancestor HEAD "$default_branch" 2>/dev/null; then
            continue
        fi
        if git -C "$d" merge-base --is-ancestor HEAD "origin/$default_branch" 2>/dev/null; then
            continue
        fi
        return 1
    done <<< "$(_workspace_repo_dirs "$ws_dir")"
    [[ $any -eq 1 ]]
}

# Generate a workspace-specific CLAUDE.md inside the workspace dir. Kept
# intentionally short — the root workspace CLAUDE.md is the canonical
# reference; this one just orients the agent inside the isolated copy.
_workspace_write_claude_md() {
    local name="$1"
    local ws_dir="$2"
    local branch="$3"
    local target="$ws_dir/CLAUDE.md"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local parent_name
    parent_name=$(config_workspace_name)

    {
        printf '# revo workspace: %s\n' "$name"
        printf '\n'
        printf '> WARNING: This workspace contains .env files and other secrets\n'
        printf '> hardlinked from the source repos. Never commit the .revo/\n'
        printf '> directory.\n'
        printf '\n'
        printf -- '- **Branch:** %s\n' "$branch"
        printf -- '- **Created:** %s\n' "$timestamp"
        if [[ -n "$parent_name" ]]; then
            printf -- '- **Parent workspace:** %s\n' "$parent_name"
        fi
        printf -- '- **Source:** ../../repos/\n'
        printf '\n'
        printf 'This is an isolated full-copy workspace. All edits, commits,\n'
        printf 'and pushes happen here — the source tree under `repos/` is\n'
        printf 'untouched. When you run `revo` from inside this directory it\n'
        printf 'automatically operates on the repos under this workspace, not\n'
        printf 'the source ones.\n'
        printf '\n'
        printf '## Repos\n'
        printf '\n'

        local d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            local rname rbranch
            rname=$(basename "$d")
            rbranch=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')
            printf '### %s\n' "$rname"
            printf -- '- **Path:** ./%s\n' "$rname"
            printf -- '- **Branch:** %s\n' "$rbranch"

            scan_repo "$d"
            if [[ -n "$SCAN_LANG" ]]; then
                if [[ -n "$SCAN_NAME" ]]; then
                    printf -- '- **Package:** %s (%s)\n' "$SCAN_NAME" "$SCAN_LANG"
                else
                    printf -- '- **Language:** %s\n' "$SCAN_LANG"
                fi
            fi
            if [[ -n "$SCAN_FRAMEWORK" ]]; then
                printf -- '- **Framework:** %s\n' "$SCAN_FRAMEWORK"
            fi
            if [[ -n "$SCAN_ROUTES" ]]; then
                printf -- '- **API routes:** %s\n' "$SCAN_ROUTES"
            fi
            local db_idx
            db_idx=$(yaml_find_by_name "$rname")
            if [[ $db_idx -ge 0 ]]; then
                local dbt dbn
                dbt=$(yaml_get_db_type "$db_idx")
                dbn=$(yaml_get_db_name "$db_idx")
                if [[ -n "$dbt" ]] && [[ -n "$dbn" ]]; then
                    local ws_db
                    ws_db=$(_db_workspace_name "$dbn" "$name")
                    printf -- '- **Database:** %s (%s) — cloned from %s\n' "$ws_db" "$dbt" "$dbn"
                fi
            fi
            printf '\n'
        done <<< "$(_workspace_repo_dirs "$ws_dir")"

        printf '## Workflow\n'
        printf '\n'
        printf '1. Edit code across the repos above\n'
        printf '2. `revo commit "msg"` to commit dirty repos in one shot\n'
        printf '3. `revo push` to push branches\n'
        printf '4. `revo pr "title"` to open coordinated PRs\n'
        printf '5. After merge, `cd ../../.. && revo workspace %s --delete`\n' "$name"
        printf '\n'
        printf '## Workspace Tool: revo\n'
        printf '\n'
        printf 'See ../../CLAUDE.md (the parent workspace context) for the full\n'
        printf 'revo command reference, dependency order, and per-repo details.\n'
    } > "$target"
}

# --- create ---

_workspace_create() {
    local name="$1"
    local tag="$2"
    local force="$3"

    local sanitized
    sanitized=$(_workspace_sanitize_name "$name")
    if [[ -z "$sanitized" ]]; then
        ui_step_error "Invalid workspace name: $name"
        return 1
    fi

    if [[ "$sanitized" != "$name" ]]; then
        ui_info "$(ui_dim "Sanitized name: $name -> $sanitized")"
    fi
    name="$sanitized"

    local branch="feature/$name"
    local ws_root="$REVO_WORKSPACE_ROOT/.revo/workspaces"
    local ws_dir="$ws_root/$name"

    ui_intro "Revo - Create Workspace: $name"

    if [[ -d "$ws_dir" ]]; then
        ui_step_error "Workspace already exists: .revo/workspaces/$name"
        ui_info "$(ui_dim "Use 'revo workspace $name --delete' to remove it first")"
        ui_outro_cancel "Aborted"
        return 1
    fi

    if ! _workspace_verify_gitignore_safe; then
        ui_step_error ".revo/ is not in .gitignore at the workspace root"
        ui_info "$(ui_dim "Workspaces hardlink-copy .env files and secrets — committing")"
        ui_info "$(ui_dim ".revo/ would leak them. Add '.revo/' to .gitignore (or run 'revo init').")"
        if [[ $force -ne 1 ]]; then
            ui_info "$(ui_dim "Re-run with --force to override.")"
            ui_outro_cancel "Aborted for safety"
            return 1
        fi
        ui_step_error "Continuing anyway because --force was passed"
    fi

    local source_repos_dir
    source_repos_dir=$(config_source_repos_dir)

    local repos
    repos=$(config_get_repos "$tag")

    if [[ -z "$repos" ]]; then
        if [[ -n "$tag" ]]; then
            ui_step_error "No repositories match tag: $tag"
        else
            ui_step_error "No repositories configured"
        fi
        ui_outro_cancel "Nothing to copy"
        return 1
    fi

    mkdir -p "$ws_dir"

    local success_count=0
    local skip_count=0
    local fail_count=0
    local success_repos=()

    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue

        local path
        path=$(yaml_get_path "$repo")
        local src="$source_repos_dir/$path"
        local dest="$ws_dir/$path"

        if [[ ! -d "$src" ]]; then
            ui_step_done "Skipped (not cloned):" "$path"
            skip_count=$((skip_count + 1))
            continue
        fi

        ui_spinner_start "Copying $path..."
        if _workspace_copy_repo "$src" "$dest"; then
            ui_spinner_stop
            ui_step_done "Copied:" "$path"
        else
            ui_spinner_error "Failed to copy: $path"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Check out the workspace branch in the copy
        if git -C "$dest" rev-parse --verify "$branch" >/dev/null 2>&1; then
            if git -C "$dest" checkout "$branch" >/dev/null 2>&1; then
                ui_step_done "Checked out existing:" "$path -> $branch"
            else
                ui_step_error "Failed to checkout existing branch in: $path"
                fail_count=$((fail_count + 1))
                continue
            fi
        else
            if git -C "$dest" checkout -b "$branch" >/dev/null 2>&1; then
                ui_step_done "Branched:" "$path -> $branch"
            else
                ui_step_error "Failed to create branch in: $path"
                fail_count=$((fail_count + 1))
                continue
            fi
        fi

        success_repos+=("$repo")
        success_count=$((success_count + 1))
    done <<< "$repos"

    if [[ $success_count -eq 0 ]]; then
        ui_outro_cancel "No repos copied; workspace cleanup needed"
        rm -rf "$ws_dir" 2>/dev/null
        return 1
    fi

    # --- Clone databases ---
    local db_clone_count=0
    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        local db_type db_name
        db_type=$(yaml_get_db_type "$repo")
        db_name=$(yaml_get_db_name "$repo")
        [[ -z "$db_type" ]] && continue

        local ws_db_name path
        ws_db_name=$(_db_workspace_name "$db_name" "$name")
        path=$(yaml_get_path "$repo")

        ui_spinner_start "Cloning DB: $db_name -> $ws_db_name ($db_type)..."
        if _db_clone "$db_type" "$db_name" "$ws_db_name"; then
            ui_spinner_stop
            ui_step_done "DB cloned:" "$db_name -> $ws_db_name ($db_type)"
            db_clone_count=$((db_clone_count + 1))
        else
            ui_spinner_error "DB clone failed: $db_name ($db_type) - $DB_ERROR"
        fi
    done <<< "$repos"

    # Feature file (so closeout has a source of truth)
    local feature_dir="$REVO_WORKSPACE_ROOT/.revo/features"
    mkdir -p "$feature_dir"
    local feature_file="$feature_dir/$name.md"

    if [[ -f "$feature_file" ]]; then
        ui_step_done "Feature file exists:" ".revo/features/$name.md"
    else
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        {
            printf '# Feature: %s\n' "$name"
            printf '\n'
            printf '## Status\n'
            printf -- '- Created: %s\n' "$timestamp"
            printf -- '- Branch: %s\n' "$branch"
            printf -- '- Source: revo workspace\n'
            if [[ -n "$tag" ]]; then
                printf -- '- Tag filter: %s\n' "$tag"
            fi
            printf '\n'
            printf '## Repos\n'

            local idx
            for idx in "${success_repos[@]}"; do
                local rpath rtags
                rpath=$(yaml_get_path "$idx")
                rtags=$(yaml_get_tags "$idx")
                if [[ -n "$rtags" ]]; then
                    printf -- '- %s (tags: %s)\n' "$rpath" "$rtags"
                else
                    printf -- '- %s\n' "$rpath"
                fi
            done

            printf '\n'
            printf '## Plan\n'
            printf '<!-- Describe what this feature does across repos -->\n'
            printf '\n'
            printf '## Changes\n'
            printf '<!-- Track what has been done in each repo -->\n'
            printf '\n'
            printf '## Dependencies\n'
            printf '<!-- Note cross-repo dependencies -->\n'
        } > "$feature_file"

        ui_step_done "Wrote:" ".revo/features/$name.md"
    fi

    # Workspace-level CLAUDE.md
    _workspace_write_claude_md "$name" "$ws_dir" "$branch"
    ui_step_done "Wrote:" "$ws_dir/CLAUDE.md"

    ui_bar_line

    if [[ $fail_count -gt 0 ]]; then
        ui_outro_cancel "Created with errors: $success_count ok, $fail_count failed"
        return 1
    fi

    local msg="Workspace ready"
    ui_info "$(ui_dim "Branch: $branch  •  Repos: $success_count")"
    if [[ $skip_count -gt 0 ]]; then
        ui_info "$(ui_dim "$skip_count repo(s) skipped (not cloned in source)")"
    fi
    ui_info ""
    ui_info "$(ui_dim "Path:") $ws_dir"
    if [[ $db_clone_count -gt 0 ]]; then
        # List cloned database names for easy copy
        while IFS= read -r repo; do
            [[ -z "$repo" ]] && continue
            local db_type db_name
            db_type=$(yaml_get_db_type "$repo")
            db_name=$(yaml_get_db_name "$repo")
            [[ -z "$db_type" ]] && continue
            local ws_db_name
            ws_db_name=$(_db_workspace_name "$db_name" "$name")
            ui_info "$(ui_dim "Database:") $ws_db_name ($db_type)"
        done <<< "$repos"
    fi
    ui_info ""
    ui_info "$(ui_dim "cd $ws_dir")"
    ui_outro "$msg"
    return 0
}

# --- delete ---

_workspace_delete() {
    local name="$1"
    local force="$2"

    local sanitized
    sanitized=$(_workspace_sanitize_name "$name")
    name="$sanitized"

    local ws_dir="$REVO_WORKSPACE_ROOT/.revo/workspaces/$name"

    ui_intro "Revo - Delete Workspace: $name"

    if [[ ! -d "$ws_dir" ]]; then
        ui_step_error "No such workspace: $name"
        ui_outro_cancel "Nothing to delete"
        return 1
    fi

    if [[ $force -ne 1 ]] && _workspace_has_local_work "$ws_dir"; then
        ui_step_error "Workspace has unpushed commits or uncommitted changes"
        ui_info "$(ui_dim "Push or stash your work first, or re-run with --force to discard it.")"
        ui_outro_cancel "Aborted"
        return 1
    fi

    # Drop workspace databases
    local i
    for ((i = 0; i < YAML_REPO_COUNT; i++)); do
        local db_type db_name
        db_type=$(yaml_get_db_type "$i")
        db_name=$(yaml_get_db_name "$i")
        [[ -z "$db_type" ]] && continue
        local ws_db_name
        ws_db_name=$(_db_workspace_name "$db_name" "$name")
        if _db_drop "$db_type" "$ws_db_name"; then
            ui_step_done "Dropped DB:" "$ws_db_name ($db_type)"
        else
            ui_step_error "Failed to drop DB: $ws_db_name - $DB_ERROR"
        fi
    done

    # Remove workspace directory. rm -rf can fail on macOS with locked files
    # (.DS_Store, Spotlight indexes), so fall back to rm -r.
    rm -rf "$ws_dir" 2>/dev/null || rm -r "$ws_dir" 2>/dev/null || true

    if [[ -d "$ws_dir" ]]; then
        ui_step_error "Could not fully remove .revo/workspaces/$name"
        ui_outro_cancel "Partial cleanup — remove manually"
        return 1
    fi

    ui_step_done "Deleted:" ".revo/workspaces/$name"
    ui_outro "Workspace removed"
    return 0
}

# --- clean ---

_workspace_clean() {
    local ws_root="$REVO_WORKSPACE_ROOT/.revo/workspaces"

    ui_intro "Revo - Clean Merged Workspaces"

    if [[ ! -d "$ws_root" ]]; then
        ui_info "No workspaces"
        ui_outro "Nothing to clean"
        return 0
    fi

    local default_branch
    default_branch=$(config_default_branch)
    [[ -z "$default_branch" ]] && default_branch="main"

    local cleaned=0
    local kept=0
    local d
    for d in "$ws_root"/*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"
        local name
        name=$(basename "$d")

        if _workspace_all_merged "$d" "$default_branch"; then
            # Drop workspace databases before removing directory
            local i
            for ((i = 0; i < YAML_REPO_COUNT; i++)); do
                local db_type db_name
                db_type=$(yaml_get_db_type "$i")
                db_name=$(yaml_get_db_name "$i")
                [[ -z "$db_type" ]] && continue
                local ws_db_name
                ws_db_name=$(_db_workspace_name "$db_name" "$name")
                if _db_drop "$db_type" "$ws_db_name"; then
                    ui_step_done "Dropped DB:" "$ws_db_name ($db_type)"
                fi
            done
            rm -rf "$d"
            ui_step_done "Removed (merged):" "$name"
            cleaned=$((cleaned + 1))
        else
            ui_step_done "Kept:" "$name"
            kept=$((kept + 1))
        fi
    done

    ui_bar_line
    ui_outro "Cleaned $cleaned, kept $kept"
    return 0
}

# --- list (revo workspaces) ---

cmd_workspaces() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                printf 'Usage: revo workspaces\n\n'
                printf 'List all active workspaces with branch, age, and dirty state.\n'
                return 0
                ;;
            *)
                ui_step_error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    config_require_workspace || return 1

    ui_intro "Revo - Workspaces"

    local ws_root="$REVO_WORKSPACE_ROOT/.revo/workspaces"
    if [[ ! -d "$ws_root" ]]; then
        ui_info "No workspaces"
        ui_bar_line
        ui_info "$(ui_dim "Create one with: revo workspace <name>")"
        ui_outro "Done"
        return 0
    fi

    # Count first so we can short-circuit empty
    local total=0
    local d
    for d in "$ws_root"/*/; do
        [[ -d "$d" ]] || continue
        total=$((total + 1))
    done

    if [[ $total -eq 0 ]]; then
        ui_info "No workspaces"
        ui_bar_line
        ui_info "$(ui_dim "Create one with: revo workspace <name>")"
        ui_outro "Done"
        return 0
    fi

    ui_table_widths 24 24 8 7 12
    ui_table_header "Workspace" "Branch" "Age" "Repos" "Dirty"

    local now
    now=$(date +%s)

    for d in "$ws_root"/*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"
        local name
        name=$(basename "$d")

        local mtime
        mtime=$(_workspace_mtime "$d")
        local age_secs=$((now - mtime))
        local age
        age=$(_workspace_format_age "$age_secs")

        local repos_in_ws=0
        local dirty_count=0
        local branch=""
        local repo
        while IFS= read -r repo; do
            [[ -z "$repo" ]] && continue
            repos_in_ws=$((repos_in_ws + 1))
            if [[ -z "$branch" ]]; then
                branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')
            fi
            if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
                dirty_count=$((dirty_count + 1))
            fi
        done <<< "$(_workspace_repo_dirs "$d")"

        [[ -z "$branch" ]] && branch="$(ui_dim "-")"

        local dirty_text
        if [[ $dirty_count -gt 0 ]]; then
            dirty_text="$(ui_yellow "$dirty_count dirty")"
        else
            dirty_text="$(ui_green "clean")"
        fi

        ui_table_row "$name" "$branch" "$age" "$repos_in_ws" "$dirty_text"
    done

    ui_bar_line
    ui_outro "$total workspace(s)"
    return 0
}

# --- entry point: revo workspace ---

cmd_workspace() {
    local name=""
    local tag=""
    local action="create"
    local force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)
                [[ $# -lt 2 ]] && { ui_step_error "Option --tag requires a value"; return 1; }
                tag="$2"
                shift 2
                ;;
            --delete)
                action="delete"
                shift
                ;;
            --clean)
                action="clean"
                shift
                ;;
            --force|-f)
                force=1
                shift
                ;;
            --help|-h)
                cat << 'EOF'
Usage:
  revo workspace <name> [--tag TAG]      Create an isolated workspace
  revo workspace <name> --delete [--force]  Delete a workspace
  revo workspace --clean                 Remove merged workspaces
  revo workspace list                    List active workspaces

Workspaces are independent copies of all repos (or a tagged subset)
under .revo/workspaces/<name>/. Each gets its own feature/<name>
branch and cloned databases (if configured).

Run revo from inside .revo/workspaces/<name>/ and it automatically
operates on the workspace's repos rather than the source tree.

EOF
                return 0
                ;;
            -*)
                ui_step_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    ui_step_error "Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done

    config_require_workspace || return 1

    # "revo workspace list" → show workspaces table
    if [[ "$name" == "list" ]]; then
        cmd_workspaces
        return $?
    fi

    case "$action" in
        clean)
            _workspace_clean
            ;;
        delete)
            if [[ -z "$name" ]]; then
                ui_step_error "Usage: revo workspace <name> --delete [--force]"
                return 1
            fi
            _workspace_delete "$name" "$force"
            ;;
        create)
            if [[ -z "$name" ]]; then
                ui_step_error "Usage: revo workspace <name> [--tag TAG]"
                return 1
            fi
            _workspace_create "$name" "$tag" "$force"
            ;;
    esac
}

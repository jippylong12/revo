#!/usr/bin/env bash
# Revo CLI - feature command
# Creates a coordinated feature branch and writes a feature context file.

cmd_feature() {
    local name=""
    local tag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)
                tag="$2"
                shift 2
                ;;
            --help|-h)
                printf 'Usage: revo feature <name> [--tag TAG]\n\n'
                printf 'Creates feature/<name> on matching repos and writes\n'
                printf '.revo/features/<name>.md as a shared context file.\n'
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

    if [[ -z "$name" ]]; then
        ui_step_error "Usage: revo feature <name> [--tag TAG]"
        return 1
    fi

    config_require_workspace || return 1

    local branch="feature/$name"
    ui_intro "Revo - Feature: $name"

    local repos
    repos=$(config_get_repos "$tag")

    if [[ -z "$repos" ]]; then
        ui_step_error "No repositories match"
        ui_outro_cancel "Nothing to do"
        return 1
    fi

    local success_count=0
    local skip_count=0
    local fail_count=0
    local involved_indices=()

    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue

        local path
        path=$(yaml_get_path "$repo")
        local full_path="$REVO_REPOS_DIR/$path"

        if [[ ! -d "$full_path" ]]; then
            ui_step_done "Skipped (not cloned):" "$path"
            skip_count=$((skip_count + 1))
            continue
        fi

        involved_indices+=("$repo")

        if git_branch_exists "$full_path" "$branch"; then
            if git_checkout "$full_path" "$branch"; then
                ui_step_done "Checked out existing:" "$path → $branch"
                success_count=$((success_count + 1))
            else
                ui_step_error "Failed to checkout existing branch: $path"
                fail_count=$((fail_count + 1))
            fi
            continue
        fi

        if git_branch "$full_path" "$branch"; then
            ui_step_done "Created:" "$path → $branch"
            success_count=$((success_count + 1))
        else
            ui_step_error "Failed: $path - $GIT_ERROR"
            fail_count=$((fail_count + 1))
        fi
    done <<< "$repos"

    # Write feature context file
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
            if [[ -n "$tag" ]]; then
                printf -- '- Tag filter: %s\n' "$tag"
            fi
            printf '\n'
            printf '## Repos\n'

            local idx
            for idx in "${involved_indices[@]}"; do
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
            printf '<!-- The agent will read this to understand the scope -->\n'
            printf '\n'
            printf '## Changes\n'
            printf '<!-- Track what has been done in each repo -->\n'
            printf '\n'
            printf '## Dependencies\n'
            printf '<!-- Note cross-repo dependencies -->\n'
        } > "$feature_file"

        ui_step_done "Wrote:" ".revo/features/$name.md"
    fi

    ui_bar_line

    if [[ $fail_count -eq 0 ]]; then
        local msg="Feature '$name' ready on $success_count repo(s)"
        [[ $skip_count -gt 0 ]] && msg+=", $skip_count skipped"
        ui_info "$(ui_dim "Next: edit .revo/features/$name.md with the plan,")"
        ui_info "$(ui_dim "then ask Claude Code to work in $REVO_WORKSPACE_ROOT")"
        ui_outro "$msg"
    else
        ui_outro_cancel "$success_count succeeded, $fail_count failed"
        return 1
    fi

    return 0
}

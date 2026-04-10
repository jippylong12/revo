#!/usr/bin/env bash
# Revo CLI - push command
# Pushes current branch across repositories.

cmd_push() {
    local tag=""
    local set_upstream=1

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)
                [[ $# -lt 2 ]] && { ui_step_error "Option --tag requires a value"; return 1; }
                tag="$2"
                shift 2
                ;;
            --no-upstream)
                set_upstream=0
                shift
                ;;
            --help|-h)
                printf 'Usage: revo push [--tag TAG]\n\n'
                printf 'Pushes current branch of each repo to origin.\n'
                printf 'Sets upstream automatically the first time.\n'
                return 0
                ;;
            -*)
                ui_step_error "Unknown option: $1"
                return 1
                ;;
            *)
                ui_step_error "Unexpected argument: $1"
                return 1
                ;;
        esac
    done

    config_require_workspace || return 1

    ui_intro "Revo - Push Repositories"

    local repos
    repos=$(config_get_repos "$tag")

    if [[ -z "$repos" ]]; then
        ui_step_error "No repositories configured"
        ui_outro_cancel "Nothing to push"
        return 1
    fi

    local success_count=0
    local skip_count=0
    local fail_count=0

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

        local branch
        branch=$(git_current_branch "$full_path")
        if [[ -z "$branch" ]] || [[ "$branch" == "HEAD" ]]; then
            ui_step_error "Detached HEAD: $path"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Check if upstream already exists
        local has_upstream=0
        if git -C "$full_path" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
            has_upstream=1
        fi

        if [[ $has_upstream -eq 1 ]]; then
            if git_exec "$full_path" push; then
                ui_step_done "Pushed:" "$path → $branch"
                success_count=$((success_count + 1))
            else
                ui_step_error "Failed: $path - $GIT_ERROR"
                fail_count=$((fail_count + 1))
            fi
        else
            if [[ $set_upstream -eq 1 ]]; then
                if git_exec "$full_path" push -u origin "$branch"; then
                    ui_step_done "Pushed (set upstream):" "$path → $branch"
                    success_count=$((success_count + 1))
                else
                    ui_step_error "Failed: $path - $GIT_ERROR"
                    fail_count=$((fail_count + 1))
                fi
            else
                ui_step_error "No upstream and --no-upstream set: $path"
                fail_count=$((fail_count + 1))
            fi
        fi
    done <<< "$repos"

    ui_bar_line

    if [[ $fail_count -eq 0 ]]; then
        local msg="Pushed $success_count repo(s)"
        [[ $skip_count -gt 0 ]] && msg+=", $skip_count skipped"
        ui_outro "$msg"
    else
        ui_outro_cancel "$success_count pushed, $fail_count failed"
        return 1
    fi

    return 0
}

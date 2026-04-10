#!/usr/bin/env bash
# Revo CLI - commit command
# Commit across dirty repos with the same message.

cmd_commit() {
    local message=""
    local tag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)
                tag="$2"
                shift 2
                ;;
            --help|-h)
                printf 'Usage: revo commit <message> [--tag TAG]\n\n'
                printf 'Stages and commits changes across dirty repos with the same message.\n'
                return 0
                ;;
            -*)
                ui_step_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$message" ]]; then
                    message="$1"
                else
                    ui_step_error "Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$message" ]]; then
        ui_step_error "Usage: revo commit <message> [--tag TAG]"
        return 1
    fi

    config_require_workspace || return 1

    ui_intro "Revo - Commit: $message"

    local repos
    repos=$(config_get_repos "$tag")

    if [[ -z "$repos" ]]; then
        ui_step_error "No repositories configured"
        ui_outro_cancel "Nothing to commit"
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

        if ! git_is_dirty "$full_path"; then
            ui_step_done "Clean (skipped):" "$path"
            skip_count=$((skip_count + 1))
            continue
        fi

        # Stage
        if ! git_exec "$full_path" add -A; then
            ui_step_error "Failed to stage: $path - $GIT_ERROR"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Commit
        if git_exec "$full_path" commit -m "$message"; then
            ui_step_done "Committed:" "$path"
            success_count=$((success_count + 1))
        else
            ui_step_error "Failed: $path - $GIT_ERROR"
            fail_count=$((fail_count + 1))
        fi
    done <<< "$repos"

    ui_bar_line

    if [[ $fail_count -eq 0 ]]; then
        local msg="Committed on $success_count repo(s)"
        [[ $skip_count -gt 0 ]] && msg+=", $skip_count skipped"
        ui_outro "$msg"
    else
        ui_outro_cancel "$success_count committed, $fail_count failed"
        return 1
    fi

    return 0
}

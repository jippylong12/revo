#!/usr/bin/env bash
# Revo CLI - pr command
# Creates coordinated pull requests across repos via the gh CLI.

cmd_pr() {
    local title=""
    local tag=""
    local body=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)
                [[ $# -lt 2 ]] && { ui_step_error "Option --tag requires a value"; return 1; }
                tag="$2"
                shift 2
                ;;
            --body)
                [[ $# -lt 2 ]] && { ui_step_error "Option --body requires a value"; return 1; }
                body="$2"
                shift 2
                ;;
            --help|-h)
                printf 'Usage: revo pr <title> [--tag TAG] [--body BODY]\n\n'
                printf 'Creates pull requests across repos on non-main branches using gh CLI.\n'
                printf 'After all PRs are created, appends cross-reference links to each body.\n'
                return 0
                ;;
            -*)
                ui_step_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$title" ]]; then
                    title="$1"
                else
                    ui_step_error "Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$title" ]]; then
        ui_step_error "Usage: revo pr <title> [--tag TAG] [--body BODY]"
        return 1
    fi

    if ! command -v gh >/dev/null 2>&1; then
        ui_step_error "gh CLI not found. Install from https://cli.github.com/"
        return 1
    fi

    config_require_workspace || return 1

    ui_intro "Revo - Create PRs: $title"

    local repos
    repos=$(config_get_repos "$tag")

    if [[ -z "$repos" ]]; then
        ui_step_error "No repositories configured"
        ui_outro_cancel "Nothing to do"
        return 1
    fi

    # Parallel arrays to collect PR results (bash 3.2)
    local pr_paths=()
    local pr_urls=()
    local pr_numbers=()

    local default_body="$body"
    if [[ -z "$default_body" ]]; then
        default_body="Coordinated PR created by \`revo pr\`."
    fi

    local skip_count=0
    local fail_count=0

    # --- Pass 1: create PRs ---
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
        if [[ -z "$branch" ]] || [[ "$branch" == "main" ]] || [[ "$branch" == "master" ]]; then
            ui_step_done "Skipped (on main/master):" "$path"
            skip_count=$((skip_count + 1))
            continue
        fi

        # Skip if no commits ahead of upstream (push required first)
        git_ahead_behind "$full_path"
        local has_upstream=0
        if git -C "$full_path" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
            has_upstream=1
        fi

        if [[ $has_upstream -eq 1 ]] && [[ $GIT_AHEAD -eq 0 ]]; then
            ui_step_done "Skipped (no changes ahead of upstream):" "$path"
            skip_count=$((skip_count + 1))
            continue
        fi

        # Create PR via gh
        local pr_title="[revo] $title"
        local output
        if output=$(cd "$full_path" && gh pr create --title "$pr_title" --body "$default_body" 2>&1); then
            local url
            url=$(printf '%s' "$output" | grep -Eo 'https://github\.com/[^ ]+/pull/[0-9]+' | tail -1)
            if [[ -z "$url" ]]; then
                url="$output"
            fi
            pr_paths+=("$path")
            pr_urls+=("$url")
            local number
            number="${url##*/}"
            pr_numbers+=("$number")
            ui_step_done "Opened PR:" "$path → $url"
        else
            # Maybe a PR already exists
            local existing
            existing=$(cd "$full_path" && gh pr view --json url -q .url 2>/dev/null || true)
            if [[ -n "$existing" ]]; then
                pr_paths+=("$path")
                pr_urls+=("$existing")
                local number
                number="${existing##*/}"
                pr_numbers+=("$number")
                ui_step_done "Existing PR:" "$path → $existing"
            else
                ui_step_error "Failed: $path"
                ui_info "$(ui_dim "$output")"
                fail_count=$((fail_count + 1))
            fi
        fi
    done <<< "$repos"

    # --- Pass 2: append cross-references if >1 PR ---
    if [[ ${#pr_paths[@]} -gt 1 ]]; then
        ui_bar_line
        ui_step "Linking PRs with cross-references..."

        # Build cross-reference block
        local xref
        xref=$'\n\n---\n**Coordinated PRs (revo):**\n'
        local i
        for ((i = 0; i < ${#pr_paths[@]}; i++)); do
            xref+="- ${pr_paths[$i]}: ${pr_urls[$i]}"$'\n'
        done

        for ((i = 0; i < ${#pr_paths[@]}; i++)); do
            local repo_path="${pr_paths[$i]}"
            local pr_number="${pr_numbers[$i]}"
            local full_path="$REVO_REPOS_DIR/$repo_path"
            local combined_body="$default_body$xref"

            if (cd "$full_path" && gh pr edit "$pr_number" --body "$combined_body" >/dev/null 2>&1); then
                ui_step_done "Linked:" "$repo_path"
            else
                ui_step_error "Failed to link: $repo_path"
            fi
        done
    fi

    ui_bar_line

    if [[ $fail_count -eq 0 ]]; then
        local msg="Opened ${#pr_paths[@]} PR(s)"
        [[ $skip_count -gt 0 ]] && msg+=", $skip_count skipped"
        ui_outro "$msg"
    else
        ui_outro_cancel "${#pr_paths[@]} opened, $fail_count failed"
        return 1
    fi

    return 0
}

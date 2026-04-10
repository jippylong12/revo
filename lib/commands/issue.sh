#!/usr/bin/env bash
# Revo CLI - issue command
# List and create GitHub issues across workspace repos via the gh CLI.

cmd_issue() {
    local subcommand="${1:-}"
    [[ $# -gt 0 ]] && shift

    case "$subcommand" in
        list|ls)
            _issue_list "$@"
            ;;
        create|new)
            _issue_create "$@"
            ;;
        --help|-h|help|"")
            _issue_help
            return 0
            ;;
        *)
            ui_step_error "Unknown subcommand: $subcommand"
            _issue_help
            return 1
            ;;
    esac
}

_issue_help() {
    cat << 'EOF'
Usage: revo issue <subcommand> [options]

Subcommands:
  list                                    List issues across workspace repos
  create                                  Create issue(s) in workspace repos

revo issue list [options]
  --tag TAG                Filter repos by tag
  --state open|closed|all  Issue state (default: open)
  --label LABEL            Filter by label
  --limit N                Per-repo limit (default: 30)
  --json                   Emit a flat JSON array (one entry per issue,
                           with a "repo" field)

revo issue create (--repo NAME | --tag TAG) "TITLE" [options]
  --repo NAME              Target a single repo by path basename
  --tag TAG                Target every repo matching the tag (cross-references
                           all created issues in each body)
  --body BODY              Issue body (default: revo-generated stub)
  --label L,L              Comma-separated labels
  --assignee USER          GitHub username to assign
  --feature NAME           Append issue links to .revo/features/NAME.md and
                           reference the brief from each issue body
EOF
}

# --- list ----------------------------------------------------------------

_issue_list() {
    local tag=""
    local state="open"
    local label=""
    local limit="30"
    local as_json=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag) [[ $# -lt 2 ]] && { ui_step_error "Option --tag requires a value"; return 1; }; tag="$2"; shift 2 ;;
            --state) [[ $# -lt 2 ]] && { ui_step_error "Option --state requires a value"; return 1; }; state="$2"; shift 2 ;;
            --label) [[ $# -lt 2 ]] && { ui_step_error "Option --label requires a value"; return 1; }; label="$2"; shift 2 ;;
            --limit) [[ $# -lt 2 ]] && { ui_step_error "Option --limit requires a value"; return 1; }; limit="$2"; shift 2 ;;
            --json) as_json=1; shift ;;
            --help|-h) _issue_help; return 0 ;;
            *) ui_step_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if ! command -v gh >/dev/null 2>&1; then
        ui_step_error "gh CLI not found. Install from https://cli.github.com/"
        return 1
    fi

    config_require_workspace || return 1

    local repos
    repos=$(config_get_repos "$tag")
    if [[ -z "$repos" ]]; then
        if [[ $as_json -eq 1 ]]; then
            printf '[]\n'
            return 0
        fi
        ui_step_error "No repositories configured"
        return 1
    fi

    # Build the per-repo gh args once
    local gh_extra=()
    if [[ -n "$label" ]]; then
        gh_extra+=( --label "$label" )
    fi

    if [[ $as_json -eq 1 ]]; then
        _issue_list_json "$repos" "$state" "$limit" "${gh_extra[@]}"
        return $?
    fi

    _issue_list_human "$repos" "$state" "$limit" "${gh_extra[@]}"
}

# Print a flat JSON array of issues across all repos. Each entry has a
# "repo" field added in addition to the gh-provided fields. Output goes to
# stdout, errors are silent (we want callers like Claude to be able to
# pipe into jq).
_issue_list_json() {
    local repos="$1"
    local state="$2"
    local limit="$3"
    shift 3
    local gh_extra=( "$@" )

    local entries=""
    local first=1

    local repo
    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        local path
        path=$(yaml_get_path "$repo")
        local full_path="$REVO_REPOS_DIR/$path"
        [[ ! -d "$full_path" ]] && continue

        # gh's --jq runs the embedded jq engine and emits one compact JSON
        # value per line by default. We map each issue, prepend a "repo"
        # field, and stream the results into our concatenated array.
        local lines
        if lines=$(cd "$full_path" && gh issue list \
            --state "$state" --limit "$limit" "${gh_extra[@]}" \
            --json number,title,state,labels,assignees,url,updatedAt,author \
            --jq ".[] | {repo: \"$path\"} + ." 2>/dev/null); then
            local line
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                if [[ $first -eq 1 ]]; then
                    entries="$line"
                    first=0
                else
                    entries="$entries,$line"
                fi
            done <<< "$lines"
        fi
    done <<< "$repos"

    printf '[%s]\n' "$entries"
    return 0
}

# Print a human-readable per-repo summary of issues. Each repo gets its
# own block separated by ui_bar_line.
_issue_list_human() {
    local repos="$1"
    local state="$2"
    local limit="$3"
    shift 3
    local gh_extra=( "$@" )

    ui_intro "Revo - Issues ($state)"

    local total=0
    local repo_count=0
    local skip_count=0

    local repo
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

        ui_bar_line
        ui_step "$path"

        local count_output
        if ! count_output=$(cd "$full_path" && gh issue list \
            --state "$state" --limit "$limit" "${gh_extra[@]}" \
            --json number --jq 'length' 2>&1); then
            ui_step_error "Failed: $count_output"
            continue
        fi

        local repo_total="${count_output:-0}"
        if [[ "$repo_total" == "0" ]]; then
            printf '%s  %s\n' "$(ui_bar)" "$(ui_dim "No $state issues")"
            continue
        fi

        local pretty
        if pretty=$(cd "$full_path" && gh issue list \
            --state "$state" --limit "$limit" "${gh_extra[@]}" 2>&1); then
            local line
            while IFS= read -r line; do
                printf '%s  %s\n' "$(ui_bar)" "$line"
            done <<< "$pretty"
        fi

        total=$((total + repo_total))
        repo_count=$((repo_count + 1))
    done <<< "$repos"

    ui_bar_line
    local msg="Found $total issue(s) across $repo_count repo(s)"
    [[ $skip_count -gt 0 ]] && msg+=", $skip_count skipped"
    ui_outro "$msg"
    return 0
}

# --- create --------------------------------------------------------------

_issue_create() {
    local title=""
    local repo=""
    local tag=""
    local body=""
    local labels=""
    local assignee=""
    local feature=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) [[ $# -lt 2 ]] && { ui_step_error "Option --repo requires a value"; return 1; }; repo="$2"; shift 2 ;;
            --tag) [[ $# -lt 2 ]] && { ui_step_error "Option --tag requires a value"; return 1; }; tag="$2"; shift 2 ;;
            --body) [[ $# -lt 2 ]] && { ui_step_error "Option --body requires a value"; return 1; }; body="$2"; shift 2 ;;
            --label) [[ $# -lt 2 ]] && { ui_step_error "Option --label requires a value"; return 1; }; labels="$2"; shift 2 ;;
            --assignee) [[ $# -lt 2 ]] && { ui_step_error "Option --assignee requires a value"; return 1; }; assignee="$2"; shift 2 ;;
            --feature) [[ $# -lt 2 ]] && { ui_step_error "Option --feature requires a value"; return 1; }; feature="$2"; shift 2 ;;
            --help|-h) _issue_help; return 0 ;;
            -*) ui_step_error "Unknown option: $1"; return 1 ;;
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
        ui_step_error "Usage: revo issue create (--repo NAME | --tag TAG) \"TITLE\""
        return 1
    fi

    if [[ -z "$repo" ]] && [[ -z "$tag" ]]; then
        ui_step_error "Either --repo or --tag is required"
        return 1
    fi

    if [[ -n "$repo" ]] && [[ -n "$tag" ]]; then
        ui_step_error "Use either --repo or --tag, not both"
        return 1
    fi

    if ! command -v gh >/dev/null 2>&1; then
        ui_step_error "gh CLI not found. Install from https://cli.github.com/"
        return 1
    fi

    config_require_workspace || return 1

    # Resolve target repo paths
    local target_paths=()
    if [[ -n "$repo" ]]; then
        local idx
        idx=$(yaml_find_by_name "$repo")
        if [[ $idx -lt 0 ]]; then
            ui_step_error "Repo not found in revo.yaml: $repo"
            return 1
        fi
        target_paths+=("$repo")
    else
        local repos
        repos=$(config_get_repos "$tag")
        local r
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            local p
            p=$(yaml_get_path "$r")
            target_paths+=("$p")
        done <<< "$repos"
    fi

    if [[ ${#target_paths[@]} -eq 0 ]]; then
        ui_step_error "No matching repos"
        return 1
    fi

    ui_intro "Revo - Create issue: $title"

    # Validate feature brief if --feature was given
    local feature_brief=""
    if [[ -n "$feature" ]]; then
        feature_brief="$REVO_WORKSPACE_ROOT/.revo/features/$feature.md"
        if [[ ! -f "$feature_brief" ]]; then
            ui_step_error "Feature brief not found: .revo/features/$feature.md"
            ui_info "$(ui_dim "Run 'revo feature $feature' first to create it")"
            return 1
        fi
    fi

    # Build the initial body that all created issues share
    local effective_body="$body"
    if [[ -z "$effective_body" ]]; then
        effective_body="Created by \`revo issue create\`."
    fi
    if [[ -n "$feature" ]]; then
        effective_body="$effective_body"$'\n\n'"Part of feature: \`$feature\` (see \`.revo/features/$feature.md\`)"
    fi

    # --- Pass 1: create issues -------------------------------------------
    local issue_paths=()
    local issue_urls=()
    local issue_numbers=()
    local fail_count=0
    local skip_count=0

    local p
    for p in "${target_paths[@]}"; do
        local full_path="$REVO_REPOS_DIR/$p"

        if [[ ! -d "$full_path" ]]; then
            ui_step_done "Skipped (not cloned):" "$p"
            skip_count=$((skip_count + 1))
            continue
        fi

        local gh_args=( --title "$title" --body "$effective_body" )
        if [[ -n "$labels" ]]; then
            gh_args+=( --label "$labels" )
        fi
        if [[ -n "$assignee" ]]; then
            gh_args+=( --assignee "$assignee" )
        fi

        local output
        if output=$(cd "$full_path" && gh issue create "${gh_args[@]}" 2>&1); then
            local url
            url=$(printf '%s' "$output" | grep -Eo 'https://github\.com/[^ ]+/issues/[0-9]+' | tail -1)
            if [[ -z "$url" ]]; then
                url="$output"
            fi
            local number="${url##*/}"
            issue_paths+=("$p")
            issue_urls+=("$url")
            issue_numbers+=("$number")
            ui_step_done "Created:" "$p → $url"
        else
            ui_step_error "Failed: $p"
            ui_info "$(ui_dim "$output")"
            fail_count=$((fail_count + 1))
        fi
    done

    # --- Pass 2: cross-references ----------------------------------------
    if [[ ${#issue_paths[@]} -gt 1 ]]; then
        ui_bar_line
        ui_step "Linking issues with cross-references..."

        local xref
        xref=$'\n\n---\n**Coordinated issues (revo):**\n'
        local i
        for ((i = 0; i < ${#issue_paths[@]}; i++)); do
            xref+="- ${issue_paths[$i]}: ${issue_urls[$i]}"$'\n'
        done

        for ((i = 0; i < ${#issue_paths[@]}; i++)); do
            local repo_path="${issue_paths[$i]}"
            local issue_number="${issue_numbers[$i]}"
            local full_path="$REVO_REPOS_DIR/$repo_path"
            local combined_body="$effective_body$xref"

            if (cd "$full_path" && gh issue edit "$issue_number" --body "$combined_body" >/dev/null 2>&1); then
                ui_step_done "Linked:" "$repo_path"
            else
                ui_step_error "Failed to link: $repo_path"
            fi
        done
    fi

    # --- Pass 3: append to feature brief ---------------------------------
    if [[ -n "$feature_brief" ]] && [[ ${#issue_paths[@]} -gt 0 ]]; then
        ui_bar_line
        ui_step "Appending to feature brief: $feature"
        {
            printf '\n## Issues (created by revo)\n\n'
            local i
            for ((i = 0; i < ${#issue_paths[@]}; i++)); do
                printf -- '- **%s**: %s\n' "${issue_paths[$i]}" "${issue_urls[$i]}"
            done
        } >> "$feature_brief"
        ui_step_done "Updated:" ".revo/features/$feature.md"
    fi

    ui_bar_line

    # Print URLs to stdout (LLM-friendly: one URL per line, parseable)
    local i
    for ((i = 0; i < ${#issue_urls[@]}; i++)); do
        printf '%s\n' "${issue_urls[$i]}"
    done

    if [[ $fail_count -eq 0 ]]; then
        local msg="Created ${#issue_paths[@]} issue(s)"
        [[ $skip_count -gt 0 ]] && msg+=", $skip_count skipped"
        ui_outro "$msg"
        return 0
    else
        ui_outro_cancel "${#issue_paths[@]} created, $fail_count failed"
        return 1
    fi
}

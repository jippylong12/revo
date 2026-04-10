#!/usr/bin/env bash
# Revo CLI - Configuration Management
# Handles workspace detection and config loading/saving

REVO_WORKSPACE_ROOT=""
REVO_CONFIG_FILE=""
REVO_REPOS_DIR=""
# When invoked from inside .revo/workspaces/<name>/, REVO_REPOS_DIR is
# overridden to point at that workspace dir so existing commands (status,
# commit, push, pr, exec, ...) operate on the workspace's copies of the
# repos rather than the source tree under repos/. REVO_ACTIVE_WORKSPACE
# holds the workspace name in that case (empty otherwise).
REVO_ACTIVE_WORKSPACE=""

# Find workspace root by searching upward for revo.yaml (or mars.yaml as fallback)
# Usage: config_find_root [start_dir]
# Returns: 0 if found (sets REVO_WORKSPACE_ROOT), 1 if not found
config_find_root() {
    local start_dir="${1:-$PWD}"
    local current="$start_dir"

    while [[ "$current" != "/" ]]; do
        if [[ -f "$current/revo.yaml" ]]; then
            REVO_WORKSPACE_ROOT="$current"
            REVO_CONFIG_FILE="$current/revo.yaml"
            REVO_REPOS_DIR="$current/repos"
            _config_apply_workspace_override "$start_dir"
            return 0
        fi
        # Fallback: support mars.yaml for migration from Mars
        if [[ -f "$current/mars.yaml" ]]; then
            REVO_WORKSPACE_ROOT="$current"
            REVO_CONFIG_FILE="$current/mars.yaml"
            REVO_REPOS_DIR="$current/repos"
            _config_apply_workspace_override "$start_dir"
            return 0
        fi
        current="$(dirname "$current")"
    done

    return 1
}

# If start_dir is inside .revo/workspaces/<name>/, point REVO_REPOS_DIR at
# that workspace and remember the active workspace name. Otherwise leave
# things alone. Called from config_find_root after the root has been set.
_config_apply_workspace_override() {
    local start_dir="$1"
    REVO_ACTIVE_WORKSPACE=""

    [[ -z "$REVO_WORKSPACE_ROOT" ]] && return 0

    local prefix="$REVO_WORKSPACE_ROOT/.revo/workspaces/"
    case "$start_dir/" in
        "$prefix"*)
            local rest="${start_dir#"$prefix"}"
            local ws_name="${rest%%/*}"
            if [[ -n "$ws_name" ]] && [[ -d "$prefix$ws_name" ]]; then
                REVO_REPOS_DIR="$prefix$ws_name"
                REVO_ACTIVE_WORKSPACE="$ws_name"
            fi
            ;;
    esac
    return 0
}

# Always returns the source repos dir ($REVO_WORKSPACE_ROOT/repos),
# regardless of any active workspace override. Used by `revo workspace`
# itself, which must read from the source tree even when invoked from
# inside another workspace.
config_source_repos_dir() {
    printf '%s/repos' "$REVO_WORKSPACE_ROOT"
}

# Initialize workspace in current directory
# Usage: config_init "workspace_name"
# Returns: 0 on success, 1 if already initialized
config_init() {
    local workspace_name="$1"
    local dir="${2:-$PWD}"

    if [[ -f "$dir/revo.yaml" ]] || [[ -f "$dir/mars.yaml" ]]; then
        return 1
    fi

    REVO_WORKSPACE_ROOT="$dir"
    REVO_CONFIG_FILE="$dir/revo.yaml"
    REVO_REPOS_DIR="$dir/repos"

    # Set workspace name for yaml module
    YAML_WORKSPACE_NAME="$workspace_name"
    YAML_DEFAULTS_BRANCH="main"
    YAML_REPO_COUNT=0
    YAML_REPO_URLS=()
    YAML_REPO_PATHS=()
    YAML_REPO_TAGS=()
    YAML_REPO_DEPS=()
    YAML_REPO_BRANCHES=()

    # Create directory structure
    mkdir -p "$REVO_REPOS_DIR"

    # Write config
    yaml_write "$REVO_CONFIG_FILE"

    # Merge revo's required entries into .gitignore without clobbering
    # any existing user entries.
    config_ensure_gitignore "$dir/.gitignore"

    return 0
}

# Ensure the given .gitignore contains the entries revo needs
# (`repos/` and `.revo/`). Existing content is preserved; only missing
# entries are appended. Creates the file if it doesn't exist.
# Usage: config_ensure_gitignore "/path/to/.gitignore"
config_ensure_gitignore() {
    local gitignore="$1"
    local needed
    needed=$(printf 'repos/\n.revo/\n')

    if [[ ! -f "$gitignore" ]]; then
        printf '%s\n' "$needed" > "$gitignore"
        return 0
    fi

    # Append only the entries that aren't already present (exact line match,
    # ignoring leading/trailing whitespace and comments).
    local entry has_entry needs_newline=0
    # If the file is non-empty and doesn't end in a newline, we need to add
    # one before appending so we don't merge into an existing line.
    if [[ -s "$gitignore" ]] && [[ -n "$(tail -c1 "$gitignore" 2>/dev/null)" ]]; then
        needs_newline=1
    fi

    local appended=0
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        has_entry=$(awk -v e="$entry" '
            { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
            $0 == e { found = 1; exit }
            END { exit !found }
        ' "$gitignore" && printf 'yes' || printf 'no')
        if [[ "$has_entry" == "no" ]]; then
            if [[ $appended -eq 0 ]] && [[ $needs_newline -eq 1 ]]; then
                printf '\n' >> "$gitignore"
            fi
            printf '%s\n' "$entry" >> "$gitignore"
            appended=1
        fi
    done <<< "$needed"

    return 0
}

# Load configuration
# Usage: config_load
# Returns: 0 on success, 1 on failure
config_load() {
    if [[ -z "$REVO_CONFIG_FILE" ]] || [[ ! -f "$REVO_CONFIG_FILE" ]]; then
        return 1
    fi

    if ! yaml_parse "$REVO_CONFIG_FILE"; then
        return 1
    fi
}

# Save configuration
# Usage: config_save
config_save() {
    if [[ -z "$REVO_CONFIG_FILE" ]]; then
        return 1
    fi

    yaml_write "$REVO_CONFIG_FILE"
}

# Get repos (optionally filtered by tag)
# Usage: repos=$(config_get_repos [tag])
config_get_repos() {
    local tag="${1:-}"
    yaml_get_repos "$tag"
}

# Get repo count
# Usage: count=$(config_repo_count [tag])
config_repo_count() {
    local tag="${1:-}"
    local count=0
    local repos
    repos=$(config_get_repos "$tag")

    while IFS= read -r repo; do
        [[ -n "$repo" ]] && count=$((count + 1))
    done <<< "$repos"

    printf '%d' "$count"
}

# Check if repo directory exists
# Usage: if config_repo_exists "repo_index"; then ...
config_repo_exists() {
    local idx="$1"
    local path
    path=$(yaml_get_path "$idx")
    [[ -d "$REVO_REPOS_DIR/$path" ]]
}

# Get full path to repo
# Usage: full_path=$(config_repo_full_path "repo_index")
config_repo_full_path() {
    local idx="$1"
    local path
    path=$(yaml_get_path "$idx")
    printf '%s/%s' "$REVO_REPOS_DIR" "$path"
}

# Require workspace context
# Usage: config_require_workspace || return 1
# Prints error and returns 1 if not in workspace
config_require_workspace() {
    if ! config_find_root; then
        printf 'Error: Not in a Revo workspace. Run "revo init" first.\n' >&2
        return 1
    fi
    config_load
}

# Check if path is inside workspace
# Usage: if config_is_in_workspace "/some/path"; then ...
config_is_in_workspace() {
    local path="$1"
    [[ "$path" == "$REVO_WORKSPACE_ROOT"* ]]
}

# Get workspace name
config_workspace_name() {
    printf '%s' "$YAML_WORKSPACE_NAME"
}

# Get workspace default branch
config_default_branch() {
    printf '%s' "$YAML_DEFAULTS_BRANCH"
}

# Get effective default branch for a specific repo
# Falls back to workspace default if no per-repo branch is set
# Usage: branch=$(config_repo_default_branch "repo_index")
config_repo_default_branch() {
    local idx="$1"
    local branch
    branch=$(yaml_get_branch "$idx")
    if [[ -n "$branch" ]]; then
        printf '%s' "$branch"
    else
        printf '%s' "$YAML_DEFAULTS_BRANCH"
    fi
}

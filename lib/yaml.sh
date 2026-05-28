#!/usr/bin/env bash
# Revo CLI - Minimal YAML Parser
# Parses revo.yaml (and legacy mars.yaml) format only - not a general YAML parser
# Compatible with bash 3.2+ (no associative arrays)

# Global state - using parallel indexed arrays instead of associative arrays
YAML_WORKSPACE_NAME=""
YAML_DEFAULTS_BRANCH=""
YAML_REPO_COUNT=0

# Arrays indexed by repo number (0, 1, 2, ...)
# Access: ${YAML_REPO_URLS[$i]}
YAML_REPO_URLS=()
YAML_REPO_PATHS=()
YAML_REPO_TAGS=()
YAML_REPO_DEPS=()
YAML_REPO_BRANCHES=()
YAML_REPO_DB_TYPES=()
YAML_REPO_DB_NAMES=()
YAML_REPO_TYPES=()
YAML_REPO_DESCRIPTIONS=()

_yaml_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

_yaml_parse_scalar() {
    local value
    value=$(_yaml_trim "$1")

    case "$value" in
        \"*)
            if [[ ! "$value" =~ ^\"(([^\"\\]|\\.)*)\"[[:space:]]*(#.*)?$ ]]; then
                return 1
            fi
            value="${BASH_REMATCH[1]}"
            value="${value//\\\"/\"}"
            value="${value//\\\\/\\}"
            ;;
        \'*)
            if [[ ! "$value" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
                return 1
            fi
            value="${BASH_REMATCH[1]}"
            value="${value//\'\'/\'}"
            ;;
        *)
            # Minimal YAML comment support for unquoted scalars.
            value="${value%% #*}"
            value=$(_yaml_trim "$value")
            ;;
    esac

    printf '%s' "$value"
}

_yaml_escape_double_quoted() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

_yaml_parse_inline_list() {
    local value
    value=$(_yaml_trim "$1")
    if [[ "$value" == *"] #"* ]]; then
        value="${value%%] #*}]"
    fi

    [[ "$value" == \[*\] ]] || return 1

    value="${value#\[}"
    value="${value%\]}"
    value=$(_yaml_trim "$value")

    if [[ -z "$value" ]]; then
        printf ''
        return 0
    fi

    local old_ifs="$IFS"
    local parts=()
    IFS=','
    read -r -a parts <<< "$value"
    IFS="$old_ifs"

    local item parsed result=""
    for item in "${parts[@]}"; do
        parsed=$(_yaml_parse_scalar "$item") || return 1
        if [[ -z "$parsed" ]] || [[ ! "$parsed" =~ ^[A-Za-z0-9._/-]+$ ]]; then
            return 1
        fi
        if [[ -z "$result" ]]; then
            result="$parsed"
        else
            result="$result,$parsed"
        fi
    done

    printf '%s' "$result"
}

yaml_parse() {
    local file="$1"
    local line
    local in_repos=0
    local in_defaults=0
    local in_database=0
    local current_index=-1

    # Reset state
    YAML_WORKSPACE_NAME=""
    YAML_DEFAULTS_BRANCH="main"
    YAML_REPO_COUNT=0
    YAML_REPO_URLS=()
    YAML_REPO_PATHS=()
    YAML_REPO_TAGS=()
    YAML_REPO_DEPS=()
    YAML_REPO_BRANCHES=()
    YAML_REPO_DB_TYPES=()
    YAML_REPO_DB_NAMES=()
    YAML_REPO_TYPES=()
    YAML_REPO_DESCRIPTIONS=()

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Remove leading/trailing whitespace for comparison
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

        # Check section markers
        if [[ "$trimmed" == "repos:" ]]; then
            in_repos=1
            in_defaults=0
            continue
        elif [[ "$trimmed" == "defaults:" ]]; then
            in_repos=0
            in_defaults=1
            continue
        elif [[ "$trimmed" == "workspace:" ]]; then
            in_repos=0
            in_defaults=0
            continue
        fi

        # Parse workspace name (only outside repos/defaults sections)
        if [[ $in_repos -eq 0 ]] && [[ $in_defaults -eq 0 ]] && [[ "$trimmed" =~ ^name:[[:space:]]*(.*)$ ]]; then
            local workspace_name
            if ! workspace_name=$(_yaml_parse_scalar "${BASH_REMATCH[1]}"); then
                printf 'Error: invalid workspace name\n' >&2
                return 1
            fi
            YAML_WORKSPACE_NAME="$workspace_name"
            continue
        fi

        # Parse defaults section
        if [[ $in_defaults -eq 1 ]]; then
            if [[ "$trimmed" =~ ^branch:[[:space:]]*(.+)$ ]]; then
                local default_branch
                if ! default_branch=$(_yaml_parse_scalar "${BASH_REMATCH[1]}"); then
                    printf 'Error: invalid defaults branch\n' >&2
                    return 1
                fi
                YAML_DEFAULTS_BRANCH="$default_branch"
            fi
            continue
        fi

        # Parse repos section
        if [[ $in_repos -eq 1 ]]; then
            # New repo entry (starts with -)
            if [[ "$trimmed" =~ ^-[[:space:]]*url:[[:space:]]*(.+)$ ]]; then
                current_index=$((current_index + 1))
                local url
                if ! url=$(_yaml_parse_scalar "${BASH_REMATCH[1]}"); then
                    printf 'Error: invalid repo url\n' >&2
                    return 1
                fi
                YAML_REPO_URLS[$current_index]="$url"
                YAML_REPO_PATHS[$current_index]=$(yaml_path_from_url "$url")
                YAML_REPO_TAGS[$current_index]=""
                YAML_REPO_DEPS[$current_index]=""
                YAML_REPO_BRANCHES[$current_index]=""
                YAML_REPO_DB_TYPES[$current_index]=""
                YAML_REPO_DB_NAMES[$current_index]=""
                YAML_REPO_TYPES[$current_index]=""
                YAML_REPO_DESCRIPTIONS[$current_index]=""
                in_database=0
                YAML_REPO_COUNT=$((YAML_REPO_COUNT + 1))
                continue
            fi

            # Continuation of current repo
            if [[ $current_index -ge 0 ]]; then
                if [[ "$trimmed" =~ ^path:[[:space:]]*(.+)$ ]]; then
                    local path_val
                    if ! path_val=$(_yaml_parse_scalar "${BASH_REMATCH[1]}"); then
                        printf 'Error: invalid repo path scalar\n' >&2
                        return 1
                    fi
                    YAML_REPO_PATHS[$current_index]="$path_val"
                elif [[ "$trimmed" =~ ^tags:[[:space:]]*(.*)$ ]]; then
                    local tags_str
                    if ! tags_str=$(_yaml_parse_inline_list "${trimmed#tags:}"); then
                        printf 'Error: invalid tags list for %s\n' "${YAML_REPO_URLS[$current_index]}" >&2
                        return 1
                    fi
                    YAML_REPO_TAGS[$current_index]="$tags_str"
                elif [[ "$trimmed" =~ ^depends_on:[[:space:]]*(.*)$ ]]; then
                    local deps_str
                    if ! deps_str=$(_yaml_parse_inline_list "${trimmed#depends_on:}"); then
                        printf 'Error: invalid depends_on list for %s\n' "${YAML_REPO_URLS[$current_index]}" >&2
                        return 1
                    fi
                    YAML_REPO_DEPS[$current_index]="$deps_str"
                elif [[ "$trimmed" =~ ^branch:[[:space:]]*(.+)$ ]]; then
                    local branch_val
                    if ! branch_val=$(_yaml_parse_scalar "${BASH_REMATCH[1]}"); then
                        printf 'Error: invalid repo branch for %s\n' "${YAML_REPO_URLS[$current_index]}" >&2
                        return 1
                    fi
                    YAML_REPO_BRANCHES[$current_index]="$branch_val"
                elif [[ $in_database -eq 0 ]] && [[ "$trimmed" =~ ^type:[[:space:]]*(.+)$ ]]; then
                    local type_val
                    if ! type_val=$(_yaml_parse_scalar "${BASH_REMATCH[1]}"); then
                        printf 'Error: invalid repo type for %s\n' "${YAML_REPO_URLS[$current_index]}" >&2
                        return 1
                    fi
                    YAML_REPO_TYPES[$current_index]="$type_val"
                elif [[ $in_database -eq 0 ]] && [[ "$trimmed" =~ ^description:[[:space:]]*(.*) ]]; then
                    local desc
                    if ! desc=$(_yaml_parse_scalar "${BASH_REMATCH[1]}"); then
                        printf 'Error: invalid repo description for %s\n' "${YAML_REPO_URLS[$current_index]}" >&2
                        return 1
                    fi
                    YAML_REPO_DESCRIPTIONS[$current_index]="$desc"
                elif [[ "$trimmed" == "database:" ]]; then
                    in_database=1
                elif [[ $in_database -eq 1 ]] && [[ "$trimmed" =~ ^type:[[:space:]]*(.+)$ ]]; then
                    local db_type_val
                    if ! db_type_val=$(_yaml_parse_scalar "${BASH_REMATCH[1]}"); then
                        printf 'Warning: invalid database type scalar, ignoring\n' >&2
                        continue
                    fi
                    case "$db_type_val" in
                        postgres|mongodb|mysql)
                            YAML_REPO_DB_TYPES[$current_index]="$db_type_val"
                            ;;
                        *)
                            printf 'Warning: unsupported database type "%s", ignoring\n' "$db_type_val" >&2
                            ;;
                    esac
                elif [[ $in_database -eq 1 ]] && [[ "$trimmed" =~ ^name:[[:space:]]*(.+)$ ]]; then
                    local db_name_val
                    if ! db_name_val=$(_yaml_parse_scalar "${BASH_REMATCH[1]}"); then
                        printf 'Warning: invalid database name scalar, ignoring\n' >&2
                        continue
                    fi
                    if [[ "$db_name_val" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                        YAML_REPO_DB_NAMES[$current_index]="$db_name_val"
                    else
                        printf 'Warning: invalid database name "%s", ignoring\n' "$db_name_val" >&2
                    fi
                fi
            fi
        fi
    done < "$file"

    local i j
    for ((i = 0; i < YAML_REPO_COUNT; i++)); do
        if ! yaml_validate_repo_path "${YAML_REPO_PATHS[$i]}"; then
            printf 'Error: invalid repo path for %s: %s\n' "${YAML_REPO_URLS[$i]}" "${YAML_REPO_PATHS[$i]}" >&2
            return 1
        fi
        for ((j = 0; j < i; j++)); do
            if [[ "${YAML_REPO_PATHS[$i]}" == "${YAML_REPO_PATHS[$j]}" ]]; then
                printf 'Error: duplicate repo path: %s\n' "${YAML_REPO_PATHS[$i]}" >&2
                return 1
            fi
        done
    done

    return 0
}

# Validate repo paths before they are joined under repos/ or .revo/workspaces/.
# Paths are relative POSIX-style paths; traversal, absolute paths, empty
# components, and shell-hostile characters are rejected.
yaml_validate_repo_path() {
    local path="$1"

    [[ -z "$path" ]] && return 1
    [[ "$path" == /* ]] && return 1
    [[ "$path" == */ ]] && return 1
    [[ "$path" == *"//"* ]] && return 1
    [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1

    local old_ifs="$IFS"
    local part
    IFS='/'
    for part in $path; do
        if [[ -z "$part" ]] || [[ "$part" == "." ]] || [[ "$part" == ".." ]]; then
            IFS="$old_ifs"
            return 1
        fi
    done
    IFS="$old_ifs"

    return 0
}

# Extract repo name from URL
# Usage: yaml_path_from_url "git@github.com:org/repo.git"
# Returns: "repo"
yaml_path_from_url() {
    local url="$1"
    local name

    # Handle SSH URLs: git@github.com:org/repo.git
    if [[ "$url" =~ ([^/:]+)\.git$ ]]; then
        name="${BASH_REMATCH[1]}"
    # Handle HTTPS URLs: https://github.com/org/repo.git
    elif [[ "$url" =~ /([^/]+)\.git$ ]]; then
        name="${BASH_REMATCH[1]}"
    # Handle URLs without .git
    elif [[ "$url" =~ ([^/:]+)$ ]]; then
        name="${BASH_REMATCH[1]}"
    else
        name="repo"
    fi

    printf '%s' "$name"
}

# Get list of repo indices, optionally filtered by tag
# Usage: yaml_get_repos [tag]
# Returns: newline-separated list of indices (0, 1, 2, ...)
yaml_get_repos() {
    local filter_tag="${1:-}"
    local i

    for ((i = 0; i < YAML_REPO_COUNT; i++)); do
        if [[ -z "$filter_tag" ]]; then
            printf '%d\n' "$i"
        else
            local tags="${YAML_REPO_TAGS[$i]}"
            # Check if tag is in comma-separated list
            if [[ ",$tags," == *",$filter_tag,"* ]]; then
                printf '%d\n' "$i"
            fi
        fi
    done
}

# Get repo URL by index
yaml_get_url() {
    local idx="$1"
    printf '%s' "${YAML_REPO_URLS[$idx]:-}"
}

# Get repo path by index
yaml_get_path() {
    local idx="$1"
    printf '%s' "${YAML_REPO_PATHS[$idx]:-}"
}

# Get repo tags by index
yaml_get_tags() {
    local idx="$1"
    printf '%s' "${YAML_REPO_TAGS[$idx]:-}"
}

# Get repo depends_on list by index (comma-separated names)
yaml_get_deps() {
    local idx="$1"
    printf '%s' "${YAML_REPO_DEPS[$idx]:-}"
}

# Get repo default branch by index (empty means use workspace default)
yaml_get_branch() {
    local idx="$1"
    printf '%s' "${YAML_REPO_BRANCHES[$idx]:-}"
}

# Get repo type by index (frontend, backend, shared, mobile, infra, or empty)
yaml_get_type() {
    local idx="$1"
    printf '%s' "${YAML_REPO_TYPES[$idx]:-}"
}

# Get repo description by index
yaml_get_description() {
    local idx="$1"
    printf '%s' "${YAML_REPO_DESCRIPTIONS[$idx]:-}"
}

# Get repo database type by index (postgres, mongodb, mysql, or empty)
yaml_get_db_type() {
    local idx="$1"
    printf '%s' "${YAML_REPO_DB_TYPES[$idx]:-}"
}

# Get repo database name by index
yaml_get_db_name() {
    local idx="$1"
    printf '%s' "${YAML_REPO_DB_NAMES[$idx]:-}"
}

# Find repo index by name (path basename)
# Usage: idx=$(yaml_find_by_name "backend")
# Returns: index or -1 if not found
yaml_find_by_name() {
    local name="$1"
    local i
    for ((i = 0; i < YAML_REPO_COUNT; i++)); do
        if [[ "${YAML_REPO_PATHS[$i]}" == "$name" ]]; then
            printf '%d' "$i"
            return 0
        fi
    done
    printf '%d' -1
    return 1
}

# Write revo.yaml
# Usage: yaml_write "path/to/revo.yaml"
yaml_write() {
    local file="$1"
    local i

    {
        printf 'version: 1\n\n'
        printf 'workspace:\n'
        local escaped_workspace
        escaped_workspace=$(_yaml_escape_double_quoted "$YAML_WORKSPACE_NAME")
        printf '  name: "%s"\n\n' "$escaped_workspace"
        printf 'repos:\n'

        for ((i = 0; i < YAML_REPO_COUNT; i++)); do
            local url="${YAML_REPO_URLS[$i]}"
            local path="${YAML_REPO_PATHS[$i]}"
            local tags="${YAML_REPO_TAGS[$i]}"
            local deps="${YAML_REPO_DEPS[$i]:-}"
            local branch="${YAML_REPO_BRANCHES[$i]:-}"

            printf '  - url: %s\n' "$url"

            # Only write path if different from derived
            local derived
            derived=$(yaml_path_from_url "$url")
            if [[ "$path" != "$derived" ]]; then
                printf '    path: %s\n' "$path"
            fi

            # Write tags if present
            if [[ -n "$tags" ]]; then
                printf '    tags: [%s]\n' "$tags"
            fi

            # Write type if present (quoted for safety)
            local type="${YAML_REPO_TYPES[$i]:-}"
            if [[ -n "$type" ]]; then
                type=$(_yaml_escape_double_quoted "$type")
                printf '    type: "%s"\n' "$type"
            fi

            # Write description if present (escape embedded quotes)
            local desc="${YAML_REPO_DESCRIPTIONS[$i]:-}"
            if [[ -n "$desc" ]]; then
                desc=$(_yaml_escape_double_quoted "$desc")
                printf '    description: "%s"\n' "$desc"
            fi

            # Write depends_on if present
            if [[ -n "$deps" ]]; then
                printf '    depends_on: [%s]\n' "$deps"
            fi

            # Write branch if it differs from the workspace default
            if [[ -n "$branch" ]] && [[ "$branch" != "$YAML_DEFAULTS_BRANCH" ]]; then
                printf '    branch: %s\n' "$branch"
            fi

            # Write database if present
            local db_type="${YAML_REPO_DB_TYPES[$i]:-}"
            local db_name="${YAML_REPO_DB_NAMES[$i]:-}"
            if [[ -n "$db_type" ]] && [[ -n "$db_name" ]]; then
                printf '    database:\n'
                printf '      type: %s\n' "$db_type"
                printf '      name: %s\n' "$db_name"
            fi
        done

        printf '\ndefaults:\n'
        printf '  branch: %s\n' "$YAML_DEFAULTS_BRANCH"
    } > "$file"
}

# Add a repo to the config
# Usage: yaml_add_repo "url" "path" "tags" "deps" ["branch" ["db_type" "db_name" ["type" "description"]]]
yaml_add_repo() {
    local url="$1"
    local path="${2:-}"
    local tags="${3:-}"
    local deps="${4:-}"
    local branch="${5:-}"
    local db_type="${6:-}"
    local db_name="${7:-}"
    local type="${8:-}"
    local description="${9:-}"

    local idx=$YAML_REPO_COUNT

    YAML_REPO_URLS[$idx]="$url"

    if [[ -z "$path" ]]; then
        path=$(yaml_path_from_url "$url")
    fi
    YAML_REPO_PATHS[$idx]="$path"
    YAML_REPO_TAGS[$idx]="$tags"
    YAML_REPO_DEPS[$idx]="$deps"
    YAML_REPO_BRANCHES[$idx]="$branch"
    YAML_REPO_DB_TYPES[$idx]="$db_type"
    YAML_REPO_DB_NAMES[$idx]="$db_name"
    YAML_REPO_TYPES[$idx]="$type"
    YAML_REPO_DESCRIPTIONS[$idx]="$description"

    YAML_REPO_COUNT=$((YAML_REPO_COUNT + 1))
}

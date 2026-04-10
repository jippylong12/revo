#!/usr/bin/env bash
# Revo CLI - Repo Scanner
# Detects language, framework, routes, and metadata per repo.
# Uses globals to avoid subshells (bash 3.2 compatibility).

SCAN_NAME=""
SCAN_LANG=""
SCAN_FRAMEWORK=""
SCAN_ROUTES=""
SCAN_DESCRIPTION=""
SCAN_HAS_CLAUDE_MD=0
SCAN_HAS_DOCKER=0

# Reset all SCAN_* globals
scan_reset() {
    SCAN_NAME=""
    SCAN_LANG=""
    SCAN_FRAMEWORK=""
    SCAN_ROUTES=""
    SCAN_DESCRIPTION=""
    SCAN_HAS_CLAUDE_MD=0
    SCAN_HAS_DOCKER=0
}

# Extract a top-level JSON string value from a file.
# Usage: val=$(_scan_json_string "path/to/file.json" "name")
# Handles simple cases only; no nested objects.
_scan_json_string() {
    local file="$1"
    local key="$2"
    local line
    # Match: "key": "value"  (value may contain escaped chars but no quotes)
    line=$(grep -m1 -E "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null || true)
    [[ -z "$line" ]] && return 1
    # Strip to the value
    line="${line#*\"$key\"}"
    line="${line#*:}"
    line="${line#*\"}"
    line="${line%%\"*}"
    printf '%s' "$line"
}

# Returns 0 if the package.json has "dep_name" anywhere in a dependencies block
_scan_pkg_has_dep() {
    local file="$1"
    local dep="$2"
    grep -q "\"$dep\"[[:space:]]*:" "$file" 2>/dev/null
}

# Detect framework from package.json dependencies
_scan_node_framework() {
    local file="$1"
    if _scan_pkg_has_dep "$file" "next"; then
        printf 'Next.js'
    elif _scan_pkg_has_dep "$file" "nuxt"; then
        printf 'Nuxt'
    elif _scan_pkg_has_dep "$file" "@remix-run/react"; then
        printf 'Remix'
    elif _scan_pkg_has_dep "$file" "@sveltejs/kit"; then
        printf 'SvelteKit'
    elif _scan_pkg_has_dep "$file" "astro"; then
        printf 'Astro'
    elif _scan_pkg_has_dep "$file" "vite"; then
        printf 'Vite'
    elif _scan_pkg_has_dep "$file" "nestjs" || _scan_pkg_has_dep "$file" "@nestjs/core"; then
        printf 'NestJS'
    elif _scan_pkg_has_dep "$file" "fastify"; then
        printf 'Fastify'
    elif _scan_pkg_has_dep "$file" "express"; then
        printf 'Express'
    elif _scan_pkg_has_dep "$file" "hono"; then
        printf 'Hono'
    elif _scan_pkg_has_dep "$file" "react"; then
        printf 'React'
    elif _scan_pkg_has_dep "$file" "vue"; then
        printf 'Vue'
    elif _scan_pkg_has_dep "$file" "svelte"; then
        printf 'Svelte'
    fi
}

# Detect framework from Python dependency files
_scan_python_framework() {
    local repo_dir="$1"
    local files=()
    [[ -f "$repo_dir/requirements.txt" ]] && files+=("$repo_dir/requirements.txt")
    [[ -f "$repo_dir/pyproject.toml" ]] && files+=("$repo_dir/pyproject.toml")
    [[ -f "$repo_dir/Pipfile" ]] && files+=("$repo_dir/Pipfile")

    [[ ${#files[@]} -eq 0 ]] && return

    if grep -qiE '(^|[^a-z])django([^a-z]|$)' "${files[@]}" 2>/dev/null; then
        printf 'Django'
    elif grep -qiE '(^|[^a-z])fastapi([^a-z]|$)' "${files[@]}" 2>/dev/null; then
        printf 'FastAPI'
    elif grep -qiE '(^|[^a-z])flask([^a-z]|$)' "${files[@]}" 2>/dev/null; then
        printf 'Flask'
    elif grep -qiE '(^|[^a-z])starlette([^a-z]|$)' "${files[@]}" 2>/dev/null; then
        printf 'Starlette'
    fi
}

# List route files in common route directories.
# Returns comma-separated list (max 6 files, basename only).
_scan_list_routes() {
    local repo_dir="$1"
    local dirs=(
        "src/routes"
        "src/api"
        "src/controllers"
        "app/api"
        "app/routes"
        "routes"
        "api"
        "pages/api"
    )

    local found=()
    local dir
    for dir in "${dirs[@]}"; do
        local full="$repo_dir/$dir"
        [[ ! -d "$full" ]] && continue

        # Find code files (not tests), max depth 2
        local file
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            [[ "$file" == *".test."* ]] && continue
            [[ "$file" == *".spec."* ]] && continue
            found+=("$(basename "$file")")
            # Cap the number of results
            [[ ${#found[@]} -ge 6 ]] && break
        done < <(find "$full" -maxdepth 2 -type f \( -name "*.ts" -o -name "*.js" -o -name "*.tsx" -o -name "*.jsx" -o -name "*.py" -o -name "*.go" -o -name "*.rs" \) 2>/dev/null | sort)

        [[ ${#found[@]} -ge 6 ]] && break
    done

    # Join as comma-separated
    local result=""
    local f
    for f in "${found[@]}"; do
        if [[ -z "$result" ]]; then
            result="$f"
        else
            result="$result, $f"
        fi
    done
    printf '%s' "$result"
}

# First non-empty, non-heading line of README.md (trimmed, first 100 chars)
_scan_readme_description() {
    local readme="$1"
    [[ ! -f "$readme" ]] && return

    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty/whitespace
        [[ -z "${line// }" ]] && continue
        # Skip heading lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip HTML tags (often used for logos/badges at the top)
        [[ "$line" =~ ^[[:space:]]*\< ]] && continue
        # Skip badge lines
        [[ "$line" =~ ^[[:space:]]*\[!\[ ]] && continue

        # Trim
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Cap length
        if [[ ${#line} -gt 100 ]]; then
            line="${line:0:100}..."
        fi
        printf '%s' "$line"
        return 0
    done < "$readme"
}

# Scan a repository directory and populate SCAN_* globals.
# Usage: scan_repo "/path/to/repo"
scan_repo() {
    local repo_dir="$1"
    scan_reset

    [[ ! -d "$repo_dir" ]] && return 1

    # Node.js
    if [[ -f "$repo_dir/package.json" ]]; then
        SCAN_LANG="Node.js"
        SCAN_NAME=$(_scan_json_string "$repo_dir/package.json" "name" || true)
        SCAN_FRAMEWORK=$(_scan_node_framework "$repo_dir/package.json")
    fi

    # Python
    if [[ -z "$SCAN_LANG" ]] && { [[ -f "$repo_dir/pyproject.toml" ]] || [[ -f "$repo_dir/requirements.txt" ]] || [[ -f "$repo_dir/Pipfile" ]]; }; then
        SCAN_LANG="Python"
        if [[ -f "$repo_dir/pyproject.toml" ]]; then
            local pyname
            pyname=$(grep -m1 -E '^[[:space:]]*name[[:space:]]*=' "$repo_dir/pyproject.toml" 2>/dev/null | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' || true)
            [[ -n "$pyname" ]] && SCAN_NAME="$pyname"
        fi
        SCAN_FRAMEWORK=$(_scan_python_framework "$repo_dir")
    fi

    # Go
    if [[ -z "$SCAN_LANG" ]] && [[ -f "$repo_dir/go.mod" ]]; then
        SCAN_LANG="Go"
        SCAN_NAME=$(grep -m1 '^module ' "$repo_dir/go.mod" 2>/dev/null | awk '{print $2}' || true)
    fi

    # Rust
    if [[ -z "$SCAN_LANG" ]] && [[ -f "$repo_dir/Cargo.toml" ]]; then
        SCAN_LANG="Rust"
        SCAN_NAME=$(grep -m1 -E '^[[:space:]]*name[[:space:]]*=' "$repo_dir/Cargo.toml" 2>/dev/null | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' || true)
    fi

    # Routes
    SCAN_ROUTES=$(_scan_list_routes "$repo_dir")

    # README description
    if [[ -f "$repo_dir/README.md" ]]; then
        SCAN_DESCRIPTION=$(_scan_readme_description "$repo_dir/README.md")
    elif [[ -f "$repo_dir/readme.md" ]]; then
        SCAN_DESCRIPTION=$(_scan_readme_description "$repo_dir/readme.md")
    fi

    # CLAUDE.md
    if [[ -f "$repo_dir/CLAUDE.md" ]]; then
        SCAN_HAS_CLAUDE_MD=1
    fi

    # Docker
    if [[ -f "$repo_dir/Dockerfile" ]] || [[ -f "$repo_dir/docker-compose.yml" ]] || [[ -f "$repo_dir/docker-compose.yaml" ]] || [[ -f "$repo_dir/compose.yml" ]] || [[ -f "$repo_dir/compose.yaml" ]]; then
        SCAN_HAS_DOCKER=1
    fi

    return 0
}

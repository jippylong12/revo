#!/usr/bin/env bash
# Test suite for workspace helpers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/ui.sh"
source "$SCRIPT_DIR/../lib/commands/workspace.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

test_start() {
    printf "Testing: %s... " "$1"
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_pass() {
    printf "PASS\n"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    printf "FAIL: %s\n" "$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

mk_workspace_copy_fixture() {
    local root="/tmp/revo/workspace_test_$$_$1"
    rm -rf "$root"
    mkdir -p "$root/src/app" "$root/src/node_modules/pkg" "$root/src/packages/api/node_modules/pkg"
    mkdir -p "$root/src/.next/cache" "$root/src/target/debug" "$root/src/.git"
    mkdir -p "$root/src/dist" "$root/src/build" "$root/src/coverage" "$root/src/packages/api/.turbo"
    printf 'console.log("ok")\n' > "$root/src/app/index.js"
    printf 'module\n' > "$root/src/node_modules/pkg/index.js"
    printf 'nested\n' > "$root/src/packages/api/node_modules/pkg/index.js"
    printf 'cache\n' > "$root/src/.next/cache/file"
    printf 'target\n' > "$root/src/target/debug/file"
    printf 'bundle\n' > "$root/src/dist/app.js"
    printf 'build\n' > "$root/src/build/app.js"
    printf 'coverage\n' > "$root/src/coverage/report.txt"
    printf 'turbo\n' > "$root/src/packages/api/.turbo/cache"
    printf '%s' "$root"
}

test_workspace_copy_skips_dependency_dirs() {
    test_start "_workspace_copy_repo - skips dependency/cache/build dirs"

    local root
    root=$(mk_workspace_copy_fixture "skip_deps")
    local src="$root/src"
    local dest="$root/dest"

    _workspace_copy_repo "$src" "$dest" || {
        rm -rf "$root"
        test_fail "copy failed"
        return 1
    }

    if [[ ! -f "$dest/app/index.js" ]]; then
        rm -rf "$root"
        test_fail "app file was not copied"
        return 1
    fi

    if [[ -e "$dest/node_modules" ]] || [[ -e "$dest/packages/api/node_modules" ]] \
        || [[ -e "$dest/.next" ]] || [[ -e "$dest/target" ]] \
        || [[ -e "$dest/dist" ]] || [[ -e "$dest/build" ]] \
        || [[ -e "$dest/coverage" ]] || [[ -e "$dest/packages/api/.turbo" ]]; then
        rm -rf "$root"
        test_fail "excluded dependency/cache/build dirs were copied"
        return 1
    fi

    rm -rf "$root"
    test_pass
}

test_workspace_fallback_prunes_before_copying_nested_dirs() {
    test_start "_workspace_copy_repo_fallback - prunes nested generated dirs"

    local root
    root=$(mk_workspace_copy_fixture "fallback_prune")
    local src="$root/src"
    local dest="$root/dest"

    _workspace_copy_repo_fallback "$src" "$dest" || {
        rm -rf "$root"
        test_fail "fallback copy failed"
        return 1
    }

    if [[ ! -f "$dest/app/index.js" ]]; then
        rm -rf "$root"
        test_fail "app file was not copied"
        return 1
    fi

    if [[ -e "$dest/packages/api/node_modules" ]] || [[ -e "$dest/packages/api/.turbo" ]]; then
        rm -rf "$root"
        test_fail "nested generated dirs were copied"
        return 1
    fi

    rm -rf "$root"
    test_pass
}

test_workspace_copy_prunes_external_symlinks() {
    test_start "_workspace_copy_repo - prunes symlinks that escape source"

    local root
    root=$(mk_workspace_copy_fixture "symlink")
    local src="$root/src"
    local dest="$root/dest"
    local external="$root/outside_secret.txt"
    printf 'do-not-copy-this-secret\n' > "$external"
    ln -s "$external" "$src/external_secret"

    _workspace_copy_repo "$src" "$dest" || {
        rm -rf "$root"
        test_fail "copy failed"
        return 1
    }

    if [[ -L "$dest/external_secret" ]] || [[ -e "$dest/external_secret" ]]; then
        rm -rf "$root"
        test_fail "external symlink was copied"
        return 1
    fi

    if grep -R "do-not-copy-this-secret" "$dest" >/dev/null 2>&1; then
        rm -rf "$root"
        test_fail "external symlink target content was materialized"
        return 1
    fi

    rm -rf "$root"
    test_pass
}

test_workspace_delete_rejects_empty_sanitized_name() {
    test_start "_workspace_delete - rejects names that sanitize to empty"

    local root="/tmp/revo/workspace_test_$$_empty_delete"
    rm -rf "$root"
    mkdir -p "$root/.revo/workspaces/keep"

    REVO_WORKSPACE_ROOT="$root"

    if _workspace_delete "!!!" 0 >/dev/null 2>&1; then
        rm -rf "$root"
        test_fail "delete accepted empty sanitized name"
        return 1
    fi

    if [[ ! -d "$root/.revo/workspaces/keep" ]]; then
        rm -rf "$root"
        test_fail "workspace root was removed"
        return 1
    fi

    rm -rf "$root"
    test_pass
}

test_workspace_gitignore_guard() {
    test_start "_workspace_verify_gitignore_safe - accepts whitespace-padded .revo/"

    local root="/tmp/revo/workspace_test_$$_gitignore_guard"
    rm -rf "$root"
    mkdir -p "$root/.git"
    printf '  .revo/  \n' > "$root/.gitignore"
    REVO_WORKSPACE_ROOT="$root"

    if _workspace_verify_gitignore_safe; then
        test_pass
    else
        rm -rf "$root"
        test_fail "whitespace-padded .revo/ was not accepted"
        return 1
    fi

    test_start "_workspace_verify_gitignore_safe - rejects commented-only .revo/"
    printf '# .revo/\n' > "$root/.gitignore"
    if _workspace_verify_gitignore_safe; then
        rm -rf "$root"
        test_fail "commented .revo/ was accepted"
        return 1
    fi

    rm -rf "$root"
    test_pass
}

printf "\n=== Workspace Tests ===\n\n"

test_workspace_copy_skips_dependency_dirs
test_workspace_fallback_prunes_before_copying_nested_dirs
test_workspace_copy_prunes_external_symlinks
test_workspace_delete_rejects_empty_sanitized_name
test_workspace_gitignore_guard

printf "\n=== Results ===\n"
printf "Passed: %d/%d\n" "$TESTS_PASSED" "$TESTS_RUN"

if [[ $TESTS_FAILED -gt 0 ]]; then
    printf "Failed: %d\n" "$TESTS_FAILED"
    exit 1
fi

exit 0

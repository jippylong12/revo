#!/usr/bin/env bash
# Test suite for workspace helpers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    printf 'console.log("ok")\n' > "$root/src/app/index.js"
    printf 'module\n' > "$root/src/node_modules/pkg/index.js"
    printf 'nested\n' > "$root/src/packages/api/node_modules/pkg/index.js"
    printf 'cache\n' > "$root/src/.next/cache/file"
    printf 'target\n' > "$root/src/target/debug/file"
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
        || [[ -e "$dest/.next" ]] || [[ -e "$dest/target" ]]; then
        rm -rf "$root"
        test_fail "excluded dependency/cache/build dirs were copied"
        return 1
    fi

    rm -rf "$root"
    test_pass
}

printf "\n=== Workspace Tests ===\n\n"

test_workspace_copy_skips_dependency_dirs

printf "\n=== Results ===\n"
printf "Passed: %d/%d\n" "$TESTS_PASSED" "$TESTS_RUN"

if [[ $TESTS_FAILED -gt 0 ]]; then
    printf "Failed: %d\n" "$TESTS_FAILED"
    exit 1
fi

exit 0

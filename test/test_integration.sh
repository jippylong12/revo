#!/usr/bin/env bash
# Integration tests for Revo CLI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVO_CMD="bash $SCRIPT_DIR/../revo"
ORIG_DIR="$PWD"

# Test workspace directory
TEST_DIR=""

# Test helpers
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

cleanup() {
    cd "$ORIG_DIR" 2>/dev/null || true
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

trap cleanup EXIT

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

setup_test_dir() {
    cleanup
    TEST_DIR="/tmp/revo/revo_integ_$$_$RANDOM"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
}

# --- Tests ---

test_help() {
    test_start "revo --help"

    local output
    output=$($REVO_CMD --help 2>&1) || true
    if echo "$output" | grep -q "Claude-first multi-repo workspace manager"; then
        test_pass
    else
        test_fail "help output missing expected text"
    fi
}

test_version() {
    test_start "revo --version"

    local output
    output=$($REVO_CMD --version 2>&1) || true
    if echo "$output" | grep -q "^Revo v"; then
        test_pass
    else
        test_fail "version output format incorrect"
    fi
}

test_init_creates_files() {
    test_start "revo init - creates expected files"

    setup_test_dir

    # Run init with stdin to answer prompts
    echo "test-workspace" | $REVO_CMD init > /dev/null 2>&1

    if [[ -f "revo.yaml" ]] && [[ -f ".gitignore" ]] && [[ -d "repos" ]]; then
        test_pass
    else
        test_fail "missing expected files/directories"
    fi
}

test_add_repo() {
    test_start "revo add - adds repository to config"

    setup_test_dir
    echo "add-test" | $REVO_CMD init > /dev/null 2>&1

    $REVO_CMD add "git@github.com:test/repo.git" --tags "test,demo" > /dev/null 2>&1

    if grep -q "git@github.com:test/repo.git" revo.yaml; then
        test_pass
    else
        test_fail "repo not found in revo.yaml"
    fi
}

test_add_with_depends_on() {
    test_start "revo add - depends_on flag"

    setup_test_dir
    echo "deps-test" | $REVO_CMD init > /dev/null 2>&1

    $REVO_CMD add "git@github.com:test/shared.git" > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/backend.git" --depends-on "shared" > /dev/null 2>&1

    if grep -q "depends_on: \[shared\]" revo.yaml; then
        test_pass
    else
        test_fail "depends_on not persisted to revo.yaml"
    fi
}

test_list_repos() {
    test_start "revo list - shows configured repos"

    setup_test_dir
    echo "list-test" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/repo1.git" > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/repo2.git" > /dev/null 2>&1

    local output
    output=$($REVO_CMD list 2>&1)

    if echo "$output" | grep -q "repo1" && echo "$output" | grep -q "repo2"; then
        test_pass
    else
        test_fail "repos not listed"
    fi
}

test_status_not_cloned() {
    test_start "revo status - shows not cloned"

    setup_test_dir
    echo "status-test" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/repo.git" > /dev/null 2>&1

    local output
    output=$($REVO_CMD status 2>&1)

    if echo "$output" | grep -q "not cloned"; then
        test_pass
    else
        test_fail "should show 'not cloned' status"
    fi
}

test_context_generates_claude_md() {
    test_start "revo context - writes CLAUDE.md with dep order"

    setup_test_dir
    echo "ctx-test" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/shared.git" > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/backend.git" --depends-on "shared" > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/frontend.git" --depends-on "backend" > /dev/null 2>&1

    $REVO_CMD context > /dev/null 2>&1

    if [[ ! -f "CLAUDE.md" ]]; then
        test_fail "CLAUDE.md not created"
        return 1
    fi

    # Check for expected sections and order
    if grep -q "## Repos" CLAUDE.md && grep -q "## Dependency Order" CLAUDE.md; then
        # Verify shared comes before backend which comes before frontend
        local shared_line backend_line frontend_line
        shared_line=$(grep -n "1\. \*\*shared\*\*" CLAUDE.md | head -1 | cut -d: -f1)
        backend_line=$(grep -n "2\. \*\*backend\*\*" CLAUDE.md | head -1 | cut -d: -f1)
        frontend_line=$(grep -n "3\. \*\*frontend\*\*" CLAUDE.md | head -1 | cut -d: -f1)
        if [[ -n "$shared_line" ]] && [[ -n "$backend_line" ]] && [[ -n "$frontend_line" ]]; then
            test_pass
        else
            test_fail "dependency order incorrect in CLAUDE.md"
        fi
    else
        test_fail "CLAUDE.md missing expected sections"
    fi
}

test_feature_creates_file() {
    test_start "revo feature - writes .revo/features file"

    setup_test_dir
    echo "feat-test" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/repo.git" > /dev/null 2>&1

    # Will fail to create branch (not cloned) but should still write context file
    $REVO_CMD feature my-feature > /dev/null 2>&1 || true

    if [[ -f ".revo/features/my-feature.md" ]]; then
        if grep -q "# Feature: my-feature" ".revo/features/my-feature.md"; then
            test_pass
        else
            test_fail "feature file missing header"
        fi
    else
        test_fail "feature file not created"
    fi
}

test_clone_with_real_repo() {
    test_start "revo clone - clones real repository"

    setup_test_dir
    echo "clone-test" | $REVO_CMD init > /dev/null 2>&1

    # Use a small, public repo for testing
    $REVO_CMD add "https://github.com/octocat/Hello-World.git" > /dev/null 2>&1

    if $REVO_CMD clone 2>&1 | grep -q "Cloned"; then
        if [[ -d "repos/Hello-World/.git" ]]; then
            test_pass
        else
            test_fail "repo directory not created"
        fi
    else
        test_fail "clone command failed"
    fi
}

test_exec_command() {
    test_start "revo exec - runs command in repos"

    setup_test_dir
    echo "exec-test" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "https://github.com/octocat/Hello-World.git" > /dev/null 2>&1
    $REVO_CMD clone > /dev/null 2>&1

    local output
    output=$($REVO_CMD exec "git log -1 --oneline" 2>&1)

    if echo "$output" | grep -q "Success"; then
        test_pass
    else
        test_fail "exec should show success"
    fi
}

test_tag_filtering() {
    test_start "revo --tag filtering"

    setup_test_dir
    echo "tag-test" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/frontend.git" --tags "frontend" > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/backend.git" --tags "backend" > /dev/null 2>&1

    local output
    output=$($REVO_CMD list --tag frontend 2>&1)

    if echo "$output" | grep -q "frontend" && ! echo "$output" | grep -q "backend"; then
        test_pass
    else
        test_fail "tag filtering not working correctly"
    fi
}

test_mars_yaml_fallback() {
    test_start "revo finds mars.yaml fallback"

    setup_test_dir
    cat > mars.yaml << 'EOF'
version: 1
workspace:
  name: legacy
repos:
  - url: git@github.com:test/legacy.git
    tags: [legacy]
defaults:
  branch: main
EOF
    mkdir -p repos

    local output
    output=$($REVO_CMD list 2>&1)

    if echo "$output" | grep -q "legacy"; then
        test_pass
    else
        test_fail "did not fall back to mars.yaml"
    fi
}

# --- Run tests ---

printf "\n=== Revo CLI Integration Tests ===\n\n"

# Basic tests (no network)
test_help
test_version
test_init_creates_files
test_add_repo
test_add_with_depends_on
test_list_repos
test_status_not_cloned
test_tag_filtering
test_mars_yaml_fallback
test_context_generates_claude_md
test_feature_creates_file

# Network tests (optional - skip if offline)
if ping -c 1 github.com &> /dev/null; then
    printf "\n--- Network Tests ---\n\n"
    test_clone_with_real_repo
    test_exec_command
else
    printf "\n--- Skipping network tests (no connectivity) ---\n"
fi

printf "\n=== Results ===\n"
printf "Passed: %d/%d\n" "$TESTS_PASSED" "$TESTS_RUN"

if [[ $TESTS_FAILED -gt 0 ]]; then
    printf "Failed: %d\n" "$TESTS_FAILED"
    exit 1
fi

exit 0

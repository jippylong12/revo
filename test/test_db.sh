#!/usr/bin/env bash
# Test suite for db.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/db.sh"

# Test helpers
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

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        test_fail "expected '$expected', got '$actual' ${msg}"
        return 1
    fi
}

# --- Tests ---

test_sanitize_ws_suffix() {
    test_start "_db_sanitize_ws_suffix - basic"
    local result
    result=$(_db_sanitize_ws_suffix "my-feature")
    assert_eq "my_feature" "$result" && test_pass

    test_start "_db_sanitize_ws_suffix - uppercase"
    result=$(_db_sanitize_ws_suffix "My-Feature")
    assert_eq "my_feature" "$result" && test_pass

    test_start "_db_sanitize_ws_suffix - special chars stripped"
    result=$(_db_sanitize_ws_suffix "feat@#\$123")
    assert_eq "feat123" "$result" && test_pass

    test_start "_db_sanitize_ws_suffix - spaces removed"
    result=$(_db_sanitize_ws_suffix "my feature")
    assert_eq "myfeature" "$result" && test_pass
}

test_workspace_name() {
    test_start "_db_workspace_name - basic"
    local result
    result=$(_db_workspace_name "myapp_dev" "my-feature")
    assert_eq "myapp_dev_ws_my_feature" "$result" && test_pass

    test_start "_db_workspace_name - preserves source name"
    result=$(_db_workspace_name "prod_db" "fix-auth")
    assert_eq "prod_db_ws_fix_auth" "$result" && test_pass

    test_start "_db_workspace_name - truncates at 63 chars"
    result=$(_db_workspace_name "very_long_database_name_that_goes_on" "extremely-long-workspace-name-here")
    if [[ ${#result} -le 63 ]]; then
        test_pass
    else
        test_fail "length ${#result} exceeds 63"
    fi
}

test_validate_name() {
    test_start "_db_validate_name - valid name"
    if _db_validate_name "myapp_dev"; then
        test_pass
    else
        test_fail "$DB_ERROR"
    fi

    test_start "_db_validate_name - valid with hyphens"
    if _db_validate_name "my-app-dev"; then
        test_pass
    else
        test_fail "$DB_ERROR"
    fi

    test_start "_db_validate_name - rejects empty"
    if _db_validate_name ""; then
        test_fail "should have rejected empty name"
    else
        test_pass
    fi

    test_start "_db_validate_name - rejects injection attempt"
    if _db_validate_name "test'; DROP TABLE users; --"; then
        test_fail "should have rejected injection"
    else
        test_pass
    fi

    test_start "_db_validate_name - rejects spaces"
    if _db_validate_name "my database"; then
        test_fail "should have rejected spaces"
    else
        test_pass
    fi

    test_start "_db_validate_name - rejects too long"
    local long_name
    long_name=$(printf '%0.s_' {1..64})
    if _db_validate_name "$long_name"; then
        test_fail "should have rejected >63 chars"
    else
        test_pass
    fi
}

test_drop_safety_guard() {
    test_start "_db_drop - rejects name without _ws_ marker"
    if _db_drop "postgres" "myapp_dev" 2>/dev/null; then
        test_fail "should have refused to drop"
    else
        assert_eq "Refusing to drop 'myapp_dev': name does not contain _ws_ (safety guard)" "$DB_ERROR" && test_pass
    fi

    test_start "_db_drop - rejects plain name with injection"
    if _db_drop "postgres" "production" 2>/dev/null; then
        test_fail "should have refused to drop"
    else
        test_pass
    fi
}

test_check_tool_unsupported() {
    test_start "_db_check_tool - rejects unsupported type"
    if _db_check_tool "sqlite"; then
        test_fail "should have rejected sqlite"
    else
        assert_eq "Unsupported database type: sqlite" "$DB_ERROR" && test_pass
    fi
}

test_ws_name_contains_marker() {
    test_start "_db_workspace_name always contains _ws_"
    local result
    result=$(_db_workspace_name "db" "feat")
    if [[ "$result" == *"_ws_"* ]]; then
        test_pass
    else
        test_fail "result '$result' missing _ws_ marker"
    fi
}

# --- Run tests ---

printf "\n=== Database Module Tests ===\n\n"

test_sanitize_ws_suffix
test_workspace_name
test_validate_name
test_drop_safety_guard
test_check_tool_unsupported
test_ws_name_contains_marker

printf "\n=== Results ===\n"
printf "Passed: %d/%d\n" "$TESTS_PASSED" "$TESTS_RUN"

if [[ $TESTS_FAILED -gt 0 ]]; then
    printf "Failed: %d\n" "$TESTS_FAILED"
    exit 1
fi

exit 0

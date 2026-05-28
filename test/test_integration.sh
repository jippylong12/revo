#!/usr/bin/env bash
# Integration tests for Revo CLI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVO_CMD="bash $SCRIPT_DIR/../revo"
ORIG_DIR="$PWD"

source "$SCRIPT_DIR/../lib/git.sh"

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

setup_local_git_repo() {
    local repo_dir="$1"
    mkdir -p "$repo_dir"
    git -C "$repo_dir" init > /dev/null 2>&1
    git -C "$repo_dir" config user.email "revo-test@example.com"
    git -C "$repo_dir" config user.name "Revo Test"
    printf 'initial\n' > "$repo_dir/README.md"
    git -C "$repo_dir" add README.md > /dev/null 2>&1
    git -C "$repo_dir" commit -m "initial" > /dev/null 2>&1
    git -C "$repo_dir" branch -M main > /dev/null 2>&1
}

setup_fake_gh_issue_list() {
    local fakebin="$1"
    local log="$2"
    mkdir -p "$fakebin"
    cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "issue" ]] && [[ "${2:-}" == "list" ]]; then
    printf 'issue-list:%s:%s\n' "$PWD" "$*" >> "$FAKE_GH_LOG"
    repo=$(basename "$PWD")
    json=0
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json=1
    done
    if [[ $json -eq 1 ]]; then
        case "$repo" in
            api) printf '{"repo":"api","number":1,"title":"API issue"}\n' ;;
            web) printf '{"repo":"web","number":2,"title":"Web issue"}\n' ;;
        esac
    else
        case "$repo" in
            api) printf '1\tOPEN\tAPI issue\n' ;;
            web) printf '2\tOPEN\tWeb issue\n' ;;
        esac
    fi
    exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
    chmod +x "$fakebin/gh"
    : > "$log"
}

setup_fake_git_clone() {
    local fakebin="$1"
    local log="$2"
    mkdir -p "$fakebin"
    cat > "$fakebin/git" <<'EOF'
#!/usr/bin/env bash
printf 'git' >> "$FAKE_GIT_LOG"
for arg in "$@"; do
    printf ' <%s>' "$arg" >> "$FAKE_GIT_LOG"
done
printf '\n' >> "$FAKE_GIT_LOG"

if [[ "${1:-}" == "clone" ]]; then
    seen_separator=0
    target=""
    for arg in "$@"; do
        target="$arg"
        if [[ "$arg" == "--" ]]; then
            seen_separator=1
            continue
        fi
        if [[ $seen_separator -eq 0 && "$arg" == --upload-pack=* ]]; then
            printf 'option-like URL reached git before -- separator\n' >&2
            exit 64
        fi
    done
    mkdir -p "$target/.git"
    exit 0
fi

if [[ "${1:-}" == "-C" && "${3:-}" == "symbolic-ref" ]]; then
    exit 1
fi

if [[ "${1:-}" == "-C" && "${3:-}" == "rev-parse" && "${4:-}" == "--verify" ]]; then
    exit 1
fi

if [[ "${1:-}" == "-C" && "${3:-}" == "rev-parse" && "${4:-}" == "--abbrev-ref" ]]; then
    printf 'main\n'
    exit 0
fi

exit 1
EOF
    chmod +x "$fakebin/git"
    : > "$log"
}

# --- Tests ---

test_help() {
    test_start "revo --help"

    local output
    output=$($REVO_CMD --help 2>&1) || true
    if echo "$output" | grep -q "Agent-first multi-repo workspace manager"; then
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

    if [[ -f "revo.yaml" ]] && [[ -f ".gitignore" ]] && [[ -d "repos" ]] \
        && [[ -f "AGENTS.md" ]] && [[ -f "CLAUDE.md" ]] \
        && grep -q "files: \[AGENTS.md,CLAUDE.md\]" revo.yaml \
        && grep -q "provider: github" revo.yaml \
        && ! grep -q "revo exec" AGENTS.md CLAUDE.md; then
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

test_add_rejects_traversal_path() {
    test_start "revo add - rejects traversal repo path"

    setup_test_dir
    echo "path-guard-test" | $REVO_CMD init > /dev/null 2>&1

    local output
    if output=$($REVO_CMD add "git@github.com:test/repo.git" --path "../outside" 2>&1); then
        test_fail "accepted traversal repo path"
        return 1
    fi

    if echo "$output" | grep -q "Invalid repo path"; then
        test_pass
    else
        test_fail "missing invalid path error"
    fi
}

test_exec_command_unavailable() {
    test_start "revo exec - unavailable arbitrary shell surface"

    local output
    output=$($REVO_CMD exec true 2>&1) || true

    if echo "$output" | grep -q "Unknown command: exec"; then
        test_pass
    else
        test_fail "exec command should remain unavailable"
    fi
}

test_exec_surface_not_bundled() {
    test_start "build artifact - omits dead exec command surface"

    local root="$SCRIPT_DIR/.."
    if [[ -e "$root/lib/commands/exec.sh" ]]; then
        test_fail "deleted exec command file is still present"
        return 1
    fi

    if grep -q "lib/commands/exec.sh" "$root/build.sh"; then
        test_fail "build still bundles exec command file"
        return 1
    fi

    if grep -Eq 'cmd_exec|bash -c "\$command"' "$root/dist/revo"; then
        test_fail "dist still contains arbitrary exec command implementation"
        return 1
    fi

    test_pass
}

test_git_clone_helper_separates_option_like_url() {
    test_start "git_clone - passes option-like URL after --"

    setup_test_dir
    local fakebin="$TEST_DIR/fakebin-git-helper"
    local log="$TEST_DIR/git-helper.log"
    setup_fake_git_clone "$fakebin" "$log"

    local old_path="$PATH"
    export FAKE_GIT_LOG="$log"
    PATH="$fakebin:$PATH"

    if ! git_clone "--upload-pack=/tmp/revo-pwn" "$TEST_DIR/cloned-helper"; then
        PATH="$old_path"
        test_fail "git_clone failed: $GIT_ERROR"
        return 1
    fi

    PATH="$old_path"

    if grep -qF 'git <clone> <--progress> <--> <--upload-pack=/tmp/revo-pwn>' "$log"; then
        test_pass
    else
        test_fail "git_clone did not put -- before option-like URL"
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

test_status_reports_dirty_gitfile_worktree() {
    test_start "revo status - detects dirty gitfile worktree"

    setup_test_dir
    echo "gitfile-status" | $REVO_CMD init > /dev/null 2>&1
    setup_local_git_repo "$TEST_DIR/source"
    $REVO_CMD add "file://$TEST_DIR/source" --path app > /dev/null 2>&1

    git -C "$TEST_DIR/source" worktree add -b workspace-copy "$TEST_DIR/repos/app" > /dev/null 2>&1
    printf 'dirty\n' >> "$TEST_DIR/repos/app/README.md"

    local output
    output=$($REVO_CMD status 2>&1)

    if echo "$output" | grep -q "app" && echo "$output" | grep -q "dirty"; then
        test_pass
    else
        test_fail "dirty worktree with .git file was not reported"
    fi
}

test_status_reports_no_upstream() {
    test_start "revo status - reports no upstream"

    setup_test_dir
    echo "no-upstream-status" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/app.git" --path app > /dev/null 2>&1
    setup_local_git_repo "$TEST_DIR/repos/app"

    local output
    output=$($REVO_CMD status 2>&1)

    if echo "$output" | grep -q "no upstream"; then
        test_pass
    else
        test_fail "repo without upstream was reported as synced"
    fi
}

test_checkout_rejects_tag_name_without_branch() {
    test_start "revo checkout - does not treat tag as branch"

    setup_test_dir
    echo "checkout-tag" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/app.git" --path app > /dev/null 2>&1
    setup_local_git_repo "$TEST_DIR/repos/app"
    git -C "$TEST_DIR/repos/app" tag release > /dev/null 2>&1

    local output
    if output=$($REVO_CMD checkout release 2>&1); then
        test_fail "checkout accepted a tag without a branch"
        return 1
    fi

    local branch
    branch=$(git -C "$TEST_DIR/repos/app" rev-parse --abbrev-ref HEAD)
    if [[ "$branch" == "main" ]] && echo "$output" | grep -q "Branch not found"; then
        test_pass
    else
        test_fail "checkout detached or reported the wrong failure"
    fi
}

test_clone_refuses_hostile_config_path() {
    test_start "revo clone --force - refuses hostile config path"

    setup_test_dir
    echo "clone-path-guard" | $REVO_CMD init > /dev/null 2>&1
    printf 'keep\n' > outside-sentinel

    cat > revo.yaml << 'EOF'
version: 1
workspace:
  name: clone-path-guard
repos:
  - url: git@github.com:test/repo.git
    path: ../outside-sentinel
defaults:
  branch: main
EOF

    local output
    if output=$($REVO_CMD clone --force 2>&1); then
        test_fail "clone accepted hostile config path"
        return 1
    fi

    if [[ ! -f outside-sentinel ]]; then
        test_fail "sentinel outside repos was removed"
        return 1
    fi

    if echo "$output" | grep -q "invalid repo path"; then
        test_pass
    else
        test_fail "missing invalid path error"
    fi
}

test_clone_separates_option_like_url() {
    test_start "revo clone - passes option-like URL after --"

    setup_test_dir
    echo "clone-url-separator" | $REVO_CMD init > /dev/null 2>&1

    cat > revo.yaml << 'EOF'
version: 1
workspace:
  name: clone-url-separator
repos:
  - url: --upload-pack=/tmp/revo-pwn
    path: option-url
defaults:
  branch: main
EOF

    local fakebin="$TEST_DIR/fakebin-git-clone"
    local log="$TEST_DIR/git-clone.log"
    setup_fake_git_clone "$fakebin" "$log"

    local output
    if ! output=$(FAKE_GIT_LOG="$log" PATH="$fakebin:$PATH" $REVO_CMD clone 2>&1); then
        test_fail "clone failed with fake git: $output"
        return 1
    fi

    if grep -qF 'git <clone> <--quiet> <--> <--upload-pack=/tmp/revo-pwn>' "$log"; then
        test_pass
    else
        test_fail "clone did not put -- before option-like URL"
    fi
}

test_workspace_cleans_partial_repo_after_branch_failure() {
    test_start "revo workspace - cleans partial repo after branch failure"

    setup_test_dir
    echo "workspace-cleanup" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/app.git" --path app > /dev/null 2>&1
    mkdir -p repos/app
    printf 'source file\n' > repos/app/README.md

    local fakebin="$TEST_DIR/fakebin-workspace-git"
    mkdir -p "$fakebin"
    cat > "$fakebin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" && "${3:-}" == "rev-parse" && "${4:-}" == "--verify" ]]; then
    exit 1
fi
if [[ "${1:-}" == "-C" && "${3:-}" == "checkout" && "${4:-}" == "-b" ]]; then
    exit 1
fi
exit 1
EOF
    chmod +x "$fakebin/git"

    local output
    if output=$(PATH="$fakebin:$PATH" $REVO_CMD workspace fail-branch 2>&1); then
        test_fail "workspace unexpectedly succeeded"
        return 1
    fi

    if [[ -e ".revo/workspaces/fail-branch/app" ]] || [[ -e ".revo/workspaces/fail-branch" ]]; then
        test_fail "partial workspace copy remained after branch failure"
        return 1
    fi

    if echo "$output" | grep -q "Failed to create branch"; then
        test_pass
    else
        test_fail "missing branch failure output"
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

test_context_generates_configured_agent_files() {
    test_start "revo context - writes configured AGENTS.md and CLAUDE.md"

    setup_test_dir
    echo "agent-files" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/shared.git" > /dev/null 2>&1

    $REVO_CMD context --auto > /dev/null 2>&1

    if [[ -f "AGENTS.md" ]] && [[ -f "CLAUDE.md" ]] \
        && grep -q "Tracker Source Of Truth" AGENTS.md \
        && grep -q "Tracker Source Of Truth" CLAUDE.md \
        && grep -q "GitHub issues" AGENTS.md; then
        test_pass
    else
        test_fail "configured agent files missing expected tracker context"
    fi
}

test_context_legacy_config_defaults_to_claude_only() {
    test_start "revo context - legacy config writes CLAUDE.md only"

    setup_test_dir
    mkdir -p repos
    cat > revo.yaml << 'EOF'
version: 1
workspace:
  name: legacy-agent
repos:
  - url: git@github.com:test/shared.git
defaults:
  branch: main
EOF

    $REVO_CMD context --auto > /dev/null 2>&1

    if [[ -f "CLAUDE.md" ]] && [[ ! -f "AGENTS.md" ]] \
        && grep -q "GitHub issues" CLAUDE.md; then
        test_pass
    else
        test_fail "legacy config did not preserve CLAUDE-only default"
    fi
}

test_init_preserves_existing_claude_md() {
    test_start "revo init - preserves pre-existing CLAUDE.md"

    setup_test_dir

    # Pre-existing user CLAUDE.md
    printf '# My Project\n\nUser content that must survive.\n' > CLAUDE.md

    echo "preserve-test" | $REVO_CMD init > /dev/null 2>&1

    if ! grep -q "# My Project" CLAUDE.md; then
        test_fail "lost user heading"
        return 1
    fi
    if ! grep -q "User content that must survive" CLAUDE.md; then
        test_fail "lost user body content"
        return 1
    fi
    test_pass
}

test_init_preserves_existing_gitignore() {
    test_start "revo init - preserves pre-existing .gitignore entries"

    setup_test_dir

    printf 'node_modules/\n.env\ncoverage/\n' > .gitignore

    echo "gitignore-test" | $REVO_CMD init > /dev/null 2>&1

    # User entries preserved
    if ! grep -q "^node_modules/$" .gitignore; then
        test_fail "lost node_modules/"
        return 1
    fi
    if ! grep -q "^\.env$" .gitignore; then
        test_fail "lost .env"
        return 1
    fi
    if ! grep -q "^coverage/$" .gitignore; then
        test_fail "lost coverage/"
        return 1
    fi
    # Revo entries appended
    if ! grep -q "^repos/$" .gitignore; then
        test_fail "missing repos/"
        return 1
    fi
    if ! grep -q "^\.revo/$" .gitignore; then
        test_fail "missing .revo/"
        return 1
    fi
    test_pass
}

test_context_preserves_user_content() {
    test_start "revo context - preserves user content above and below auto block"

    setup_test_dir
    echo "ctx-preserve" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/shared.git" > /dev/null 2>&1

    # Generate the auto block once
    $REVO_CMD context > /dev/null 2>&1

    # Inject user content above and below the markers
    local tmp
    tmp=$(mktemp)
    {
        printf '# Pre-content above markers\n\n'
        cat CLAUDE.md
        printf '\n## Post-content below markers\n\nMore user notes.\n'
    } > "$tmp"
    mv "$tmp" CLAUDE.md

    # Regenerate
    $REVO_CMD context > /dev/null 2>&1

    if ! grep -q "# Pre-content above markers" CLAUDE.md; then
        test_fail "lost pre-content"
        return 1
    fi
    if ! grep -q "## Post-content below markers" CLAUDE.md; then
        test_fail "lost post-content heading"
        return 1
    fi
    if ! grep -q "More user notes" CLAUDE.md; then
        test_fail "lost post-content body"
        return 1
    fi
    # Auto block still present
    if ! grep -q "BEGIN revo:auto" CLAUDE.md; then
        test_fail "missing BEGIN marker after regeneration"
        return 1
    fi
    if ! grep -q "END revo:auto" CLAUDE.md; then
        test_fail "missing END marker after regeneration"
        return 1
    fi
    test_pass
}

test_context_preserves_agents_user_content() {
    test_start "revo context - preserves AGENTS.md user content"

    setup_test_dir
    echo "agents-preserve" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/shared.git" > /dev/null 2>&1

    $REVO_CMD context --auto > /dev/null 2>&1

    local tmp
    tmp=$(mktemp)
    {
        printf '# Agent pre-content\n\n'
        cat AGENTS.md
        printf '\n## Agent post-content\n\nAgent notes.\n'
    } > "$tmp"
    mv "$tmp" AGENTS.md

    $REVO_CMD context --auto > /dev/null 2>&1

    if grep -q "# Agent pre-content" AGENTS.md \
        && grep -q "## Agent post-content" AGENTS.md \
        && grep -q "Agent notes" AGENTS.md \
        && grep -q "BEGIN revo:auto" AGENTS.md \
        && grep -q "END revo:auto" AGENTS.md; then
        test_pass
    else
        test_fail "lost AGENTS.md user content or markers"
    fi
}

test_context_idempotent_no_duplication() {
    test_start "revo context - idempotent, no marker duplication"

    setup_test_dir
    echo "ctx-idem" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/shared.git" > /dev/null 2>&1

    $REVO_CMD context > /dev/null 2>&1
    $REVO_CMD context > /dev/null 2>&1
    $REVO_CMD context > /dev/null 2>&1

    local begin_count end_count
    begin_count=$(grep -c "BEGIN revo:auto" CLAUDE.md)
    end_count=$(grep -c "END revo:auto" CLAUDE.md)

    if [[ "$begin_count" != "1" ]]; then
        test_fail "expected 1 BEGIN marker, got $begin_count"
        return 1
    fi
    if [[ "$end_count" != "1" ]]; then
        test_fail "expected 1 END marker, got $end_count"
        return 1
    fi
    test_pass
}

test_context_does_not_emit_env_secret_values() {
    test_start "revo context - does not emit .env secret values"

    setup_test_dir
    echo "secret-context" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/api.git" > /dev/null 2>&1

    local config_tmp
    config_tmp=$(mktemp)
    awk '
        { print }
        /url: git@github.com:test\/api.git/ { print "    branch: main" }
    ' revo.yaml > "$config_tmp"
    mv "$config_tmp" revo.yaml

    mkdir -p repos/api
    printf '{"name":"api","description":"API service"}\n' > repos/api/package.json
    printf 'DATABASE_URL=postgres://secret_user:super_secret_password@localhost:5432/app_db\n' > repos/api/.env

    $REVO_CMD context > /dev/null 2>&1
    local analyze_output
    analyze_output=$($REVO_CMD context --analyze 2>&1)

    if grep -q "super_secret_password" CLAUDE.md .revo/COMMANDS.md 2>/dev/null \
        || echo "$analyze_output" | grep -q "super_secret_password"; then
        test_fail "generated context leaked env secret value"
        return 1
    fi

    if grep -q "Database (detected):.*app_db (postgres)" CLAUDE.md \
        && echo "$analyze_output" | grep -q "Database (detected):.*app_db (postgres)"; then
        test_pass
    else
        test_fail "generated context missing expected database structure"
    fi
}

test_issue_list_json_flat_array() {
    test_start "revo issue list --json - emits flat array across repos"

    setup_test_dir
    echo "issue-json" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/api.git" --path api > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/web.git" --path web > /dev/null 2>&1
    mkdir -p repos/api repos/web

    local fakebin="$TEST_DIR/fakebin"
    local log="$TEST_DIR/gh.log"
    setup_fake_gh_issue_list "$fakebin" "$log"

    local output
    output=$(FAKE_GH_LOG="$log" PATH="$fakebin:$PATH" $REVO_CMD issue list --json 2>&1)

    if [[ "$output" == '[{"repo":"api","number":1,"title":"API issue"},{"repo":"web","number":2,"title":"Web issue"}]' ]]; then
        test_pass
    else
        test_fail "unexpected JSON output: $output"
    fi
}

test_issue_list_human_calls_gh_once_per_repo() {
    test_start "revo issue list - calls gh once per repo"

    setup_test_dir
    echo "issue-human" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/api.git" --path api > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/web.git" --path web > /dev/null 2>&1
    mkdir -p repos/api repos/web

    local fakebin="$TEST_DIR/fakebin"
    local log="$TEST_DIR/gh.log"
    setup_fake_gh_issue_list "$fakebin" "$log"

    local output
    output=$(FAKE_GH_LOG="$log" PATH="$fakebin:$PATH" $REVO_CMD issue list 2>&1)

    local calls
    calls=$(grep -c '^issue-list:' "$log")
    if [[ "$calls" == "2" ]] && echo "$output" | grep -q "API issue" && echo "$output" | grep -q "Web issue"; then
        test_pass
    else
        test_fail "expected 2 gh calls and both issues, got calls=$calls output=$output"
    fi
}

test_issue_linear_provider_blocks_gh() {
    test_start "revo issue - linear provider blocks gh issue calls"

    setup_test_dir
    echo "issue-linear" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/api.git" --path api > /dev/null 2>&1
    mkdir -p repos/api

    local tmp
    tmp=$(mktemp)
    awk '
        /provider: github/ { print "  provider: linear"; next }
        { print }
    ' revo.yaml > "$tmp"
    mv "$tmp" revo.yaml

    local fakebin="$TEST_DIR/fakebin"
    local log="$TEST_DIR/gh.log"
    setup_fake_gh_issue_list "$fakebin" "$log"

    local output
    if output=$(FAKE_GH_LOG="$log" PATH="$fakebin:$PATH" $REVO_CMD issue list 2>&1); then
        test_fail "linear provider allowed issue list"
        return 1
    fi

    if echo "$output" | grep -q "Linear MCP/app" && [[ ! -s "$log" ]]; then
        test_pass
    else
        test_fail "expected Linear MCP guidance and no gh calls, output=$output"
    fi
}

test_issue_none_provider_blocks_gh() {
    test_start "revo issue - none provider blocks gh issue calls"

    setup_test_dir
    echo "issue-none" | $REVO_CMD init > /dev/null 2>&1
    $REVO_CMD add "git@github.com:test/api.git" --path api > /dev/null 2>&1
    mkdir -p repos/api

    local tmp
    tmp=$(mktemp)
    awk '
        /provider: github/ { print "  provider: none"; next }
        /  linear:/ { skip = 1; next }
        skip && /    team:/ { next }
        skip && /    project:/ { skip = 0; next }
        { print }
    ' revo.yaml > "$tmp"
    mv "$tmp" revo.yaml

    local fakebin="$TEST_DIR/fakebin"
    local log="$TEST_DIR/gh.log"
    setup_fake_gh_issue_list "$fakebin" "$log"

    local output
    if output=$(FAKE_GH_LOG="$log" PATH="$fakebin:$PATH" $REVO_CMD issue list 2>&1); then
        test_fail "none provider allowed issue list"
        return 1
    fi

    if echo "$output" | grep -q "no configured issue tracker" && [[ ! -s "$log" ]]; then
        test_pass
    else
        test_fail "expected no-tracker guidance and no gh calls, output=$output"
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
test_exec_command_unavailable
test_exec_surface_not_bundled
test_git_clone_helper_separates_option_like_url
test_init_creates_files
test_add_repo
test_add_rejects_traversal_path
test_add_with_depends_on
test_list_repos
test_status_not_cloned
test_status_reports_dirty_gitfile_worktree
test_status_reports_no_upstream
test_checkout_rejects_tag_name_without_branch
test_clone_refuses_hostile_config_path
test_clone_separates_option_like_url
test_workspace_cleans_partial_repo_after_branch_failure
test_tag_filtering
test_mars_yaml_fallback
test_context_generates_claude_md
test_context_generates_configured_agent_files
test_context_legacy_config_defaults_to_claude_only
test_init_preserves_existing_claude_md
test_init_preserves_existing_gitignore
test_context_preserves_user_content
test_context_preserves_agents_user_content
test_context_idempotent_no_duplication
test_context_does_not_emit_env_secret_values
test_issue_list_json_flat_array
test_issue_list_human_calls_gh_once_per_repo
test_issue_linear_provider_blocks_gh
test_issue_none_provider_blocks_gh
test_feature_creates_file

# Network tests (optional - skip if offline)
if ping -c 1 github.com &> /dev/null; then
    printf "\n--- Network Tests ---\n\n"
    test_clone_with_real_repo
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

#!/usr/bin/env bash
# Test suite for workspace helpers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/ui.sh"
source "$SCRIPT_DIR/../lib/yaml.sh"
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

# Fixture with the Rails/UI/Flutter scratch that 2.1.0 skips, plus nested
# folders named like anchored excludes that must survive.
mk_scratch_fixture() {
    local root="/tmp/revo/workspace_test_$$_$1"
    rm -rf "$root"
    local s="$root/src"
    mkdir -p "$s/app/models/log" "$s/app/tmp" "$s/tmp/cache" "$s/tmp/pids" "$s/log"
    mkdir -p "$s/.idea" "$s/.vscode" "$s/.ruby-lsp" "$s/.firebase" "$s/bin"
    mkdir -p "$s/ios/.symlinks/plugins" "$s/ios/Flutter/ephemeral" "$s/storage/ab"
    printf 'class Keep; end\n' > "$s/app/models/log/entry.rb"
    printf 'nested tmp\n' > "$s/app/tmp/helper.rb"
    printf 'cache\n' > "$s/tmp/cache/bootsnap"
    printf 'pid\n' > "$s/tmp/pids/server.pid"
    printf 'log\n' > "$s/log/development.log"
    printf 'x\n' > "$s/.idea/workspace.xml"
    printf 'x\n' > "$s/.vscode/launch.json"
    printf 'x\n' > "$s/.ruby-lsp/index"
    printf 'x\n' > "$s/.firebase/hosting.cache"
    printf 'x\n' > "$s/ios/.symlinks/plugins/a"
    printf 'x\n' > "$s/ios/Flutter/ephemeral/flutter_lldb_helper.py"
    printf 'x\n' > "$s/.DS_Store"
    printf 'x\n' > "$s/ad-hoc-run.log"
    printf 'x\n' > "$s/latest.dump"
    printf 'x\n' > "$s/tsconfig.tsbuildinfo"
    printf 'blob\n' > "$s/storage/ab/blob"
    printf '#!/bin/sh\n' > "$s/bin/build"
    printf 'source\n' > "$s/app/application.rb"
    printf '%s' "$root"
}

assert_scratch_skipped() {
    local dest="$1"
    local p
    for p in app/application.rb app/models/log/entry.rb app/tmp/helper.rb bin/build storage/ab/blob; do
        if [[ ! -f "$dest/$p" ]]; then
            test_fail "expected $p to be copied"
            return 1
        fi
    done
    for p in tmp log .idea .vscode .ruby-lsp .firebase ios/.symlinks ios/Flutter/ephemeral \
        .DS_Store ad-hoc-run.log latest.dump tsconfig.tsbuildinfo; do
        if [[ -e "$dest/$p" ]]; then
            test_fail "expected $p to be skipped"
            return 1
        fi
    done
    return 0
}

test_workspace_copy_skips_scratch() {
    test_start "_workspace_copy_repo - skips Rails/editor/Flutter scratch, keeps nested tmp/log"
    local root
    root=$(mk_scratch_fixture "scratch")
    _workspace_set_excludes
    # Run from a dir with *.log files so unquoted glob expansion would show up
    if ! (cd "$root/src" && _workspace_copy_repo "$root/src" "$root/dest"); then
        rm -rf "$root"
        test_fail "copy failed"
        return 1
    fi
    if assert_scratch_skipped "$root/dest"; then
        test_pass
    fi
    rm -rf "$root"
}

test_workspace_fallback_skips_scratch() {
    test_start "_workspace_copy_repo_fallback - skips the same scratch"
    local root
    root=$(mk_scratch_fixture "scratch_fallback")
    _workspace_set_excludes
    if ! (cd "$root/src" && _workspace_copy_repo_fallback "$root/src" "$root/dest"); then
        rm -rf "$root"
        test_fail "fallback copy failed"
        return 1
    fi
    if assert_scratch_skipped "$root/dest"; then
        test_pass
    fi
    rm -rf "$root"
}

test_workspace_copy_paths_agree() {
    test_start "rsync and fallback copy the same file set"
    if ! command -v rsync >/dev/null 2>&1; then
        printf "SKIP (no rsync) "
        test_pass
        return 0
    fi
    local root
    root=$(mk_scratch_fixture "parity")
    _workspace_set_excludes
    _workspace_copy_repo "$root/src" "$root/rsync" || { rm -rf "$root"; test_fail "rsync copy failed"; return 1; }
    _workspace_copy_repo_fallback "$root/src" "$root/fallback" || { rm -rf "$root"; test_fail "fallback copy failed"; return 1; }
    local a b
    a=$(cd "$root/rsync" && find . | sort)
    b=$(cd "$root/fallback" && find . | sort)
    if [[ "$a" == "$b" ]]; then
        test_pass
    else
        test_fail "copy paths differ: $(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | tr '\n' ' ')"
    fi
    rm -rf "$root"
}

test_workspace_restores_tracked_files() {
    test_start "_workspace_copy_repo - restores tracked files under excluded paths"
    local root
    root=$(mk_scratch_fixture "restore")
    local s="$root/src"
    : > "$s/tmp/.keep"
    : > "$s/tmp/pids/.keep"
    : > "$s/log/.keep"
    printf '{"editor.tabSize": 2}\n' > "$s/.vscode/settings.json"
    printf 'tracked\n' > "$s/tmp/gone.txt"
    git -C "$s" init -q
    git -C "$s" add app bin tmp/.keep tmp/pids/.keep tmp/gone.txt log/.keep .vscode/settings.json
    git -C "$s" -c user.email=t@t -c user.name=t commit -qm init
    # Local edit and local deletion in the source must both carry over
    printf '{"editor.tabSize": 4}\n' > "$s/.vscode/settings.json"
    rm "$s/tmp/gone.txt"

    _workspace_set_excludes
    if ! _workspace_copy_repo "$s" "$root/dest"; then
        rm -rf "$root"
        test_fail "copy failed"
        return 1
    fi
    local d="$root/dest"
    if [[ ! -f "$d/tmp/.keep" ]] || [[ ! -f "$d/tmp/pids/.keep" ]] || [[ ! -f "$d/log/.keep" ]]; then
        test_fail ".keep files were not restored"
    elif [[ -e "$d/tmp/cache" ]] || [[ -e "$d/tmp/pids/server.pid" ]] || [[ -e "$d/log/development.log" ]]; then
        test_fail "untracked scratch came back with the restore"
    elif ! grep -q 'tabSize": 4' "$d/.vscode/settings.json" 2>/dev/null; then
        test_fail "tracked file was not restored with its local edit"
    elif [[ -e "$d/tmp/gone.txt" ]]; then
        test_fail "file deleted in source was resurrected"
    elif [[ "$WORKSPACE_RESTORED_COUNT" -ne 4 ]]; then
        test_fail "expected 4 restored files, got $WORKSPACE_RESTORED_COUNT"
    elif [[ -n "$(git -C "$d" status --porcelain -- tmp/.keep tmp/pids/.keep log/.keep)" ]]; then
        test_fail "restored .keep files show as changed"
    else
        test_pass
    fi
    rm -rf "$root"
}

test_workspace_restore_ignores_parent_repo() {
    test_start "_workspace_restore_tracked - no-op when dest is not a repo root"
    local root="/tmp/revo/workspace_test_$$_parent_repo"
    rm -rf "$root"
    mkdir -p "$root/sub"
    git -C "$root" init -q
    : > "$root/tracked.txt"
    git -C "$root" add tracked.txt
    git -C "$root" -c user.email=t@t -c user.name=t commit -qm init
    rm "$root/tracked.txt"
    _workspace_restore_tracked "$root" "$root/sub"
    if [[ -e "$root/sub/tracked.txt" ]] || [[ "$WORKSPACE_RESTORED_COUNT" -ne 0 ]]; then
        test_fail "restored files from a parent repository"
    else
        test_pass
    fi
    rm -rf "$root"
}

test_workspace_exclude_config_merge() {
    local root="/tmp/revo/workspace_test_$$_merge"
    rm -rf "$root"
    mkdir -p "$root"
    cat > "$root/revo.yaml" << 'EOF2'
version: 1
workspace:
  name: "merge"
  exclude: ["*.sqlite3"]
repos:
  - url: git@github.com:org/api.git
    exclude: [/storage]
    include: [tmp, .vscode, not-excluded]
  - url: git@github.com:org/web.git
EOF2
    yaml_parse "$root/revo.yaml"

    test_start "_workspace_set_excludes - defaults + workspace + repo, minus include"
    _workspace_set_excludes 0
    local joined=",$(IFS=','; printf '%s' "${WORKSPACE_EXCLUDES[*]}"),"
    if [[ "$joined" != *",node_modules/,"* ]] || [[ "$joined" != *",*.sqlite3,"* ]] \
        || [[ "$joined" != *",/storage,"* ]] || [[ "$joined" != *",/log/,"* ]]; then
        test_fail "missing merged entries: $joined"
    elif [[ "$joined" == *",/tmp/,"* ]] || [[ "$joined" == *",.vscode/,"* ]]; then
        test_fail "include did not remove entries: $joined"
    elif [[ "$WORKSPACE_UNUSED_INCLUDES" != "not-excluded" ]]; then
        test_fail "unused includes: '$WORKSPACE_UNUSED_INCLUDES'"
    else
        test_pass
    fi

    test_start "_workspace_set_excludes - other repos keep defaults + workspace only"
    _workspace_set_excludes 1
    joined=",$(IFS=','; printf '%s' "${WORKSPACE_EXCLUDES[*]}"),"
    if [[ "$joined" != *",/tmp/,"* ]] || [[ "$joined" != *",*.sqlite3,"* ]] \
        || [[ "$joined" == *",/storage,"* ]] || [[ -n "$WORKSPACE_UNUSED_INCLUDES" ]]; then
        test_fail "unexpected list: $joined"
    else
        test_pass
    fi

    test_start "_workspace_copy_repo - honors merged config on both copy paths"
    local fixture
    fixture=$(mk_scratch_fixture "merge_copy")
    printf 'db\n' > "$fixture/src/development.sqlite3"
    _workspace_set_excludes 0
    _workspace_copy_repo "$fixture/src" "$fixture/rsync"
    _workspace_copy_repo_fallback "$fixture/src" "$fixture/fallback"
    local d ok=1
    for d in "$fixture/rsync" "$fixture/fallback"; do
        if [[ -e "$d/storage" ]] || [[ -e "$d/development.sqlite3" ]] \
            || [[ ! -f "$d/tmp/cache/bootsnap" ]] || [[ ! -f "$d/.vscode/launch.json" ]] \
            || [[ -e "$d/log" ]]; then
            ok=0
            test_fail "wrong copy in ${d##*/}"
            break
        fi
    done
    [[ $ok -eq 1 ]] && test_pass

    rm -rf "$root" "$fixture"
    # Reset for later tests
    YAML_WORKSPACE_EXCLUDE=""
    YAML_REPO_COUNT=0
    _workspace_set_excludes
}

test_workspace_size_report() {
    test_start "_workspace_print_size_report - top dirs and over-threshold warning"
    local root="/tmp/revo/workspace_test_$$_size"
    rm -rf "$root"
    mkdir -p "$root/repo/.git" "$root/repo/storage" "$root/repo/app"
    dd if=/dev/zero of="$root/repo/storage/blob" bs=1024 count=300 2>/dev/null
    dd if=/dev/zero of="$root/repo/.git/pack" bs=1024 count=300 2>/dev/null
    printf 'x\n' > "$root/repo/app/a.rb"

    local saved="$WORKSPACE_SIZE_WARN_KB"
    WORKSPACE_SIZE_WARN_KB=100
    _workspace_measure "$root/repo"
    local out
    out=$(_workspace_print_size_report "api" 2>&1)
    WORKSPACE_SIZE_WARN_KB="$saved"

    if [[ "$WORKSPACE_FILE_COUNT" -ne 3 ]]; then
        test_fail "file count $WORKSPACE_FILE_COUNT, expected 3"
    elif [[ "$out" != *"3 files"* ]] || [[ "$out" != *"largest:"* ]]; then
        test_fail "report missing totals: $out"
    elif [[ "$out" != *"api/storage is"*"exclude: [/storage]"* ]]; then
        test_fail "no storage warning: $out"
    elif [[ "$out" == *"exclude: [/.git]"* ]]; then
        test_fail ".git should never be suggested for exclusion"
    elif [[ "$out" == *"exclude: [/app]"* ]]; then
        test_fail "small dir was flagged"
    else
        test_pass
    fi
    rm -rf "$root"
}

test_workspace_format_kb() {
    test_start "_workspace_format_kb - KB, MB, GB"
    local a b c
    a=$(_workspace_format_kb 512)
    b=$(_workspace_format_kb 142336)
    c=$(_workspace_format_kb 1048576)
    if [[ "$a" == "512 KB" ]] && [[ "$b" == "139.0 MB" ]] && [[ "$c" == "1.0 GB" ]]; then
        test_pass
    else
        test_fail "got '$a' '$b' '$c'"
    fi
}

printf "\n=== Workspace Tests ===\n\n"

test_workspace_copy_skips_dependency_dirs
test_workspace_fallback_prunes_before_copying_nested_dirs
test_workspace_copy_prunes_external_symlinks
test_workspace_delete_rejects_empty_sanitized_name
test_workspace_gitignore_guard
test_workspace_copy_skips_scratch
test_workspace_fallback_skips_scratch
test_workspace_copy_paths_agree
test_workspace_restores_tracked_files
test_workspace_restore_ignores_parent_repo
test_workspace_exclude_config_merge
test_workspace_size_report
test_workspace_format_kb

printf "\n=== Results ===\n"
printf "Passed: %d/%d\n" "$TESTS_PASSED" "$TESTS_RUN"

if [[ $TESTS_FAILED -gt 0 ]]; then
    printf "Failed: %d\n" "$TESTS_FAILED"
    exit 1
fi

exit 0

#!/usr/bin/env bash
# Test suite for scan.sh detection (database and framework)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/scan.sh"
source "$SCRIPT_DIR/../lib/commands/init.sh"

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
    if [[ "$expected" != "$actual" ]]; then
        test_fail "expected='$expected' got='$actual'"
        return 1
    fi
    return 0
}

# --- helper: build a fake repo dir ---
mk_repo() {
    local d="/tmp/revo/scan_test_$$_$1"
    rm -rf "$d"
    mkdir -p "$d"
    printf '%s' "$d"
}

# --- Tag detection tests ---

test_tags_rails_with_vue_is_backend() {
    test_start "_init_auto_tags - Rails+Vue (Gemfile + package.json) → backend"
    local d
    d=$(mk_repo "rails_vue")
    : > "$d/Gemfile"
    printf '{"dependencies":{"vue":"^3.0.0"}}' > "$d/package.json"
    local tags
    tags=$(_init_auto_tags "$d" "myrepo")
    rm -rf "$d"
    [[ "$tags" == *"backend"* ]] && [[ "$tags" != *"frontend"* ]] || { test_fail "got: $tags"; return 1; }
    test_pass
}

test_tags_pure_vue_is_frontend() {
    test_start "_init_auto_tags - pure Vue (package.json only) → frontend"
    local d
    d=$(mk_repo "pure_vue")
    printf '{"dependencies":{"vue":"^3.0.0","vite":"^4.0.0"}}' > "$d/package.json"
    local tags
    tags=$(_init_auto_tags "$d" "myrepo")
    rm -rf "$d"
    [[ "$tags" == *"frontend"* ]] || { test_fail "got: $tags"; return 1; }
    test_pass
}

test_tags_django_is_backend() {
    test_start "_init_auto_tags - Django (manage.py) → backend"
    local d
    d=$(mk_repo "django")
    : > "$d/manage.py"
    : > "$d/requirements.txt"
    local tags
    tags=$(_init_auto_tags "$d" "myrepo")
    rm -rf "$d"
    [[ "$tags" == *"backend"* ]] || { test_fail "got: $tags"; return 1; }
    test_pass
}

test_tags_react_native_is_mobile() {
    test_start "_init_auto_tags - React Native → mobile"
    local d
    d=$(mk_repo "rn")
    printf '{"dependencies":{"react-native":"^0.72.0"}}' > "$d/package.json"
    local tags
    tags=$(_init_auto_tags "$d" "myrepo")
    rm -rf "$d"
    [[ "$tags" == *"mobile"* ]] || { test_fail "got: $tags"; return 1; }
    test_pass
}

test_tags_flutter_is_mobile() {
    test_start "_init_auto_tags - Flutter (pubspec.yaml) → mobile"
    local d
    d=$(mk_repo "flutter")
    : > "$d/pubspec.yaml"
    local tags
    tags=$(_init_auto_tags "$d" "myrepo")
    rm -rf "$d"
    [[ "$tags" == *"mobile"* ]] || { test_fail "got: $tags"; return 1; }
    test_pass
}

test_routes_empty_does_not_trip_nounset() {
    test_start "_scan_list_routes - empty route list works with nounset"
    local d
    d=$(mk_repo "empty_routes")
    mkdir -p "$d/src/routes"
    local routes
    routes=$(_scan_list_routes "$d")
    rm -rf "$d"
    assert_eq "" "$routes" || return 1
    test_pass
}

# --- Database detection tests ---

test_db_rails_postgres() {
    test_start "_scan_database - Rails database.yml (postgres)"
    local d
    d=$(mk_repo "rails_pg")
    mkdir -p "$d/config"
    cat > "$d/config/database.yml" <<'EOF'
default: &default
  adapter: postgresql
  encoding: unicode

development:
  <<: *default
  database: myapp_development
EOF
    scan_reset
    _scan_database "$d"
    rm -rf "$d"
    assert_eq "postgres" "$SCAN_DB_TYPE" || return 1
    assert_eq "myapp_development" "$SCAN_DB_NAME" || return 1
    test_pass
}

test_db_rails_mysql() {
    test_start "_scan_database - Rails database.yml (mysql2)"
    local d
    d=$(mk_repo "rails_mysql")
    mkdir -p "$d/config"
    cat > "$d/config/database.yml" <<'EOF'
development:
  adapter: mysql2
  database: myapp_dev
EOF
    scan_reset
    _scan_database "$d"
    rm -rf "$d"
    assert_eq "mysql" "$SCAN_DB_TYPE" || return 1
    assert_eq "myapp_dev" "$SCAN_DB_NAME" || return 1
    test_pass
}

test_db_rails_erb_name_rejected() {
    test_start "_scan_database - Rails database with ERB name kept blank"
    local d
    d=$(mk_repo "rails_erb")
    mkdir -p "$d/config"
    cat > "$d/config/database.yml" <<'EOF'
development:
  adapter: postgresql
  database: <%= ENV['DB_NAME'] %>
EOF
    scan_reset
    _scan_database "$d"
    rm -rf "$d"
    assert_eq "postgres" "$SCAN_DB_TYPE" || return 1
    assert_eq "" "$SCAN_DB_NAME" || return 1
    test_pass
}

test_db_env_database_url_postgres() {
    test_start "_scan_database - .env DATABASE_URL postgres"
    local d
    d=$(mk_repo "env_pg")
    printf 'DATABASE_URL=postgres://user:pass@localhost:5432/myapp_dev\n' > "$d/.env"
    scan_reset
    _scan_database "$d"
    rm -rf "$d"
    assert_eq "postgres" "$SCAN_DB_TYPE" || return 1
    assert_eq "myapp_dev" "$SCAN_DB_NAME" || return 1
    test_pass
}

test_db_env_database_url_mongodb() {
    test_start "_scan_database - .env DATABASE_URL mongodb"
    local d
    d=$(mk_repo "env_mongo")
    printf 'DATABASE_URL=mongodb://user:pass@localhost:27017/cooldb\n' > "$d/.env.example"
    scan_reset
    _scan_database "$d"
    rm -rf "$d"
    assert_eq "mongodb" "$SCAN_DB_TYPE" || return 1
    assert_eq "cooldb" "$SCAN_DB_NAME" || return 1
    test_pass
}

test_db_env_postgres_db_var() {
    test_start "_scan_database - .env POSTGRES_DB only"
    local d
    d=$(mk_repo "env_pg_var")
    printf 'POSTGRES_DB=myapp_db\nPOSTGRES_USER=u\n' > "$d/.env.example"
    scan_reset
    _scan_database "$d"
    rm -rf "$d"
    assert_eq "postgres" "$SCAN_DB_TYPE" || return 1
    assert_eq "myapp_db" "$SCAN_DB_NAME" || return 1
    test_pass
}

test_db_compose_postgres() {
    test_start "_scan_database - docker-compose postgres image"
    local d
    d=$(mk_repo "compose_pg")
    cat > "$d/docker-compose.yml" <<'EOF'
services:
  db:
    image: postgres:15
    environment:
      POSTGRES_DB: app_db
EOF
    scan_reset
    _scan_database "$d"
    rm -rf "$d"
    assert_eq "postgres" "$SCAN_DB_TYPE" || return 1
    assert_eq "app_db" "$SCAN_DB_NAME" || return 1
    test_pass
}

test_db_no_database() {
    test_start "_scan_database - no DB config → empty"
    local d
    d=$(mk_repo "no_db")
    : > "$d/README.md"
    scan_reset
    _scan_database "$d"
    rm -rf "$d"
    assert_eq "" "$SCAN_DB_TYPE" || return 1
    assert_eq "" "$SCAN_DB_NAME" || return 1
    test_pass
}

# --- Run tests ---

mkdir -p /tmp/revo

printf "\n=== Scan Tests ===\n\n"

test_tags_rails_with_vue_is_backend
test_tags_pure_vue_is_frontend
test_tags_django_is_backend
test_tags_react_native_is_mobile
test_tags_flutter_is_mobile
test_routes_empty_does_not_trip_nounset
test_db_rails_postgres
test_db_rails_mysql
test_db_rails_erb_name_rejected
test_db_env_database_url_postgres
test_db_env_database_url_mongodb
test_db_env_postgres_db_var
test_db_compose_postgres
test_db_no_database

printf "\n=== Results ===\n"
printf "Passed: %d/%d\n" "$TESTS_PASSED" "$TESTS_RUN"

if [[ $TESTS_FAILED -gt 0 ]]; then
    printf "Failed: %d\n" "$TESTS_FAILED"
    exit 1
fi

exit 0

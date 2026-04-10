#!/usr/bin/env bash
# Revo CLI - Database operations
# Clone and drop local databases for workspace isolation.
# Supports postgres, mongodb, mysql. CLI tools must be installed by the user.

DB_OUTPUT=""
DB_ERROR=""

# Validate a database name is safe (alphanumeric, underscore, hyphen only)
_db_validate_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        DB_ERROR="Database name is empty"
        return 1
    fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        DB_ERROR="Invalid database name '$name': only alphanumeric, underscore, and hyphen allowed"
        return 1
    fi
    if [[ ${#name} -gt 63 ]]; then
        DB_ERROR="Database name '$name' exceeds 63 character limit"
        return 1
    fi
    return 0
}

# Convert workspace name to a DB-safe suffix (hyphens -> underscores, strip unsafe chars)
_db_sanitize_ws_suffix() {
    local name="$1"
    name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    name=$(printf '%s' "$name" | tr '-' '_')
    name=$(printf '%s' "$name" | tr -cd 'a-z0-9_')
    printf '%s' "$name"
}

# Build the workspace-scoped database name
# Usage: ws_db=$(_db_workspace_name "myapp_dev" "my-feature")
# Returns: myapp_dev_ws_my_feature
_db_workspace_name() {
    local source="$1"
    local ws_name="$2"
    local suffix
    suffix=$(_db_sanitize_ws_suffix "$ws_name")
    local full="${source}_ws_${suffix}"
    # Truncate to 63 chars (PostgreSQL limit) preserving the _ws_ marker
    if [[ ${#full} -gt 63 ]]; then
        full="${full:0:63}"
    fi
    printf '%s' "$full"
}

# Check that the required CLI tool is available
# Returns 0 if found, 1 with DB_ERROR message if missing
_db_check_tool() {
    local db_type="$1"

    case "$db_type" in
        postgres)
            if ! command -v psql >/dev/null 2>&1; then
                DB_ERROR="psql not found. Install PostgreSQL CLI tools (e.g., brew install postgresql)"
                return 1
            fi
            ;;
        mongodb)
            if ! command -v mongodump >/dev/null 2>&1; then
                DB_ERROR="mongodump not found. Install MongoDB Database Tools (e.g., brew install mongodb-database-tools)"
                return 1
            fi
            if ! command -v mongosh >/dev/null 2>&1 && ! command -v mongo >/dev/null 2>&1; then
                DB_ERROR="mongosh/mongo not found. Install MongoDB Shell (e.g., brew install mongosh)"
                return 1
            fi
            ;;
        mysql)
            if ! command -v mysql >/dev/null 2>&1; then
                DB_ERROR="mysql not found. Install MySQL CLI tools (e.g., brew install mysql)"
                return 1
            fi
            ;;
        *)
            DB_ERROR="Unsupported database type: $db_type"
            return 1
            ;;
    esac
    return 0
}

# Clone a database
# Usage: _db_clone "postgres" "source_db" "target_db"
_db_clone() {
    local db_type="$1"
    local source="$2"
    local target="$3"

    DB_OUTPUT=""
    DB_ERROR=""

    _db_validate_name "$source" || return 1
    _db_validate_name "$target" || return 1
    _db_check_tool "$db_type" || return 1

    case "$db_type" in
        postgres)
            # Try template clone first (fastest, filesystem-level copy)
            if DB_OUTPUT=$(createdb -T "$source" "$target" </dev/null 2>&1); then
                return 0
            fi
            # Fallback: dump/restore via temp file (avoids partial state from broken pipes)
            DB_ERROR=""
            local dump_file
            dump_file=$(mktemp -t revo-pgdump.XXXXXX)
            if ! pg_dump "$source" > "$dump_file" 2>/dev/null; then
                DB_ERROR="Failed to dump postgres database: $source"
                rm -f "$dump_file"
                return 1
            fi
            if ! createdb "$target" </dev/null 2>/dev/null; then
                DB_ERROR="Failed to create postgres database: $target"
                rm -f "$dump_file"
                return 1
            fi
            if psql -q "$target" < "$dump_file" >/dev/null 2>&1; then
                rm -f "$dump_file"
                DB_OUTPUT="Cloned via dump/restore"
                return 0
            fi
            DB_ERROR="Failed to restore postgres database: $target"
            dropdb --if-exists "$target" </dev/null 2>/dev/null
            rm -f "$dump_file"
            return 1
            ;;
        mongodb)
            # Use temp archive file (avoids partial state from broken pipes)
            local archive_file
            archive_file=$(mktemp -t revo-mongodump.XXXXXX)
            if ! mongodump --archive="$archive_file" --db "$source" 2>/dev/null; then
                DB_ERROR="Failed to dump mongodb database: $source"
                rm -f "$archive_file"
                return 1
            fi
            if DB_OUTPUT=$(mongorestore --archive="$archive_file" --nsFrom="${source}.*" --nsTo="${target}.*" 2>&1); then
                rm -f "$archive_file"
                return 0
            fi
            DB_ERROR="Failed to restore mongodb database: $source -> $target"
            # Clean up partial target
            local mongo_cmd="mongosh"
            command -v mongosh >/dev/null 2>&1 || mongo_cmd="mongo"
            $mongo_cmd --quiet --eval "db.getSiblingDB(\"$target\").dropDatabase()" </dev/null 2>/dev/null || true
            rm -f "$archive_file"
            return 1
            ;;
        mysql)
            # Use temp dump file (avoids partial state from broken pipes)
            local dump_file
            dump_file=$(mktemp -t revo-mysqldump.XXXXXX)
            if ! mysqladmin create "$target" </dev/null 2>/dev/null; then
                DB_ERROR="Failed to create mysql database: $target"
                rm -f "$dump_file"
                return 1
            fi
            if ! mysqldump "$source" > "$dump_file" 2>/dev/null; then
                DB_ERROR="Failed to dump mysql database: $source"
                mysqladmin -f drop "$target" </dev/null 2>/dev/null
                rm -f "$dump_file"
                return 1
            fi
            if DB_OUTPUT=$(mysql "$target" < "$dump_file" 2>&1); then
                rm -f "$dump_file"
                return 0
            fi
            DB_ERROR="Failed to restore mysql database: $target"
            mysqladmin -f drop "$target" </dev/null 2>/dev/null
            rm -f "$dump_file"
            return 1
            ;;
    esac
}

# Drop a database (with safety check)
# Usage: _db_drop "postgres" "myapp_dev_ws_feature"
_db_drop() {
    local db_type="$1"
    local db_name="$2"

    DB_OUTPUT=""
    DB_ERROR=""

    # Safety: refuse to drop databases without the _ws_ infix
    if [[ "$db_name" != *"_ws_"* ]]; then
        DB_ERROR="Refusing to drop '$db_name': name does not contain _ws_ (safety guard)"
        return 1
    fi

    _db_validate_name "$db_name" || return 1
    _db_check_tool "$db_type" || return 1

    case "$db_type" in
        postgres)
            if DB_OUTPUT=$(dropdb --if-exists "$db_name" </dev/null 2>&1); then
                return 0
            fi
            DB_ERROR="Failed to drop postgres database: $db_name"
            return 1
            ;;
        mongodb)
            local mongo_cmd="mongosh"
            command -v mongosh >/dev/null 2>&1 || mongo_cmd="mongo"
            if DB_OUTPUT=$($mongo_cmd --quiet --eval "db.getSiblingDB(\"$db_name\").dropDatabase()" </dev/null 2>&1); then
                return 0
            fi
            DB_ERROR="Failed to drop mongodb database: $db_name"
            return 1
            ;;
        mysql)
            if DB_OUTPUT=$(mysqladmin -f drop "$db_name" </dev/null 2>&1); then
                return 0
            fi
            DB_ERROR="Failed to drop mysql database: $db_name"
            return 1
            ;;
    esac
}

# Check if a database exists
# Returns 0 if exists, 1 if not
_db_exists() {
    local db_type="$1"
    local db_name="$2"

    _db_check_tool "$db_type" || return 1

    case "$db_type" in
        postgres)
            psql -lqt </dev/null 2>/dev/null | cut -d '|' -f 1 | grep -qw "$db_name"
            ;;
        mongodb)
            local mongo_cmd="mongosh"
            command -v mongosh >/dev/null 2>&1 || mongo_cmd="mongo"
            $mongo_cmd --quiet --eval "db.getMongo().getDBNames()" </dev/null 2>/dev/null | grep -qw "$db_name"
            ;;
        mysql)
            mysqlshow "$db_name" </dev/null >/dev/null 2>&1
            ;;
    esac
}

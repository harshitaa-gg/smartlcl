#!/usr/bin/env bash
# ==============================================================================
# SmartLCL - Database Migration Runner
# Applies plain SQL migrations in filename order.
# Each migration runs inside its own transaction.
# Tracks applied migrations in schema_migrations (version, filename, checksum, applied_at).
# ==============================================================================

set -euo pipefail

# Locate project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env if present
if [ -f "${ROOT_DIR}/.env" ]; then
    # Export non-comment lines
    set -a
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/.env"
    set +a
fi

DB_HOST="${POSTGRES_HOST:-localhost}"
DB_PORT="${POSTGRES_PORT:-5432}"
DB_NAME="${POSTGRES_DB:-smartlcl_dev}"
DB_USER="${POSTGRES_USER:-smartlcl_admin}"
export PGPASSWORD="${POSTGRES_PASSWORD:-smartlcl_dev_password}"

PSQL_CMD=(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q -t -A)

compute_checksum() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        python -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())" "$file"
    fi
}

echo "==> Ensuring schema_migrations table exists in ${DB_NAME}..."
"${PSQL_CMD[@]}" <<'EOF'
CREATE TABLE IF NOT EXISTS schema_migrations (
    version VARCHAR(255) PRIMARY KEY,
    filename VARCHAR(255) NOT NULL,
    checksum VARCHAR(64) NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
EOF

MIGRATIONS_DIR="${ROOT_DIR}/db/migrations"
if [ ! -d "${MIGRATIONS_DIR}" ]; then
    echo "ERROR: Migrations directory ${MIGRATIONS_DIR} does not exist." >&2
    exit 1
fi

# Find all SQL files sorted lexicographically
shopt -s nullglob
migration_files=("${MIGRATIONS_DIR}"/*.sql)
shopt -u nullglob

if [ ${#migration_files[@]} -eq 0 ]; then
    echo "==> No SQL migrations found in ${MIGRATIONS_DIR}."
    exit 0
fi

# Sort migration files
IFS=$'\n' sorted_files=($(sort <<<"${migration_files[*]}"))
unset IFS

for file in "${sorted_files[@]}"; do
    filename="$(basename "$file")"
    version="${filename%%_*}"
    current_checksum="$(compute_checksum "$file")"

    # Query existing migration record
    record="$("${PSQL_CMD[@]}" -c "SELECT checksum FROM schema_migrations WHERE version = '${version}';")"

    if [ -n "$record" ]; then
        if [ "$record" != "$current_checksum" ]; then
            echo "FATAL: Checksum mismatch for migration version ${version} (${filename})!" >&2
            echo "  Expected in DB: ${record}" >&2
            echo "  Actual on disk: ${current_checksum}" >&2
            echo "Migrations must be immutable and forward-only." >&2
            exit 1
        else
            echo "--> Skipping already-applied migration: ${filename}"
            continue
        fi
    fi

    echo "==> Applying migration: ${filename} (version: ${version})..."
    
    # Run migration inside a single atomic transaction
    "${PSQL_CMD[@]}" <<EOF
BEGIN;
\i ${file}
INSERT INTO schema_migrations (version, filename, checksum)
VALUES ('${version}', '${filename}', '${current_checksum}');
COMMIT;
EOF

    echo "    Successfully applied ${filename}"
done

echo "==> All migrations up to date."

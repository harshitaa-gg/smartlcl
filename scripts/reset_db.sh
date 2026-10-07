#!/usr/bin/env bash
# ==============================================================================
# SmartLCL - Database Reset Script
# Drops and recreates the development database, applies migrations, and
# optionally applies seeds when invoked with --seed / -s.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env if present
if [ -f "${ROOT_DIR}/.env" ]; then
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

RUN_SEEDS=false
for arg in "$@"; do
    case "$arg" in
        -s|--seed)
            RUN_SEEDS=true
            shift
            ;;
    esac
done

echo "==> Resetting database: ${DB_NAME} on ${DB_HOST}:${DB_PORT}..."

# Terminate active connections and drop/recreate database using maintenance database 'postgres'
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d postgres -v ON_ERROR_STOP=1 <<EOF
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
EOF

echo "==> Database ${DB_NAME} recreated successfully."

# Run migrations
"${SCRIPT_DIR}/migrate.sh"

# Run seeds if requested
if [ "$RUN_SEEDS" = true ]; then
    SEEDS_DIR="${ROOT_DIR}/db/seeds"
    echo "==> Running seeds from ${SEEDS_DIR}..."
    shopt -s nullglob
    seed_files=("${SEEDS_DIR}"/*.sql)
    shopt -u nullglob

    if [ ${#seed_files[@]} -gt 0 ]; then
        IFS=$'\n' sorted_seeds=($(sort <<<"${seed_files[*]}"))
        unset IFS
        for sfile in "${sorted_seeds[@]}"; do
            sname="$(basename "$sfile")"
            echo "--> Applying seed: ${sname}..."
            psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -f "${sfile}"
        done
        echo "==> Seeds applied successfully."
    else
        echo "--> No seed files found in ${SEEDS_DIR}."
    fi
fi

echo "==> Database reset complete."

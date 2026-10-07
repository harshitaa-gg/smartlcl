#!/usr/bin/env python3
"""
SmartLCL - Idempotent Database Migration Runner (Python / Cross-Platform)
Applies plain SQL migrations in filename order.
Each migration executes inside its own atomic transaction.
Records versions, filenames, and SHA-256 checksums in schema_migrations.
Fails loudly if an applied migration's checksum has changed.
"""

import hashlib
import os
import sys
from pathlib import Path
from dotenv import load_dotenv
import psycopg

ROOT_DIR = Path(__file__).resolve().parent.parent
load_dotenv(ROOT_DIR / ".env")

def get_connection():
    return psycopg.connect(
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=int(os.getenv("POSTGRES_PORT", "5432")),
        dbname=os.getenv("POSTGRES_DB", "smartlcl_dev"),
        user=os.getenv("POSTGRES_USER", "smartlcl_admin"),
        password=os.getenv("POSTGRES_PASSWORD", "smartlcl_dev_password"),
        autocommit=False,
    )

def compute_checksum(filepath: Path) -> str:
    hasher = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()

def run_migrations():
    migrations_dir = ROOT_DIR / "db" / "migrations"
    if not migrations_dir.exists():
        print(f"ERROR: Migrations directory {migrations_dir} does not exist.", file=sys.stderr)
        sys.exit(1)

    sql_files = sorted(migrations_dir.glob("*.sql"))
    if not sql_files:
        print(f"==> No SQL migrations found in {migrations_dir}.")
        return

    conn = get_connection()
    try:
        with conn.cursor() as cur:
            # 1. Ensure schema_migrations exists
            cur.execute("""
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version VARCHAR(255) PRIMARY KEY,
                    filename VARCHAR(255) NOT NULL,
                    checksum VARCHAR(64) NOT NULL,
                    applied_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
                );
            """)
            conn.commit()

            # 2. Fetch applied migrations
            cur.execute("SELECT version, filename, checksum FROM schema_migrations;")
            applied = {row[0]: {"filename": row[1], "checksum": row[2]} for row in cur.fetchall()}

            for filepath in sql_files:
                filename = filepath.name
                version = filename.split("_")[0]
                current_checksum = compute_checksum(filepath)

                if version in applied:
                    recorded_checksum = applied[version]["checksum"]
                    if recorded_checksum != current_checksum:
                        print(
                            f"FATAL: Checksum mismatch for migration version {version} ({filename})!\n"
                            f"  Recorded in DB: {recorded_checksum}\n"
                            f"  Current on disk: {current_checksum}\n"
                            f"Migrations must be immutable and forward-only.",
                            file=sys.stderr,
                        )
                        sys.exit(1)
                    else:
                        print(f"--> Skipping already-applied migration: {filename}")
                        continue

                print(f"==> Applying migration: {filename} (version {version})...")
                with open(filepath, "r", encoding="utf-8") as f:
                    sql_content = f.read()

                # Execute migration inside an atomic transaction
                cur.execute(sql_content)
                cur.execute(
                    """
                    INSERT INTO schema_migrations (version, filename, checksum)
                    VALUES (%s, %s, %s);
                    """,
                    (version, filename, current_checksum),
                )
                conn.commit()
                print(f"    Successfully applied {filename}")

        print("==> All migrations up to date.")
    except Exception as exc:
        conn.rollback()
        print(f"ERROR: Migration failed: {exc}", file=sys.stderr)
        sys.exit(1)
    finally:
        conn.close()

if __name__ == "__main__":
    run_migrations()

#!/usr/bin/env python3
"""
SmartLCL - Database Reset Utility (Python / Cross-Platform)
Drops and recreates the dev database, applies migrations, and optionally applies seeds.
"""

import argparse
import os
import sys
from pathlib import Path
from dotenv import load_dotenv
import psycopg

ROOT_DIR = Path(__file__).resolve().parent.parent
load_dotenv(ROOT_DIR / ".env")

def reset_database(run_seeds=False):
    db_name = os.getenv("POSTGRES_DB", "smartlcl_dev")
    user = os.getenv("POSTGRES_USER", "smartlcl_admin")
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = int(os.getenv("POSTGRES_PORT", "5432"))
    password = os.getenv("POSTGRES_PASSWORD", "smartlcl_dev_password")

    print(f"==> Resetting database '{db_name}' on {host}:{port}...")

    # Connect to default maintenance database 'postgres' with autocommit=True for DROP/CREATE DATABASE
    maint_conn = psycopg.connect(
        host=host,
        port=port,
        dbname="postgres",
        user=user,
        password=password,
        autocommit=True,
    )

    try:
        with maint_conn.cursor() as cur:
            # Terminate existing connections to target database
            cur.execute("""
                SELECT pg_terminate_backend(pid)
                FROM pg_stat_activity
                WHERE datname = %s AND pid <> pg_backend_pid();
            """, (db_name,))
            cur.execute(f'DROP DATABASE IF EXISTS "{db_name}";')
            cur.execute(f'CREATE DATABASE "{db_name}" OWNER "{user}";')
        print(f"==> Database '{db_name}' recreated successfully.")
    finally:
        maint_conn.close()

    # Import and run migrations
    sys.path.insert(0, str(ROOT_DIR / "scripts"))
    import migrate
    migrate.run_migrations()

    # Apply seeds if requested
    if run_seeds:
        seeds_dir = ROOT_DIR / "db" / "seeds"
        seed_files = sorted(seeds_dir.glob("*.sql"))
        if seed_files:
            print(f"==> Applying seeds from {seeds_dir}...")
            conn = migrate.get_connection()
            try:
                with conn.cursor() as cur:
                    for sfile in seed_files:
                        print(f"--> Applying seed: {sfile.name}...")
                        with open(sfile, "r", encoding="utf-8") as f:
                            cur.execute(f.read())
                        conn.commit()
                print("==> Seeds applied successfully.")
            finally:
                conn.close()
        else:
            print("--> No seed files found.")

    print("==> Database reset complete.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Reset SmartLCL database.")
    parser.add_argument("-s", "--seed", action="store_true", help="Apply seeds after reset.")
    args = parser.parse_args()
    reset_database(run_seeds=args.seed)

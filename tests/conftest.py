import os
from pathlib import Path
import pytest
import psycopg
from dotenv import load_dotenv

# Load .env from project root
ROOT_DIR = Path(__file__).resolve().parent.parent
load_dotenv(ROOT_DIR / ".env")

@pytest.fixture(scope="session")
def db_conn_params():
    """Extract connection parameters from environment variables with safe defaults."""
    return {
        "host": os.getenv("POSTGRES_HOST", "localhost"),
        "port": int(os.getenv("POSTGRES_PORT", "5432")),
        "dbname": os.getenv("POSTGRES_DB", "smartlcl_dev"),
        "user": os.getenv("POSTGRES_USER", "smartlcl_admin"),
        "password": os.getenv("POSTGRES_PASSWORD", "smartlcl_dev_password"),
    }

@pytest.fixture(scope="function")
def db_conn(db_conn_params):
    """Provide a fresh psycopg 3 database connection per test function."""
    conn = psycopg.connect(**db_conn_params)
    yield conn
    conn.close()

@pytest.fixture(scope="function")
def db_cursor(db_conn):
    """Provide a database cursor with automatic rollback after test completion."""
    with db_conn.cursor() as cur:
        yield cur
    db_conn.rollback()

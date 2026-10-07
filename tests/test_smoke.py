import pytest
import psycopg

def test_database_connection_and_select_1(db_cursor):
    """Assert direct connectivity and basic query execution."""
    db_cursor.execute("SELECT 1;")
    result = db_cursor.fetchone()
    assert result is not None
    assert result[0] == 1

def test_postgresql_version_is_18(db_cursor):
    """Assert that the running PostgreSQL instance is version 18.x."""
    db_cursor.execute("SHOW server_version;")
    version_str = db_cursor.fetchone()[0]
    assert version_str.startswith("18."), f"Expected PostgreSQL 18.x, found: {version_str}"

def test_schema_migrations_table_exists(db_cursor):
    """Assert schema_migrations table exists and has expected schema."""
    db_cursor.execute("""
        SELECT table_name 
        FROM information_schema.tables 
        WHERE table_schema = 'public' 
          AND table_name = 'schema_migrations';
    """)
    table = db_cursor.fetchone()
    assert table is not None, "Table 'schema_migrations' must exist in public schema."
    assert table[0] == "schema_migrations"

    # Verify columns in schema_migrations
    db_cursor.execute("""
        SELECT column_name, data_type 
        FROM information_schema.columns 
        WHERE table_name = 'schema_migrations'
        ORDER BY ordinal_position;
    """)
    columns = {col[0]: col[1] for col in db_cursor.fetchall()}
    assert "version" in columns
    assert "filename" in columns
    assert "checksum" in columns
    assert "applied_at" in columns

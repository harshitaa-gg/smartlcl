"""
SmartLCL - Sprint 2 Seed Data Verification Tests
Verifies row counts, provenance flags, actor naming invariants,
cargo category acceptance, edge cases, zero bookings, and seed idempotency.
"""

import re
import pytest
import psycopg
from pathlib import Path


@pytest.fixture(autouse=True, scope="module")
def ensure_seeds_applied(db_conn_params):
    """Ensure seeds are applied for seed tests, and clean table data on teardown."""
    conn = psycopg.connect(**db_conn_params)
    try:
        with conn.cursor() as cur:
            seeds_dir = Path(__file__).resolve().parent.parent / "db" / "seeds"
            for sfile in sorted(seeds_dir.glob("*.sql")):
                with open(sfile, "r", encoding="utf-8") as f:
                    cur.execute(f.read())
            conn.commit()
    finally:
        conn.close()

    yield

    # Teardown: truncate tables in reverse topological order so test_schema runs isolated
    conn = psycopg.connect(**db_conn_params)
    try:
        with conn.cursor() as cur:
            cur.execute("""
                TRUNCATE TABLE 
                    booking_audit, booking, shipment, rate, departure,
                    service_cargo_acceptance, lcl_service, trader, provider,
                    cargo_category, app_user, port
                CASCADE;
            """)
            conn.commit()
    finally:
        conn.close()


def test_seed_row_counts(db_conn):
    """Verify all seeded tables have the expected exact or minimum row counts."""
    with db_conn.cursor() as cur:
        # Ports
        cur.execute("SELECT COUNT(*) FROM port;")
        assert cur.fetchone()[0] == 16, "Expected exactly 16 seeded ports"

        # App Users & Actors
        cur.execute("SELECT COUNT(*) FROM app_user;")
        assert cur.fetchone()[0] == 15, "Expected 15 app_users (5 providers + 10 traders)"

        cur.execute("SELECT COUNT(*) FROM provider;")
        assert cur.fetchone()[0] == 5, "Expected exactly 5 providers"

        cur.execute("SELECT COUNT(*) FROM trader;")
        assert cur.fetchone()[0] == 10, "Expected exactly 10 traders"

        # Cargo Categories
        cur.execute("SELECT COUNT(*) FROM cargo_category;")
        assert cur.fetchone()[0] == 8, "Expected exactly 8 cargo categories"

        # Operational Services & Departures
        cur.execute("SELECT COUNT(*) FROM lcl_service;")
        assert cur.fetchone()[0] == 8, "Expected exactly 8 LCL services"

        cur.execute("SELECT COUNT(*) FROM departure;")
        assert cur.fetchone()[0] == 32, "Expected 32 departures (4 departures x 8 services)"

        # Shipments
        cur.execute("SELECT COUNT(*) FROM shipment;")
        assert cur.fetchone()[0] == 20, "Expected exactly 20 shipments"


def test_seed_provenance_data_origin(db_conn):
    """Verify port data_origin is REAL, while providers and traders are SYNTHETIC."""
    with db_conn.cursor() as cur:
        # All ports must be REAL
        cur.execute("SELECT COUNT(*) FROM port WHERE data_origin <> 'REAL';")
        assert cur.fetchone()[0] == 0, "All seeded ports must have data_origin = 'REAL'"

        # All providers must be SYNTHETIC
        cur.execute("SELECT COUNT(*) FROM provider WHERE data_origin <> 'SYNTHETIC';")
        assert cur.fetchone()[0] == 0, "All seeded providers must have data_origin = 'SYNTHETIC'"

        # All traders must be SYNTHETIC
        cur.execute("SELECT COUNT(*) FROM trader WHERE data_origin <> 'SYNTHETIC';")
        assert cur.fetchone()[0] == 0, "All seeded traders must have data_origin = 'SYNTHETIC'"


def test_seed_no_placeholder_naming(db_conn):
    """Ensure no synthetic names match carrier|port|route|user\\d+ case-insensitively."""
    pattern = re.compile(r"\b(carrier\d*|port\d*|route\d*|user\d+)\b", re.IGNORECASE)

    with db_conn.cursor() as cur:
        # Providers
        cur.execute("SELECT company_name FROM provider;")
        for (name,) in cur.fetchall():
            assert not pattern.search(name), f"Provider name '{name}' matched forbidden placeholder pattern"

        # Traders
        cur.execute("SELECT company_name FROM trader;")
        for (name,) in cur.fetchall():
            assert not pattern.search(name), f"Trader name '{name}' matched forbidden placeholder pattern"

        # Users
        cur.execute("SELECT full_name, email FROM app_user;")
        for full_name, email in cur.fetchall():
            assert not pattern.search(full_name), f"User full_name '{full_name}' matched forbidden placeholder pattern"
            assert not pattern.search(email), f"User email '{email}' matched forbidden placeholder pattern"


def test_seed_cargo_categories(db_conn):
    """Verify that all 8 required cargo categories exist with correct flags."""
    expected = {
        'GENERAL': (False, False),
        'TEXTILES': (False, False),
        'ELECTRONICS': (False, False),
        'MACHINERY_PARTS': (False, False),
        'PACKAGED_FOOD': (False, False),
        'NON_HAZ_CHEMICALS': (False, False),
        'HAZARDOUS_DG': (True, False),
        'PERISHABLES': (False, True),
    }

    with db_conn.cursor() as cur:
        cur.execute("SELECT code, is_dangerous, is_perishable FROM cargo_category;")
        rows = cur.fetchall()
        assert len(rows) == 8
        found = {row[0]: (row[1], row[2]) for row in rows}
        for code, flags in expected.items():
            assert code in found, f"Cargo category '{code}' missing"
            assert found[code] == flags, f"Cargo category '{code}' flags mismatch: got {found[code]}, expected {flags}"


def test_seed_services_and_acceptance(db_conn):
    """
    Verify the 8 services on realistic lanes and cargo acceptance variations:
    At least two services must refuse hazardous cargo.
    At least two services must refuse perishables.
    """
    with db_conn.cursor() as cur:
        # Check lane count
        cur.execute("""
            SELECT po.unlocode, pd.unlocode, COUNT(*)
            FROM lcl_service s
            JOIN port po ON po.id = s.origin_port_id
            JOIN port pd ON pd.id = s.dest_port_id
            GROUP BY po.unlocode, pd.unlocode;
        """)
        lane_counts = {(row[0], row[1]): row[2] for row in cur.fetchall()}

        # Chennai -> Singapore must have two providers
        assert lane_counts.get(('INMAA', 'SGSIN')) == 2, "Expected 2 providers for INMAA -> SGSIN lane"
        assert ('INTUT', 'LKCMB') in lane_counts
        assert ('INMUN', 'AEJEA') in lane_counts
        assert ('INNSA', 'NLRTM') in lane_counts
        assert ('INCOK', 'AEJEA') in lane_counts
        assert ('INVTZ', 'SGSIN') in lane_counts
        assert ('INCCU', 'MYPKG') in lane_counts

        # Services refusing hazardous cargo (DG)
        cur.execute("""
            SELECT s.id
            FROM lcl_service s
            WHERE NOT EXISTS (
                SELECT 1 FROM service_cargo_acceptance sca
                JOIN cargo_category c ON c.id = sca.category_id
                WHERE sca.service_id = s.id AND c.code = 'HAZARDOUS_DG'
            );
        """)
        refusing_dg = cur.fetchall()
        assert len(refusing_dg) >= 2, f"Expected at least 2 services refusing HAZARDOUS_DG, found {len(refusing_dg)}"

        # Services refusing perishables
        cur.execute("""
            SELECT s.id
            FROM lcl_service s
            WHERE NOT EXISTS (
                SELECT 1 FROM service_cargo_acceptance sca
                JOIN cargo_category c ON c.id = sca.category_id
                WHERE sca.service_id = s.id AND c.code = 'PERISHABLES'
            );
        """)
        refusing_perishables = cur.fetchall()
        assert len(refusing_perishables) >= 2, f"Expected at least 2 services refusing PERISHABLES, found {len(refusing_perishables)}"


def test_seed_rates_temporal_rules(db_conn):
    """
    Verify rates:
    - One service has two adjacent validity periods (price change).
    - One service has a deliberate rate validity gap.
    """
    with db_conn.cursor() as cur:
        # Check service with adjacent validity periods
        cur.execute("""
            SELECT s.id, COUNT(r.id)
            FROM lcl_service s
            JOIN rate r ON r.service_id = s.id
            GROUP BY s.id
            HAVING COUNT(r.id) > 1;
        """)
        multi_rate_services = cur.fetchall()
        assert len(multi_rate_services) >= 2, "Expected at least 2 services with multiple rate periods"

        # Check for adjacent periods
        cur.execute("""
            SELECT r1.service_id, r1.validity, r2.validity
            FROM rate r1
            JOIN rate r2 ON r1.service_id = r2.service_id AND upper(r1.validity) = lower(r2.validity);
        """)
        adjacent = cur.fetchall()
        assert len(adjacent) >= 1, "Expected at least one service with adjacent rate validity periods"

        # Check for gap between periods
        cur.execute("""
            SELECT r1.service_id, upper(r1.validity), lower(r2.validity)
            FROM rate r1
            JOIN rate r2 ON r1.service_id = r2.service_id AND upper(r1.validity) < lower(r2.validity);
        """)
        gaps = cur.fetchall()
        assert len(gaps) >= 1, "Expected at least one service with a deliberate rate validity gap"


def test_seed_edge_cases(db_conn):
    """
    Verify the 5 documented edge cases:
    1. One departure with exactly 10 CBM and 10,000 kg capacity (for concurrency demo).
    2. One departure whose cut-off has already passed relative to anchor date 2026-10-12.
    3. One CANCELLED departure.
    4. One shipment whose cargo category is refused by a relevant service.
    5. One shipment whose weight is high enough that weight is binding capacity limit.
    """
    with db_conn.cursor() as cur:
        # Edge Case 1: Departure with exactly 10.000 CBM and 10000.00 kg
        cur.execute("""
            SELECT COUNT(*) FROM departure
            WHERE capacity_cbm = 10.000 AND capacity_weight_kg = 10000.00;
        """)
        assert cur.fetchone()[0] >= 1, "Edge Case 1 missing: Departure with exactly 10 CBM and 10,000 kg"

        # Edge Case 2: Departure cutoff before anchor date 2026-10-12
        cur.execute("""
            SELECT COUNT(*) FROM departure
            WHERE cutoff_at < '2026-10-12 00:00:00+00'::timestamptz;
        """)
        assert cur.fetchone()[0] >= 1, "Edge Case 2 missing: Departure with cutoff passed relative to anchor date"

        # Edge Case 3: CANCELLED departure
        cur.execute("""
            SELECT COUNT(*) FROM departure
            WHERE status = 'CANCELLED';
        """)
        assert cur.fetchone()[0] >= 1, "Edge Case 3 missing: CANCELLED departure"

        # Edge Case 4: Shipment with refused cargo category on a service lane
        cur.execute("""
            SELECT sh.id, c.code, s.id
            FROM shipment sh
            JOIN cargo_category c ON c.id = sh.category_id
            JOIN lcl_service s ON s.origin_port_id = sh.origin_port_id AND s.dest_port_id = sh.dest_port_id
            WHERE NOT EXISTS (
                SELECT 1 FROM service_cargo_acceptance sca
                WHERE sca.service_id = s.id AND sca.category_id = c.id
            );
        """)
        refused_shipments = cur.fetchall()
        assert len(refused_shipments) >= 1, "Edge Case 4 missing: Shipment refused by a service on its lane"

        # Edge Case 5: Weight is binding capacity limit (weight_kg / 1000.0 > cbm)
        cur.execute("""
            SELECT COUNT(*) FROM shipment
            WHERE (weight_kg / 1000.0) >= (cbm * 2.0);
        """)
        assert cur.fetchone()[0] >= 1, "Edge Case 5 missing: Weight-dominant binding capacity shipment"


def test_seed_zero_bookings(db_conn):
    """Confirm zero bookings exist after seeding (bookings only created in Sprint 4)."""
    with db_conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM booking;")
        assert cur.fetchone()[0] == 0, "No bookings should exist after running seeds"

        cur.execute("SELECT COUNT(*) FROM booking_audit;")
        assert cur.fetchone()[0] == 0, "No booking audit records should exist after running seeds"


def test_seed_idempotency_double_run(db_conn):
    """Running all seed scripts a second time must produce identical row counts."""
    seeds_dir = Path(__file__).resolve().parent.parent / "db" / "seeds"
    seed_files = sorted(seeds_dir.glob("*.sql"))

    with db_conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM port;")
        port_count_before = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*) FROM shipment;")
        shipment_count_before = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*) FROM departure;")
        departure_count_before = cur.fetchone()[0]

        # Re-execute all seeds
        for sfile in seed_files:
            with open(sfile, "r", encoding="utf-8") as f:
                cur.execute(f.read())

        cur.execute("SELECT COUNT(*) FROM port;")
        assert cur.fetchone()[0] == port_count_before, "Port count changed after re-running seed"

        cur.execute("SELECT COUNT(*) FROM shipment;")
        assert cur.fetchone()[0] == shipment_count_before, "Shipment count changed after re-running seed"

        cur.execute("SELECT COUNT(*) FROM departure;")
        assert cur.fetchone()[0] == departure_count_before, "Departure count changed after re-running seed"

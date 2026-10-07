"""
SmartLCL - Sprint 4 Transaction-Safe Booking Engine Tests
Validates:
1. Successful booking creation with correct historical snapshots.
2. Historical price snapshot immutability across rate table changes.
3. Exact capacity edge cases (exact match vs 1 unit over CBM/weight).
4. Failure paths SL001 through SL009 asserting exact SQLSTATE.
5. Availability derivation after booking and cancellation.
6. Rollback-proof testing ensuring aborted bookings leave zero residual state.
7. Booking state machine transitions (confirm_booking, cancel_booking).
All tests execute in transaction-isolated fixtures that roll back.
"""

from decimal import Decimal
import pytest
import psycopg
from psycopg import errors


# ==============================================================================
# Test Fixture Setup
# ==============================================================================

@pytest.fixture
def booking_env(db_cursor):
    """
    Creates an isolated set of ports, users, provider, trader, service,
    rate, and departure for booking tests.
    """
    # 1. Ports
    db_cursor.execute("""
        INSERT INTO port (unlocode, name, country_code, data_origin)
        VALUES ('BKAAA', 'Booking Port Alpha', 'IN', 'SYNTHETIC'),
               ('BKBBB', 'Booking Port Bravo', 'SG', 'SYNTHETIC'),
               ('BKCCC', 'Booking Port Charlie', 'NL', 'SYNTHETIC')
        RETURNING id;
    """)
    port_a = db_cursor.fetchone()[0]
    port_b = db_cursor.fetchone()[0]
    port_c = db_cursor.fetchone()[0]

    # 2. Categories
    db_cursor.execute("""
        INSERT INTO cargo_category (code, name, is_dangerous, is_perishable)
        VALUES ('BKGEN', 'General Test Cargo', FALSE, FALSE),
               ('BKHAZ', 'Dangerous Test Cargo', TRUE, FALSE)
        RETURNING id;
    """)
    cat_gen = db_cursor.fetchone()[0]
    cat_haz = db_cursor.fetchone()[0]

    # 3. Users & Actors
    db_cursor.execute("""
        INSERT INTO app_user (email, full_name)
        VALUES ('bk_prov@example.com', 'Booking Provider User'),
               ('bk_trader@example.com', 'Booking Trader User')
        RETURNING id;
    """)
    u_prov = db_cursor.fetchone()[0]
    u_trader = db_cursor.fetchone()[0]

    db_cursor.execute("""
        INSERT INTO provider (app_user_id, company_name, data_origin)
        VALUES (%s, 'Booking Test Lines', 'SYNTHETIC')
        RETURNING id;
    """, (u_prov,))
    prov_id = db_cursor.fetchone()[0]

    db_cursor.execute("""
        INSERT INTO trader (app_user_id, company_name, home_city, data_origin)
        VALUES (%s, 'Booking Test Merchant', 'Chennai', 'SYNTHETIC')
        RETURNING id;
    """, (u_trader,))
    trader_id = db_cursor.fetchone()[0]

    # 4. Service (A -> B, only accepts BKGEN)
    db_cursor.execute("""
        INSERT INTO lcl_service (provider_id, origin_port_id, dest_port_id, transit_days, is_active)
        VALUES (%s, %s, %s, 5, TRUE)
        RETURNING id;
    """, (prov_id, port_a, port_b))
    service_id = db_cursor.fetchone()[0]

    db_cursor.execute("""
        INSERT INTO service_cargo_acceptance (service_id, category_id)
        VALUES (%s, %s);
    """, (service_id, cat_gen))

    # 5. Rate (85.00 USD)
    db_cursor.execute("""
        INSERT INTO rate (service_id, rate_per_wm, currency, validity)
        VALUES (%s, 85.00, 'USD', '[2026-10-01, 2026-10-31]'::daterange)
        RETURNING id;
    """, (service_id,))
    rate_id = db_cursor.fetchone()[0]

    # 6. Departure (Capacity 20.0 CBM, 15,000 kg; Cutoff 2026-10-18)
    db_cursor.execute("""
        INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg, status)
        VALUES (%s, '2026-10-20 10:00:00+00', '2026-10-25 14:00:00+00', '2026-10-18 18:00:00+00', 20.000, 15000.00, 'SCHEDULED')
        RETURNING id;
    """, (service_id,))
    dep_id = db_cursor.fetchone()[0]

    # Helper function to create shipment
    def make_shipment(cbm=5.0, weight=3000.0, cat=cat_gen, orig=port_a, dest=port_b):
        db_cursor.execute("""
            INSERT INTO shipment (trader_id, origin_port_id, dest_port_id, category_id, cbm, weight_kg, cargo_ready_date, description)
            VALUES (%s, %s, %s, %s, %s, %s, '2026-10-15', 'Test shipment')
            RETURNING id;
        """, (trader_id, orig, dest, cat, cbm, weight))
        return db_cursor.fetchone()[0]

    return {
        "port_a": port_a,
        "port_b": port_b,
        "port_c": port_c,
        "cat_gen": cat_gen,
        "cat_haz": cat_haz,
        "service_id": service_id,
        "rate_id": rate_id,
        "dep_id": dep_id,
        "make_shipment": make_shipment,
        "as_of": "2026-10-12 09:00:00+00"
    }


# ==============================================================================
# 1. Successful Booking & Historical Snapshot Tests
# ==============================================================================

def test_successful_booking_creation(db_cursor, booking_env):
    """Booking within capacity succeeds, creates PENDING status, and records snapshot."""
    env = booking_env
    # 6.0 CBM, 4000.0 kg => chargeable_qty = 6.0 (CBM wins)
    # Rate = 85.00 => quoted_total = 6.0 * 85.00 = 510.00
    sh_id = env["make_shipment"](cbm=6.0, weight=4000.0)

    db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_id, env["dep_id"], env["as_of"]))
    bk_id = db_cursor.fetchone()[0]
    assert bk_id is not None

    db_cursor.execute("""
        SELECT shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg,
               chargeable_qty, quoted_rate, quoted_currency, quoted_total
        FROM booking
        WHERE id = %s;
    """, (bk_id,))
    row = db_cursor.fetchone()
    assert row[0] == sh_id
    assert row[1] == env["dep_id"]
    assert row[2] == "PENDING"
    assert row[3] == Decimal("6.000")
    assert row[4] == Decimal("4000.00")
    assert row[5] == Decimal("6.000")
    assert row[6] == Decimal("85.00")
    assert row[7] == "USD"
    assert row[8] == Decimal("510.00")

    # Confirm audit log entry created
    db_cursor.execute("SELECT old_status, new_status FROM booking_audit WHERE booking_id = %s;", (bk_id,))
    audit = db_cursor.fetchone()
    assert audit == (None, "PENDING")


def test_historical_snapshot_immutability(db_cursor, booking_env):
    """Booking price and rate snapshot remains unaltered when underlying rate changes."""
    env = booking_env
    sh_id = env["make_shipment"](cbm=10.0, weight=5000.0)

    db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_id, env["dep_id"], env["as_of"]))
    bk_id = db_cursor.fetchone()[0]

    # Mutate rate table
    db_cursor.execute("UPDATE rate SET rate_per_wm = 999.00 WHERE id = %s;", (env["rate_id"],))

    # Re-read booking
    db_cursor.execute("SELECT quoted_rate, quoted_total, quoted_currency FROM booking WHERE id = %s;", (bk_id,))
    row = db_cursor.fetchone()
    assert row[0] == Decimal("85.00"), "Quoted rate must remain unchanged"
    assert row[1] == Decimal("850.00"), "Quoted total must remain unchanged"
    assert row[2] == "USD"


def test_exact_capacity_booking_succeeds_and_over_fails(db_cursor, booking_env):
    """Booking that consumes 100% of remaining CBM and weight succeeds; 1 unit over fails."""
    env = booking_env
    # Exact: 20.0 CBM, 15000.0 kg
    sh_exact = env["make_shipment"](cbm=20.0, weight=15000.0)
    db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_exact, env["dep_id"], env["as_of"]))
    assert db_cursor.fetchone()[0] is not None

    # Next booking: 0.001 CBM over capacity
    sh_over = env["make_shipment"](cbm=0.001, weight=10.0)
    with pytest.raises(errors.DatabaseError) as exc:
        db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_over, env["dep_id"], env["as_of"]))
    assert exc.value.sqlstate == "SL006"


def test_weight_only_failure_sl007(db_cursor, booking_env):
    """Shipment fits CBM but exceeds weight capacity => SL007."""
    env = booking_env
    # 5.0 CBM (fits in 20.0), 16,000 kg (exceeds 15,000 kg)
    sh_heavy = env["make_shipment"](cbm=5.0, weight=16000.0)
    with pytest.raises(errors.DatabaseError) as exc:
        db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_heavy, env["dep_id"], env["as_of"]))
    assert exc.value.sqlstate == "SL007"


# ==============================================================================
# 2. Failure Path Tests (SL001 - SL009)
# ==============================================================================

@pytest.mark.parametrize("status", ["CLOSED", "CANCELLED", "DEPARTED"])
def test_sl001_departure_not_scheduled(db_cursor, booking_env, status):
    """Non-SCHEDULED departure fails with SL001."""
    env = booking_env
    db_cursor.execute("UPDATE departure SET status = %s WHERE id = %s;", (status, env["dep_id"]))
    sh_id = env["make_shipment"]()
    with pytest.raises(errors.DatabaseError) as exc:
        db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_id, env["dep_id"], env["as_of"]))
    assert exc.value.sqlstate == "SL001"


def test_sl002_cutoff_passed(db_cursor, booking_env):
    """Booking timestamp at or after cutoff fails with SL002."""
    env = booking_env
    sh_id = env["make_shipment"]()
    # Cutoff is 2026-10-18 18:00:00+00
    with pytest.raises(errors.DatabaseError) as exc:
        db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_id, env["dep_id"], "2026-10-18 18:00:00+00"))
    assert exc.value.sqlstate == "SL002"


def test_sl003_lane_mismatch(db_cursor, booking_env):
    """Shipment destination port does not match service lane => SL003."""
    env = booking_env
    sh_mismatch = env["make_shipment"](dest=env["port_c"]) # Service is A -> B
    with pytest.raises(errors.DatabaseError) as exc:
        db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_mismatch, env["dep_id"], env["as_of"]))
    assert exc.value.sqlstate == "SL003"


def test_sl004_cargo_category_refused(db_cursor, booking_env):
    """Cargo category not accepted by service => SL004."""
    env = booking_env
    sh_haz = env["make_shipment"](cat=env["cat_haz"]) # Service only accepts BKGEN
    with pytest.raises(errors.DatabaseError) as exc:
        db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_haz, env["dep_id"], env["as_of"]))
    assert exc.value.sqlstate == "SL004"


def test_sl005_shipment_already_allocated(db_cursor, booking_env):
    """Attempting to book a shipment that already has a capacity-holding booking => SL005."""
    env = booking_env
    sh_id = env["make_shipment"](cbm=4.0, weight=2000.0)

    # First booking succeeds
    db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_id, env["dep_id"], env["as_of"]))

    # Second booking attempt for same shipment fails with SL005
    with pytest.raises(errors.DatabaseError) as exc:
        db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_id, env["dep_id"], env["as_of"]))
    assert exc.value.sqlstate == "SL005"


def test_sl008_no_applicable_rate(db_cursor, booking_env):
    """Departure with no applicable rate for its ETD => SL008."""
    env = booking_env
    db_cursor.execute("DELETE FROM rate WHERE service_id = %s;", (env["service_id"],))
    sh_id = env["make_shipment"]()
    with pytest.raises(errors.DatabaseError) as exc:
        db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_id, env["dep_id"], env["as_of"]))
    assert exc.value.sqlstate == "SL008"


def test_sl009_missing_departure(db_cursor, booking_env):
    """Missing departure raises SL009."""
    env = booking_env
    sh_id = env["make_shipment"]()
    with pytest.raises(errors.DatabaseError) as exc:
        db_cursor.execute("SELECT create_booking(%s, 999999, %s);", (sh_id, env["as_of"]))
    assert exc.value.sqlstate == "SL009"


def test_sl009_missing_shipment(db_cursor, booking_env):
    """Missing shipment raises SL009."""
    env = booking_env
    with pytest.raises(errors.DatabaseError) as exc:
        db_cursor.execute("SELECT create_booking(999999, %s, %s);", (env["dep_id"], env["as_of"]))
    assert exc.value.sqlstate == "SL009"


# ==============================================================================
# 3. Availability Derivation After Booking & Cancellation
# ==============================================================================

def test_availability_after_booking_and_cancellation(db_cursor, booking_env):
    """Availability dynamically decreases on booking and restores on cancellation."""
    env = booking_env
    dep_id = env["dep_id"]

    # Initial availability: 20.0 CBM, 15,000 kg, 0% utilisation
    db_cursor.execute("SELECT remaining_cbm, remaining_weight_kg, utilisation_pct FROM v_departure_availability WHERE departure_id = %s;", (dep_id,))
    assert db_cursor.fetchone() == (Decimal("20.000"), Decimal("15000.00"), Decimal("0.00"))

    # Book 10.0 CBM, 7,500 kg
    sh_id = env["make_shipment"](cbm=10.0, weight=7500.0)
    db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_id, dep_id, env["as_of"]))
    bk_id = db_cursor.fetchone()[0]

    # Availability decreased: remaining 10.0 CBM, 7,500 kg, 50% utilisation
    db_cursor.execute("SELECT remaining_cbm, remaining_weight_kg, utilisation_pct FROM v_departure_availability WHERE departure_id = %s;", (dep_id,))
    assert db_cursor.fetchone() == (Decimal("10.000"), Decimal("7500.00"), Decimal("50.00"))

    # Cancel booking
    db_cursor.execute("SELECT cancel_booking(%s);", (bk_id,))

    # Availability fully restored
    db_cursor.execute("SELECT remaining_cbm, remaining_weight_kg, utilisation_pct FROM v_departure_availability WHERE departure_id = %s;", (dep_id,))
    assert db_cursor.fetchone() == (Decimal("20.000"), Decimal("15000.00"), Decimal("0.00"))


# ==============================================================================
# 4. Mandatory Rollback Proof Tests
# ==============================================================================

@pytest.mark.parametrize("error_scenario, expected_sqlstate", [
    ("cbm_overflow", "SL006"),
    ("weight_overflow", "SL007"),
    ("refused_category", "SL004"),
    ("lane_mismatch", "SL003")
])
def test_rollback_proof_on_booking_failure(db_conn, booking_env, error_scenario, expected_sqlstate):
    """
    Mandatory proof: A failed create_booking call leaves zero residual rows or state changes.
    Uses SAVEPOINT to recover from expected exception and verify database state.
    """
    env = booking_env
    dep_id = env["dep_id"]

    with db_conn.cursor() as cur:
        # Record pre-call state
        cur.execute("SELECT count(*) FROM booking;")
        count_before = cur.fetchone()[0]

        cur.execute("SELECT remaining_cbm, remaining_weight_kg FROM v_departure_availability WHERE departure_id = %s;", (dep_id,))
        avail_before = cur.fetchone()

        # Prepare failing shipment
        if error_scenario == "cbm_overflow":
            sh_fail = env["make_shipment"](cbm=25.0, weight=5000.0)
        elif error_scenario == "weight_overflow":
            sh_fail = env["make_shipment"](cbm=5.0, weight=25000.0)
        elif error_scenario == "refused_category":
            sh_fail = env["make_shipment"](cat=env["cat_haz"])
        elif error_scenario == "lane_mismatch":
            sh_fail = env["make_shipment"](dest=env["port_c"])

        # Execute inside savepoint
        cur.execute("SAVEPOINT sp_booking_test;")
        with pytest.raises(errors.DatabaseError) as exc:
            cur.execute("SELECT create_booking(%s, %s, %s);", (sh_fail, dep_id, env["as_of"]))
        assert exc.value.sqlstate == expected_sqlstate

        # Roll back to savepoint
        cur.execute("ROLLBACK TO SAVEPOINT sp_booking_test;")

        # Verify post-call state is strictly identical
        cur.execute("SELECT count(*) FROM booking;")
        assert cur.fetchone()[0] == count_before, "Booking count must not change on failure"

        cur.execute("SELECT remaining_cbm, remaining_weight_kg FROM v_departure_availability WHERE departure_id = %s;", (dep_id,))
        assert cur.fetchone() == avail_before, "Departure availability must not change on failure"


# ==============================================================================
# 5. Booking State Machine Transitions
# ==============================================================================

def test_booking_state_machine_valid_transitions(db_cursor, booking_env):
    """Valid transitions: PENDING -> CONFIRMED -> CANCELLED."""
    env = booking_env
    sh_id = env["make_shipment"](cbm=3.0, weight=1500.0)

    db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_id, env["dep_id"], env["as_of"]))
    bk_id = db_cursor.fetchone()[0]

    # 1. PENDING -> CONFIRMED
    db_cursor.execute("SELECT confirm_booking(%s);", (bk_id,))
    db_cursor.execute("SELECT status FROM booking WHERE id = %s;", (bk_id,))
    assert db_cursor.fetchone()[0] == "CONFIRMED"

    # 2. CONFIRMED -> CANCELLED
    db_cursor.execute("SELECT cancel_booking(%s);", (bk_id,))
    db_cursor.execute("SELECT status FROM booking WHERE id = %s;", (bk_id,))
    assert db_cursor.fetchone()[0] == "CANCELLED"


def test_booking_state_machine_invalid_transitions(db_cursor, booking_env):
    """Invalid transitions: CANCELLED -> CONFIRMED, CANCELLED -> CANCELLED must fail."""
    env = booking_env
    sh_id = env["make_shipment"](cbm=3.0, weight=1500.0)

    db_cursor.execute("SELECT create_booking(%s, %s, %s);", (sh_id, env["dep_id"], env["as_of"]))
    bk_id = db_cursor.fetchone()[0]

    # PENDING -> CANCELLED
    db_cursor.execute("SELECT cancel_booking(%s);", (bk_id,))

    # CANCELLED -> CONFIRMED must fail
    with pytest.raises(errors.DatabaseError):
        db_cursor.execute("SELECT confirm_booking(%s);", (bk_id,))

    # CANCELLED -> CANCELLED must fail
    with pytest.raises(errors.DatabaseError):
        db_cursor.execute("SELECT cancel_booking(%s);", (bk_id,))

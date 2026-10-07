"""
SmartLCL - Sprint 3 Availability and Search Tests
Validates:
1. chargeable_qty() single source of truth formula.
2. Availability views (v_departure_allocation, v_departure_availability) with:
   - Zero bookings
   - PENDING & CONFIRMED capacity depletion
   - CANCELLED & REJECTED non-depletion
   - Exactly-full departure (utilisation 100%, remaining 0)
3. get_applicable_rate() temporal daterange resolution:
   - Inside validity, first day, last day, adjacent boundary, deliberate gap.
4. search_departures() multi-constraint exclusion rules:
   - Wrong lane, inactive service, non-SCHEDULED departure, passed cutoff,
     cargo ready date after cutoff date, refused cargo category, CBM too large,
     weight too large, no applicable rate.
   - Fully feasible departure returned with expected attributes.
   - Ordering by estimated_total ASC, then ETD ASC.
   - Impossible request returns 0 rows.
5. Execution of all 5 demonstration queries from db/queries/search_demos.sql.
All tests run inside rolled-back transactions without permanently polluting seed data.
"""

from decimal import Decimal
from pathlib import Path
import pytest
import psycopg


# ==============================================================================
# 1. chargeable_qty() Tests
# ==============================================================================

def test_chargeable_qty_cbm_wins(db_cursor):
    """CBM > weight_kg / 1000.0 => CBM wins."""
    # 15.0 CBM, 8000 kg (8.0 t) => 15.0
    db_cursor.execute("SELECT chargeable_qty(15.0, 8000.0);")
    assert db_cursor.fetchone()[0] == Decimal("15.0")


def test_chargeable_qty_weight_wins(db_cursor):
    """weight_kg / 1000.0 > CBM => converted weight wins."""
    # 5.0 CBM, 12000 kg (12.0 t) => 12.0
    db_cursor.execute("SELECT chargeable_qty(5.0, 12000.0);")
    assert db_cursor.fetchone()[0] == Decimal("12.0")


def test_chargeable_qty_equal(db_cursor):
    """CBM == weight_kg / 1000.0 => returns either exact value."""
    # 10.0 CBM, 10000 kg (10.0 t) => 10.0
    db_cursor.execute("SELECT chargeable_qty(10.0, 10000.0);")
    assert db_cursor.fetchone()[0] == Decimal("10.0")


# ==============================================================================
# 2. Availability View Tests
# ==============================================================================

@pytest.fixture
def base_test_setup(db_cursor):
    """
    Sets up a clean isolated provider, ports, service, departure, and trader/shipment
    inside the test transaction for deterministic availability assertions.
    """
    # 1. Ports
    db_cursor.execute("""
        INSERT INTO port (unlocode, name, country_code, data_origin)
        VALUES ('XXAAA', 'Port Test Alpha', 'IN', 'SYNTHETIC'),
               ('XXBBB', 'Port Test Bravo', 'SG', 'SYNTHETIC')
        RETURNING id;
    """)
    port_a_id = db_cursor.fetchone()[0]
    port_b_id = db_cursor.fetchone()[0]

    # 2. Category
    db_cursor.execute("""
        INSERT INTO cargo_category (code, name, is_dangerous, is_perishable)
        VALUES ('TESTCAT', 'Test Cargo Category', FALSE, FALSE)
        RETURNING id;
    """)
    cat_id = db_cursor.fetchone()[0]

    # 3. Provider & User
    db_cursor.execute("""
        INSERT INTO app_user (email, full_name)
        VALUES ('prov_test@example.com', 'Test Provider User'),
               ('trader_test@example.com', 'Test Trader User')
        RETURNING id;
    """)
    p_user_id = db_cursor.fetchone()[0]
    t_user_id = db_cursor.fetchone()[0]

    db_cursor.execute("""
        INSERT INTO provider (app_user_id, company_name, data_origin)
        VALUES (%s, 'Test Ocean Lines', 'SYNTHETIC')
        RETURNING id;
    """, (p_user_id,))
    prov_id = db_cursor.fetchone()[0]

    db_cursor.execute("""
        INSERT INTO trader (app_user_id, company_name, home_city, data_origin)
        VALUES (%s, 'Test Merchant Co', 'Chennai', 'SYNTHETIC')
        RETURNING id;
    """, (t_user_id,))
    trader_id = db_cursor.fetchone()[0]

    # 4. Service
    db_cursor.execute("""
        INSERT INTO lcl_service (provider_id, origin_port_id, dest_port_id, transit_days, is_active)
        VALUES (%s, %s, %s, 5, TRUE)
        RETURNING id;
    """, (prov_id, port_a_id, port_b_id))
    service_id = db_cursor.fetchone()[0]

    db_cursor.execute("""
        INSERT INTO service_cargo_acceptance (service_id, category_id)
        VALUES (%s, %s);
    """, (service_id, cat_id))

    # 5. Departure: 50.0 CBM, 30,000 kg capacity
    db_cursor.execute("""
        INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg, status)
        VALUES (%s, '2026-10-20 10:00:00+00', '2026-10-25 14:00:00+00', '2026-10-17 18:00:00+00', 50.000, 30000.00, 'SCHEDULED')
        RETURNING id;
    """, (service_id,))
    dep_id = db_cursor.fetchone()[0]

    # 6. Rate: 80.00 USD
    db_cursor.execute("""
        INSERT INTO rate (service_id, rate_per_wm, currency, validity)
        VALUES (%s, 80.00, 'USD', '[2026-10-01, 2026-10-31]'::daterange);
    """, (service_id,))

    # 7. Shipment
    db_cursor.execute("""
        INSERT INTO shipment (trader_id, origin_port_id, dest_port_id, category_id, cbm, weight_kg, cargo_ready_date, description)
        VALUES (%s, %s, %s, %s, 10.000, 6000.00, '2026-10-15', 'Test shipment')
        RETURNING id;
    """, (trader_id, port_a_id, port_b_id, cat_id))
    shipment_id = db_cursor.fetchone()[0]

    return {
        "port_a_id": port_a_id,
        "port_b_id": port_b_id,
        "cat_id": cat_id,
        "prov_id": prov_id,
        "trader_id": trader_id,
        "service_id": service_id,
        "dep_id": dep_id,
        "shipment_id": shipment_id
    }


def test_availability_no_bookings(db_cursor, base_test_setup):
    """Departure with no bookings has remaining == capacity and 0% utilisation."""
    dep_id = base_test_setup["dep_id"]
    db_cursor.execute("""
        SELECT capacity_cbm, allocated_cbm, remaining_cbm,
               capacity_weight_kg, allocated_weight_kg, remaining_weight_kg,
               utilisation_pct
        FROM v_departure_availability
        WHERE departure_id = %s;
    """, (dep_id,))
    row = db_cursor.fetchone()
    assert row[0] == Decimal("50.000")
    assert row[1] == Decimal("0.000")
    assert row[2] == Decimal("50.000")
    assert row[3] == Decimal("30000.00")
    assert row[4] == Decimal("0.00")
    assert row[5] == Decimal("30000.00")
    assert row[6] == Decimal("0.00")


def test_availability_pending_booking_reduces_capacity(db_cursor, base_test_setup):
    """PENDING booking is capacity-holding and reduces both CBM and weight."""
    dep_id = base_test_setup["dep_id"]
    shipment_id = base_test_setup["shipment_id"]

    db_cursor.execute("""
        INSERT INTO booking (shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg,
                             chargeable_qty, quoted_rate, quoted_currency, quoted_total)
        VALUES (%s, %s, 'PENDING', 10.000, 6000.00, 10.000, 80.00, 'USD', 800.00);
    """, (shipment_id, dep_id))

    db_cursor.execute("""
        SELECT allocated_cbm, remaining_cbm, allocated_weight_kg, remaining_weight_kg, utilisation_pct
        FROM v_departure_availability
        WHERE departure_id = %s;
    """, (dep_id,))
    row = db_cursor.fetchone()
    assert row[0] == Decimal("10.000")
    assert row[1] == Decimal("40.000")
    assert row[2] == Decimal("6000.00")
    assert row[3] == Decimal("24000.00")
    # Utilisation = max(10/50 = 0.20, 6000/30000 = 0.20) * 100 = 20.00%
    assert row[4] == Decimal("20.00")


def test_availability_confirmed_booking_reduces_capacity(db_cursor, base_test_setup):
    """CONFIRMED booking is capacity-holding and reduces capacity."""
    dep_id = base_test_setup["dep_id"]
    shipment_id = base_test_setup["shipment_id"]

    db_cursor.execute("""
        INSERT INTO booking (shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg,
                             chargeable_qty, quoted_rate, quoted_currency, quoted_total)
        VALUES (%s, %s, 'CONFIRMED', 25.000, 12000.00, 25.000, 80.00, 'USD', 2000.00);
    """, (shipment_id, dep_id))

    db_cursor.execute("""
        SELECT allocated_cbm, remaining_cbm, allocated_weight_kg, remaining_weight_kg, utilisation_pct
        FROM v_departure_availability
        WHERE departure_id = %s;
    """, (dep_id,))
    row = db_cursor.fetchone()
    assert row[0] == Decimal("25.000")
    assert row[1] == Decimal("25.000")
    assert row[2] == Decimal("12000.00")
    assert row[3] == Decimal("18000.00")
    # Utilisation = max(25/50 = 0.50, 12000/30000 = 0.40) * 100 = 50.00%
    assert row[4] == Decimal("50.00")


def test_availability_cancelled_booking_does_not_reduce_capacity(db_cursor, base_test_setup):
    """CANCELLED booking does not consume capacity."""
    dep_id = base_test_setup["dep_id"]
    shipment_id = base_test_setup["shipment_id"]

    db_cursor.execute("""
        INSERT INTO booking (shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg,
                             chargeable_qty, quoted_rate, quoted_currency, quoted_total)
        VALUES (%s, %s, 'CANCELLED', 20.000, 10000.00, 20.000, 80.00, 'USD', 1600.00);
    """, (shipment_id, dep_id))

    db_cursor.execute("""
        SELECT allocated_cbm, remaining_cbm, utilisation_pct
        FROM v_departure_availability
        WHERE departure_id = %s;
    """, (dep_id,))
    row = db_cursor.fetchone()
    assert row[0] == Decimal("0.000")
    assert row[1] == Decimal("50.000")
    assert row[2] == Decimal("0.00")


def test_availability_rejected_booking_does_not_reduce_capacity(db_cursor, base_test_setup):
    """REJECTED booking does not consume capacity."""
    dep_id = base_test_setup["dep_id"]
    shipment_id = base_test_setup["shipment_id"]

    db_cursor.execute("""
        INSERT INTO booking (shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg,
                             chargeable_qty, quoted_rate, quoted_currency, quoted_total)
        VALUES (%s, %s, 'REJECTED', 20.000, 10000.00, 20.000, 80.00, 'USD', 1600.00);
    """, (shipment_id, dep_id))

    db_cursor.execute("""
        SELECT allocated_cbm, remaining_cbm, utilisation_pct
        FROM v_departure_availability
        WHERE departure_id = %s;
    """, (dep_id,))
    row = db_cursor.fetchone()
    assert row[0] == Decimal("0.000")
    assert row[1] == Decimal("50.000")
    assert row[2] == Decimal("0.00")


def test_availability_exactly_full_departure(db_cursor, base_test_setup):
    """Exactly full departure has remaining = 0 and utilisation = 100%."""
    dep_id = base_test_setup["dep_id"]
    shipment_id = base_test_setup["shipment_id"]

    db_cursor.execute("""
        INSERT INTO booking (shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg,
                             chargeable_qty, quoted_rate, quoted_currency, quoted_total)
        VALUES (%s, %s, 'CONFIRMED', 50.000, 30000.00, 50.000, 80.00, 'USD', 4000.00);
    """, (shipment_id, dep_id))

    db_cursor.execute("""
        SELECT remaining_cbm, remaining_weight_kg, utilisation_pct
        FROM v_departure_availability
        WHERE departure_id = %s;
    """, (dep_id,))
    row = db_cursor.fetchone()
    assert row[0] == Decimal("0.000")
    assert row[1] == Decimal("0.00")
    assert row[2] == Decimal("100.00")


# ==============================================================================
# 3. get_applicable_rate() Tests
# ==============================================================================

@pytest.fixture
def rate_test_service(db_cursor, base_test_setup):
    """Sets up a service with adjacent rate periods and a deliberate gap."""
    service_id = base_test_setup["service_id"]
    # Clear initial rate
    db_cursor.execute("DELETE FROM rate WHERE service_id = %s;", (service_id,))

    # Period 1: [2026-10-01, 2026-10-15) @ $50.00
    # Period 2: [2026-10-15, 2026-10-25) @ $60.00 (Adjacent)
    # Deliberate Gap: 2026-10-25 to 2026-10-28 has NO rate
    # Period 3: [2026-10-28, 2026-11-10] @ $75.00
    db_cursor.execute("""
        INSERT INTO rate (service_id, rate_per_wm, currency, validity)
        VALUES (%s, 50.00, 'USD', '[2026-10-01, 2026-10-15)'::daterange),
               (%s, 60.00, 'USD', '[2026-10-15, 2026-10-25)'::daterange),
               (%s, 75.00, 'USD', '[2026-10-28, 2026-11-10]'::daterange);
    """, (service_id, service_id, service_id))

    return service_id


def test_rate_inside_validity_period(db_cursor, rate_test_service):
    """Date inside period 1 resolves to period 1 rate."""
    db_cursor.execute("SELECT rate_per_wm FROM get_applicable_rate(%s, '2026-10-08');", (rate_test_service,))
    assert db_cursor.fetchone()[0] == Decimal("50.00")


def test_rate_first_day_of_period(db_cursor, rate_test_service):
    """First day of half-open/closed period [2026-10-01, ...) resolves to $50.00."""
    db_cursor.execute("SELECT rate_per_wm FROM get_applicable_rate(%s, '2026-10-01');", (rate_test_service,))
    assert db_cursor.fetchone()[0] == Decimal("50.00")


def test_rate_last_day_of_closed_period(db_cursor, rate_test_service):
    """Last day of closed period [... 2026-11-10] resolves to $75.00."""
    db_cursor.execute("SELECT rate_per_wm FROM get_applicable_rate(%s, '2026-11-10');", (rate_test_service,))
    assert db_cursor.fetchone()[0] == Decimal("75.00")


def test_rate_boundary_adjacent_periods(db_cursor, rate_test_service):
    """
    On boundary date 2026-10-15:
    Period 1 [2026-10-01, 2026-10-15) does NOT contain 2026-10-15.
    Period 2 [2026-10-15, 2026-10-25) DOES contain 2026-10-15.
    Must resolve unambiguously to Period 2 ($60.00).
    """
    db_cursor.execute("SELECT rate_per_wm FROM get_applicable_rate(%s, '2026-10-15');", (rate_test_service,))
    assert db_cursor.fetchone()[0] == Decimal("60.00")


def test_rate_inside_deliberate_gap_returns_empty(db_cursor, rate_test_service):
    """Date inside deliberate gap (2026-10-26) returns no row."""
    db_cursor.execute("SELECT rate_per_wm FROM get_applicable_rate(%s, '2026-10-26');", (rate_test_service,))
    assert db_cursor.fetchone() is None


# ==============================================================================
# 4. search_departures() Multi-Constraint Exclusion Tests
# ==============================================================================

def test_search_rule1_wrong_lane_excluded(db_cursor, base_test_setup):
    """Rule 1: Origin / Destination must match requested ports."""
    b = base_test_setup
    # Search for different destination port
    db_cursor.execute("""
        SELECT * FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := 999999,
            p_cbm := 5.0,
            p_weight_kg := 2000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2026-10-15'::date,
            p_as_of := '2026-10-12 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["cat_id"]))
    assert len(db_cursor.fetchall()) == 0


def test_search_rule2_inactive_service_excluded(db_cursor, base_test_setup):
    """Rule 2: Inactive service departures are excluded."""
    b = base_test_setup
    db_cursor.execute("UPDATE lcl_service SET is_active = FALSE WHERE id = %s;", (b["service_id"],))

    db_cursor.execute("""
        SELECT * FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := %s,
            p_cbm := 5.0,
            p_weight_kg := 2000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2026-10-15'::date,
            p_as_of := '2026-10-12 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["port_b_id"], b["cat_id"]))
    assert len(db_cursor.fetchall()) == 0


def test_search_rule3_non_scheduled_departure_excluded(db_cursor, base_test_setup):
    """Rule 3: Non-SCHEDULED (e.g. CANCELLED, CLOSED) departures are excluded."""
    b = base_test_setup
    db_cursor.execute("UPDATE departure SET status = 'CANCELLED' WHERE id = %s;", (b["dep_id"],))

    db_cursor.execute("""
        SELECT * FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := %s,
            p_cbm := 5.0,
            p_weight_kg := 2000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2026-10-15'::date,
            p_as_of := '2026-10-12 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["port_b_id"], b["cat_id"]))
    assert len(db_cursor.fetchall()) == 0


def test_search_rule4_passed_cutoff_excluded(db_cursor, base_test_setup):
    """Rule 4: Departure whose cutoff_at <= as_of is excluded."""
    b = base_test_setup
    # Cutoff is 2026-10-17 18:00:00+00. Supply as_of AFTER cutoff.
    db_cursor.execute("""
        SELECT * FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := %s,
            p_cbm := 5.0,
            p_weight_kg := 2000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2026-10-15'::date,
            p_as_of := '2026-10-18 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["port_b_id"], b["cat_id"]))
    assert len(db_cursor.fetchall()) == 0


def test_search_rule5_cargo_ready_after_cutoff_date_excluded(db_cursor, base_test_setup):
    """Rule 5: Cargo ready date after cutoff date is excluded."""
    b = base_test_setup
    # Cutoff is 2026-10-17. Ready date 2026-10-19 is too late.
    db_cursor.execute("""
        SELECT * FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := %s,
            p_cbm := 5.0,
            p_weight_kg := 2000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2026-10-19'::date,
            p_as_of := '2026-10-12 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["port_b_id"], b["cat_id"]))
    assert len(db_cursor.fetchall()) == 0


def test_search_rule6_refused_cargo_category_excluded(db_cursor, base_test_setup):
    """Rule 6: Cargo category not in service_cargo_acceptance is excluded."""
    b = base_test_setup
    # Create another category not accepted by service
    db_cursor.execute("""
        INSERT INTO cargo_category (code, name, is_dangerous, is_perishable)
        VALUES ('REFUSEDCAT', 'Refused Category', TRUE, FALSE)
        RETURNING id;
    """)
    refused_cat_id = db_cursor.fetchone()[0]

    db_cursor.execute("""
        SELECT * FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := %s,
            p_cbm := 5.0,
            p_weight_kg := 2000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2026-10-15'::date,
            p_as_of := '2026-10-12 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["port_b_id"], refused_cat_id))
    assert len(db_cursor.fetchall()) == 0


def test_search_rule7_cbm_too_large_excluded(db_cursor, base_test_setup):
    """Rule 7: Request CBM exceeding remaining CBM is excluded."""
    b = base_test_setup
    # Capacity is 50.0 CBM; request 55.0 CBM
    db_cursor.execute("""
        SELECT * FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := %s,
            p_cbm := 55.0,
            p_weight_kg := 2000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2026-10-15'::date,
            p_as_of := '2026-10-12 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["port_b_id"], b["cat_id"]))
    assert len(db_cursor.fetchall()) == 0


def test_search_rule8_weight_too_large_excluded(db_cursor, base_test_setup):
    """Rule 8: Request weight exceeding remaining weight is excluded."""
    b = base_test_setup
    # Capacity is 30,000 kg; request 32,000 kg
    db_cursor.execute("""
        SELECT * FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := %s,
            p_cbm := 5.0,
            p_weight_kg := 32000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2026-10-15'::date,
            p_as_of := '2026-10-12 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["port_b_id"], b["cat_id"]))
    assert len(db_cursor.fetchall()) == 0


def test_search_rule9_no_applicable_rate_excluded(db_cursor, base_test_setup):
    """Rule 9: No rate covering departure ETD excludes departure."""
    b = base_test_setup
    # Delete rate
    db_cursor.execute("DELETE FROM rate WHERE service_id = %s;", (b["service_id"],))

    db_cursor.execute("""
        SELECT * FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := %s,
            p_cbm := 5.0,
            p_weight_kg := 2000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2026-10-15'::date,
            p_as_of := '2026-10-12 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["port_b_id"], b["cat_id"]))
    assert len(db_cursor.fetchall()) == 0


def test_search_fully_feasible_departure_returned(db_cursor, base_test_setup):
    """A feasible departure matching all 9 rules is returned with accurate derived attributes."""
    b = base_test_setup
    # 8.0 CBM, 10,000 kg (10.0 t) => chargeable_qty = 10.0 W/M
    # Rate = 80.00 USD => estimated_total = 10.0 * 80.00 = 800.00 USD
    db_cursor.execute("""
        SELECT departure_id, service_id, provider_name, remaining_cbm, remaining_weight_kg,
               chargeable_qty, rate_per_wm, currency, estimated_total, utilisation_pct
        FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := %s,
            p_cbm := 8.0,
            p_weight_kg := 10000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2026-10-15'::date,
            p_as_of := '2026-10-12 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["port_b_id"], b["cat_id"]))
    rows = db_cursor.fetchall()
    assert len(rows) == 1
    row = rows[0]
    assert row[0] == b["dep_id"]
    assert row[1] == b["service_id"]
    assert row[2] == "Test Ocean Lines"
    assert row[3] == Decimal("50.000")
    assert row[4] == Decimal("30000.00")
    assert row[5] == Decimal("10.0")
    assert row[6] == Decimal("80.00")
    assert row[7] == "USD"
    assert row[8] == Decimal("800.00")
    assert row[9] == Decimal("0.00")


def test_search_results_ordering(db_cursor, base_test_setup):
    """
    Search results must be ordered by:
    1. estimated_total ASC
    2. etd ASC
    """
    b = base_test_setup

    # Create a 2nd departure on same service with higher rate
    # ETD earlier (2026-10-19), but rate $120.00 => estimated total $1200.00
    db_cursor.execute("""
        INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg, status)
        VALUES (%s, '2026-10-19 10:00:00+00', '2026-10-24 14:00:00+00', '2026-10-16 18:00:00+00', 50.000, 30000.00, 'SCHEDULED')
        RETURNING id;
    """, (b["service_id"],))
    dep_early_id = db_cursor.fetchone()[0]

    # Create a 2nd service with cheaper rate ($40.00)
    db_cursor.execute("""
        INSERT INTO app_user (email, full_name) VALUES ('cheap_prov@example.com', 'Cheap Prov') RETURNING id;
    """)
    cheap_u_id = db_cursor.fetchone()[0]
    db_cursor.execute("""
        INSERT INTO provider (app_user_id, company_name, data_origin) VALUES (%s, 'Budget Freight Lines', 'SYNTHETIC') RETURNING id;
    """, (cheap_u_id,))
    cheap_p_id = db_cursor.fetchone()[0]
    db_cursor.execute("""
        INSERT INTO lcl_service (provider_id, origin_port_id, dest_port_id, transit_days, is_active)
        VALUES (%s, %s, %s, 6, TRUE) RETURNING id;
    """, (cheap_p_id, b["port_a_id"], b["port_b_id"]))
    cheap_s_id = db_cursor.fetchone()[0]
    db_cursor.execute("INSERT INTO service_cargo_acceptance VALUES (%s, %s);", (cheap_s_id, b["cat_id"]))
    db_cursor.execute("""
        INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg, status)
        VALUES (%s, '2026-10-22 10:00:00+00', '2026-10-28 14:00:00+00', '2026-10-18 18:00:00+00', 50.000, 30000.00, 'SCHEDULED')
        RETURNING id;
    """, (cheap_s_id,))
    dep_cheap_id = db_cursor.fetchone()[0]
    db_cursor.execute("""
        INSERT INTO rate (service_id, rate_per_wm, currency, validity)
        VALUES (%s, 40.00, 'USD', '[2026-10-01, 2026-10-31]'::daterange);
    """, (cheap_s_id,))

    # Search for 10 CBM, 5000 kg => chargeable_qty = 10.0
    # Expected ranking:
    # 1. Budget Freight Lines: 10 * 40 = $400.00
    # 2. Test Ocean Lines (dep 1): 10 * 80 = $800.00
    # 3. Test Ocean Lines (dep early): 10 * 80 = $800.00 (same service rate, ordered by ETD)
    db_cursor.execute("""
        SELECT departure_id, estimated_total, etd
        FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := %s,
            p_cbm := 10.0,
            p_weight_kg := 5000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2026-10-15'::date,
            p_as_of := '2026-10-12 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["port_b_id"], b["cat_id"]))
    rows = db_cursor.fetchall()
    assert len(rows) >= 2
    # Cheapest first
    assert rows[0][0] == dep_cheap_id
    assert rows[0][1] == Decimal("400.00")
    # Subsequent rows have non-decreasing estimated_total
    for i in range(len(rows) - 1):
        assert rows[i][1] <= rows[i+1][1]
        if rows[i][1] == rows[i+1][1]:
            assert rows[i][2] <= rows[i+1][2]


def test_search_impossible_request_returns_empty(db_cursor, base_test_setup):
    """Impossible request (e.g. 100 CBM, ready in 2028) returns zero rows."""
    b = base_test_setup
    db_cursor.execute("""
        SELECT * FROM search_departures(
            p_origin_port_id := %s,
            p_dest_port_id := %s,
            p_cbm := 100.0,
            p_weight_kg := 50000.0,
            p_category_id := %s,
            p_cargo_ready_date := '2028-01-01'::date,
            p_as_of := '2026-10-12 00:00:00+00'::timestamptz
        );
    """, (b["port_a_id"], b["port_b_id"], b["cat_id"]))
    assert len(db_cursor.fetchall()) == 0


# ==============================================================================
# 5. Demo Queries Execution Test
# ==============================================================================

def test_search_demos_sql_file_executes_without_error(db_cursor):
    """
    Executes all five demonstration queries from db/queries/search_demos.sql
    against the database to verify that syntax, schema references, and join logic are valid.
    """
    demo_file = Path(__file__).resolve().parent.parent / "db" / "queries" / "search_demos.sql"
    assert demo_file.exists(), f"Query file {demo_file} does not exist"

    with open(demo_file, "r", encoding="utf-8") as f:
        content = f.read()

    queries = [q.strip() for q in content.split(";") if q.strip()]
    assert len(queries) == 5, f"Expected exactly 5 demo queries in search_demos.sql, found {len(queries)}"

    for idx, q in enumerate(queries, start=1):
        try:
            db_cursor.execute(q)
            # Fetch results to confirm execution completes cleanly
            rows = db_cursor.fetchall()
            assert isinstance(rows, list)
        except Exception as e:
            pytest.fail(f"Demo query {idx} in search_demos.sql failed with error: {e}")

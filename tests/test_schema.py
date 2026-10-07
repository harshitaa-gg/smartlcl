import pytest
import psycopg
from psycopg import errors

# ==============================================================================
# Helper fixtures / seed factories for schema testing
# ==============================================================================

def create_base_port(cur, unlocode="TSTNA", name="Test Nhava Sheva", country="IN"):
    cur.execute("""
        INSERT INTO port (unlocode, name, country_code, data_origin)
        VALUES (%s, %s, %s, 'REAL')
        RETURNING id;
    """, (unlocode, name, country))
    return cur.fetchone()[0]

def create_base_category(cur, code="TSTGEN", name="Test General Cargo"):
    cur.execute("""
        INSERT INTO cargo_category (code, name, is_dangerous, is_perishable)
        VALUES (%s, %s, FALSE, FALSE)
        RETURNING id;
    """, (code, name))
    return cur.fetchone()[0]

def create_base_user(cur, email="trader_schema_test@example.com", name="Trader Schema"):
    cur.execute("""
        INSERT INTO app_user (email, full_name)
        VALUES (%s, %s)
        RETURNING id;
    """, (email, name))
    return cur.fetchone()[0]

def create_base_trader(cur, user_id=None):
    if user_id is None:
        user_id = create_base_user(cur, "trader_owner_test@example.com", "Owner")
    cur.execute("""
        INSERT INTO trader (app_user_id, company_name, home_city, data_origin)
        VALUES (%s, 'Test Schema Apex Exports', 'Mumbai', 'SYNTHETIC')
        RETURNING id;
    """, (user_id,))
    return cur.fetchone()[0]

def create_base_provider(cur, user_id=None):
    if user_id is None:
        user_id = create_base_user(cur, "provider_owner_test@example.com", "Provider")
    cur.execute("""
        INSERT INTO provider (app_user_id, company_name, data_origin)
        VALUES (%s, 'Test Schema Global Ocean Freight', 'SYNTHETIC')
        RETURNING id;
    """, (user_id,))
    return cur.fetchone()[0]

def create_base_service(cur, provider_id=None, origin_id=None, dest_id=None):
    if origin_id is None:
        origin_id = create_base_port(cur, "TSTNA", "Test Nhava Sheva")
    if dest_id is None:
        dest_id = create_base_port(cur, "TSTSG", "Test Singapore", "SG")
    if provider_id is None:
        provider_id = create_base_provider(cur)
    cur.execute("""
        INSERT INTO lcl_service (provider_id, origin_port_id, dest_port_id, transit_days, is_active)
        VALUES (%s, %s, %s, 10, TRUE)
        RETURNING id;
    """, (provider_id, origin_id, dest_id))
    return cur.fetchone()[0]

# ==============================================================================
# Port Tests
# ==============================================================================

def test_valid_port_insert(db_cursor):
    port_id = create_base_port(db_cursor, "TSTNA", "Test Nhava Sheva", "IN")
    assert port_id is not None
    db_cursor.execute("SELECT unlocode, name, country_code FROM port WHERE id = %s;", (port_id,))
    row = db_cursor.fetchone()
    assert row == ("TSTNA", "Test Nhava Sheva", "IN")

def test_duplicate_unlocode_fails(db_cursor):
    create_base_port(db_cursor, "TSTNA", "Port One", "IN")
    with pytest.raises(errors.UniqueViolation) as exc:
        create_base_port(db_cursor, "TSTNA", "Port Two", "IN")
    assert exc.value.sqlstate == "23505"
    assert "port_unlocode_uk" in str(exc.value)

@pytest.mark.parametrize("bad_code", ["innsa", "IN1", "INNSAA", "IN_SA", "12345"])
def test_malformed_unlocode_fails(db_cursor, bad_code):
    with pytest.raises(errors.CheckViolation) as exc:
        create_base_port(db_cursor, bad_code, "Invalid Port", "IN")
    assert exc.value.sqlstate == "23514"
    assert "port_unlocode_ck" in str(exc.value)

# ==============================================================================
# User Tests (CITEXT)
# ==============================================================================

def test_duplicate_email_case_insensitive_fails(db_cursor):
    create_base_user(db_cursor, "trader_schema@example.com", "Trader Lower")
    with pytest.raises(errors.UniqueViolation) as exc:
        create_base_user(db_cursor, "TRADER_SCHEMA@EXAMPLE.COM", "Trader Upper")
    assert exc.value.sqlstate == "23505"
    assert "app_user_email_uk" in str(exc.value)

# ==============================================================================
# Shipment Tests
# ==============================================================================

def test_valid_shipment_insert(db_cursor):
    t_id = create_base_trader(db_cursor)
    p_orig = create_base_port(db_cursor, "TSTNA", "Test Nhava Sheva")
    p_dest = create_base_port(db_cursor, "TSTSG", "Test Singapore", "SG")
    c_id = create_base_category(db_cursor)

    db_cursor.execute("""
        INSERT INTO shipment (trader_id, origin_port_id, dest_port_id, category_id, cbm, weight_kg, cargo_ready_date, description)
        VALUES (%s, %s, %s, %s, 12.500, 4500.00, '2026-10-15', 'Textiles')
        RETURNING id;
    """, (t_id, p_orig, p_dest, c_id))
    assert db_cursor.fetchone()[0] is not None

@pytest.mark.parametrize("bad_weight", [0, -10.5])
def test_shipment_weight_zero_or_negative_fails(db_cursor, bad_weight):
    t_id = create_base_trader(db_cursor)
    p_orig = create_base_port(db_cursor, "TSTNA", "Test Nhava Sheva")
    p_dest = create_base_port(db_cursor, "TSTSG", "Test Singapore", "SG")
    c_id = create_base_category(db_cursor)

    with pytest.raises(errors.CheckViolation) as exc:
        db_cursor.execute("""
            INSERT INTO shipment (trader_id, origin_port_id, dest_port_id, category_id, cbm, weight_kg, cargo_ready_date)
            VALUES (%s, %s, %s, %s, 10.0, %s, '2026-10-15');
        """, (t_id, p_orig, p_dest, c_id, bad_weight))
    assert exc.value.sqlstate == "23514"
    assert "shipment_weight_kg_ck" in str(exc.value)

@pytest.mark.parametrize("bad_cbm", [0, -5.0, 71.0])
def test_shipment_cbm_bounds_fails(db_cursor, bad_cbm):
    t_id = create_base_trader(db_cursor)
    p_orig = create_base_port(db_cursor, "TSTNA", "Test Nhava Sheva")
    p_dest = create_base_port(db_cursor, "TSTSG", "Test Singapore", "SG")
    c_id = create_base_category(db_cursor)

    with pytest.raises(errors.CheckViolation) as exc:
        db_cursor.execute("""
            INSERT INTO shipment (trader_id, origin_port_id, dest_port_id, category_id, cbm, weight_kg, cargo_ready_date)
            VALUES (%s, %s, %s, %s, %s, 1000.0, '2026-10-15');
        """, (t_id, p_orig, p_dest, c_id, bad_cbm))
    assert exc.value.sqlstate == "23514"
    assert "shipment_cbm_ck" in str(exc.value)

# ==============================================================================
# Service & Departure Tests
# ==============================================================================

def test_service_origin_equals_destination_fails(db_cursor):
    p_id = create_base_port(db_cursor, "TSTNA", "Test Nhava Sheva")
    prv_id = create_base_provider(db_cursor)
    with pytest.raises(errors.CheckViolation) as exc:
        db_cursor.execute("""
            INSERT INTO lcl_service (provider_id, origin_port_id, dest_port_id, transit_days)
            VALUES (%s, %s, %s, 5);
        """, (prv_id, p_id, p_id))
    assert exc.value.sqlstate == "23514"
    assert "lcl_service_origin_dest_ck" in str(exc.value)

def test_departure_eta_before_or_equal_etd_fails(db_cursor):
    srv_id = create_base_service(db_cursor)
    with pytest.raises(errors.CheckViolation) as exc:
        db_cursor.execute("""
            INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg)
            VALUES (%s, '2026-10-20 10:00:00+00', '2026-10-20 09:00:00+00', '2026-10-18 10:00:00+00', 60.0, 25000.0);
        """, (srv_id,))
    assert exc.value.sqlstate == "23514"
    assert "departure_eta_after_etd_ck" in str(exc.value)

def test_departure_cutoff_after_etd_fails(db_cursor):
    srv_id = create_base_service(db_cursor)
    with pytest.raises(errors.CheckViolation) as exc:
        db_cursor.execute("""
            INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg)
            VALUES (%s, '2026-10-20 10:00:00+00', '2026-10-25 10:00:00+00', '2026-10-21 10:00:00+00', 60.0, 25000.0);
        """, (srv_id,))
    assert exc.value.sqlstate == "23514"
    assert "departure_cutoff_before_etd_ck" in str(exc.value)

def test_duplicate_service_and_etd_fails(db_cursor):
    srv_id = create_base_service(db_cursor)
    db_cursor.execute("""
        INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg)
        VALUES (%s, '2026-10-20 10:00:00+00', '2026-10-25 10:00:00+00', '2026-10-18 10:00:00+00', 60.0, 25000.0);
    """, (srv_id,))
    with pytest.raises(errors.UniqueViolation) as exc:
        db_cursor.execute("""
            INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg)
            VALUES (%s, '2026-10-20 10:00:00+00', '2026-10-26 10:00:00+00', '2026-10-19 10:00:00+00', 50.0, 20000.0);
        """, (srv_id,))
    assert exc.value.sqlstate == "23505"
    assert "departure_service_etd_uk" in str(exc.value)

# ==============================================================================
# Rate Temporal Exclusion Tests (btree_gist)
# ==============================================================================

def test_overlapping_rate_periods_same_service_fails(db_cursor):
    srv_id = create_base_service(db_cursor)
    db_cursor.execute("""
        INSERT INTO rate (service_id, rate_per_wm, currency, validity)
        VALUES (%s, 85.00, 'USD', daterange('2026-10-01', '2026-10-31', '[]'));
    """, (srv_id,))

    with pytest.raises(errors.ExclusionViolation) as exc:
        db_cursor.execute("""
            INSERT INTO rate (service_id, rate_per_wm, currency, validity)
            VALUES (%s, 90.00, 'USD', daterange('2026-10-15', '2026-11-15', '[]'));
        """, (srv_id,))
    assert exc.value.sqlstate == "23P01"
    assert "rate_service_validity_ex" in str(exc.value)

def test_adjacent_rate_periods_same_service_succeeds(db_cursor):
    srv_id = create_base_service(db_cursor)
    # [2026-10-01, 2026-10-15) and [2026-10-15, 2026-10-31)
    db_cursor.execute("""
        INSERT INTO rate (service_id, rate_per_wm, currency, validity)
        VALUES (%s, 85.00, 'USD', daterange('2026-10-01', '2026-10-15', '[)'));
    """, (srv_id,))
    db_cursor.execute("""
        INSERT INTO rate (service_id, rate_per_wm, currency, validity)
        VALUES (%s, 95.00, 'USD', daterange('2026-10-15', '2026-10-31', '[)'));
    """, (srv_id,))
    db_cursor.execute("SELECT COUNT(*) FROM rate WHERE service_id = %s;", (srv_id,))
    assert db_cursor.fetchone()[0] == 2

def test_same_rate_period_on_different_services_succeeds(db_cursor):
    p_orig = create_base_port(db_cursor, "TSTNA", "Test Nhava Sheva")
    p_dest1 = create_base_port(db_cursor, "TSTSG", "Test Singapore", "SG")
    p_dest2 = create_base_port(db_cursor, "TSTMY", "Test Port Klang", "MY")
    prv_id = create_base_provider(db_cursor)

    srv1 = create_base_service(db_cursor, prv_id, p_orig, p_dest1)
    srv2 = create_base_service(db_cursor, prv_id, p_orig, p_dest2)

    db_cursor.execute("""
        INSERT INTO rate (service_id, rate_per_wm, currency, validity)
        VALUES (%s, 80.00, 'USD', daterange('2026-10-01', '2026-10-31', '[]'));
    """, (srv1,))
    db_cursor.execute("""
        INSERT INTO rate (service_id, rate_per_wm, currency, validity)
        VALUES (%s, 80.00, 'USD', daterange('2026-10-01', '2026-10-31', '[]'));
    """, (srv2,))
    db_cursor.execute("SELECT COUNT(*) FROM rate WHERE service_id IN (%s, %s);", (srv1, srv2))
    assert db_cursor.fetchone()[0] == 2

# ==============================================================================
# General Referential Integrity & Nullability Tests
# ==============================================================================

def test_foreign_key_to_missing_row_fails(db_cursor):
    with pytest.raises(errors.ForeignKeyViolation) as exc:
        db_cursor.execute("""
            INSERT INTO shipment (trader_id, origin_port_id, dest_port_id, category_id, cbm, weight_kg, cargo_ready_date)
            VALUES (999999, 999999, 999998, 999999, 10.0, 1000.0, '2026-10-15');
        """)
    assert exc.value.sqlstate == "23503"

def test_null_in_mandatory_column_fails(db_cursor):
    with pytest.raises(errors.NotNullViolation) as exc:
        db_cursor.execute("""
            INSERT INTO port (unlocode, name, country_code, data_origin)
            VALUES (NULL, 'Null Port', 'IN', 'REAL');
        """)
    assert exc.value.sqlstate == "23502"

# ==============================================================================
# Booking Partial Unique Index Tests
# ==============================================================================

def test_second_capacity_holding_booking_fails(db_cursor):
    t_id = create_base_trader(db_cursor)
    p_orig = create_base_port(db_cursor, "TSTNA", "Test Nhava Sheva")
    p_dest = create_base_port(db_cursor, "TSTSG", "Test Singapore", "SG")
    c_id = create_base_category(db_cursor)

    db_cursor.execute("""
        INSERT INTO shipment (trader_id, origin_port_id, dest_port_id, category_id, cbm, weight_kg, cargo_ready_date)
        VALUES (%s, %s, %s, %s, 10.0, 2000.0, '2026-10-15')
        RETURNING id;
    """, (t_id, p_orig, p_dest, c_id))
    sh_id = db_cursor.fetchone()[0]

    srv_id = create_base_service(db_cursor, origin_id=p_orig, dest_id=p_dest)
    db_cursor.execute("""
        INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg)
        VALUES (%s, '2026-10-20 10:00:00+00', '2026-10-25 10:00:00+00', '2026-10-18 10:00:00+00', 60.0, 25000.0)
        RETURNING id;
    """, (srv_id,))
    dep1 = db_cursor.fetchone()[0]

    db_cursor.execute("""
        INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg)
        VALUES (%s, '2026-10-28 10:00:00+00', '2026-11-02 10:00:00+00', '2026-10-26 10:00:00+00', 60.0, 25000.0)
        RETURNING id;
    """, (srv_id,))
    dep2 = db_cursor.fetchone()[0]

    # First booking: PENDING
    db_cursor.execute("""
        INSERT INTO booking (shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg, chargeable_qty, quoted_rate, quoted_currency, quoted_total)
        VALUES (%s, %s, 'PENDING', 10.0, 2000.0, 10.0, 80.0, 'USD', 800.0);
    """, (sh_id, dep1))

    # Second booking: CONFIRMED on dep2 for same shipment must fail
    with pytest.raises(errors.UniqueViolation) as exc:
        db_cursor.execute("""
            INSERT INTO booking (shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg, chargeable_qty, quoted_rate, quoted_currency, quoted_total)
            VALUES (%s, %s, 'CONFIRMED', 10.0, 2000.0, 10.0, 80.0, 'USD', 800.0);
        """, (sh_id, dep2))
    assert exc.value.sqlstate == "23505"
    assert "booking_shipment_capacity_uk" in str(exc.value)

def test_cancelled_booking_permits_new_capacity_holding_booking(db_cursor):
    t_id = create_base_trader(db_cursor)
    p_orig = create_base_port(db_cursor, "TSTNA", "Test Nhava Sheva")
    p_dest = create_base_port(db_cursor, "TSTSG", "Test Singapore", "SG")
    c_id = create_base_category(db_cursor)

    db_cursor.execute("""
        INSERT INTO shipment (trader_id, origin_port_id, dest_port_id, category_id, cbm, weight_kg, cargo_ready_date)
        VALUES (%s, %s, %s, %s, 10.0, 2000.0, '2026-10-15')
        RETURNING id;
    """, (t_id, p_orig, p_dest, c_id))
    sh_id = db_cursor.fetchone()[0]

    srv_id = create_base_service(db_cursor, origin_id=p_orig, dest_id=p_dest)
    db_cursor.execute("""
        INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg)
        VALUES (%s, '2026-10-20 10:00:00+00', '2026-10-25 10:00:00+00', '2026-10-18 10:00:00+00', 60.0, 25000.0)
        RETURNING id;
    """, (srv_id,))
    dep1 = db_cursor.fetchone()[0]

    db_cursor.execute("""
        INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg)
        VALUES (%s, '2026-10-28 10:00:00+00', '2026-11-02 10:00:00+00', '2026-10-26 10:00:00+00', 60.0, 25000.0)
        RETURNING id;
    """, (srv_id,))
    dep2 = db_cursor.fetchone()[0]

    # First booking: PENDING
    db_cursor.execute("""
        INSERT INTO booking (shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg, chargeable_qty, quoted_rate, quoted_currency, quoted_total)
        VALUES (%s, %s, 'PENDING', 10.0, 2000.0, 10.0, 80.0, 'USD', 800.0);
    """, (sh_id, dep1))

    # Second booking: CONFIRMED on dep2 for same shipment must fail
    with pytest.raises(errors.UniqueViolation) as exc:
        db_cursor.execute("""
            INSERT INTO booking (shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg, chargeable_qty, quoted_rate, quoted_currency, quoted_total)
            VALUES (%s, %s, 'CONFIRMED', 10.0, 2000.0, 10.0, 80.0, 'USD', 800.0);
        """, (sh_id, dep2))
    assert exc.value.sqlstate == "23505"
    assert "booking_shipment_capacity_uk" in str(exc.value)

def test_cancelled_booking_permits_new_capacity_holding_booking(db_cursor):
    t_id = create_base_trader(db_cursor)
    p_orig = create_base_port(db_cursor, "TSTNA", "Test Nhava Sheva")
    p_dest = create_base_port(db_cursor, "TSTSG", "Test Singapore", "SG")
    c_id = create_base_category(db_cursor)

    db_cursor.execute("""
        INSERT INTO shipment (trader_id, origin_port_id, dest_port_id, category_id, cbm, weight_kg, cargo_ready_date)
        VALUES (%s, %s, %s, %s, 8.0, 1500.0, '2026-10-15')
        RETURNING id;
    """, (t_id, p_orig, p_dest, c_id))
    sh_id = db_cursor.fetchone()[0]

    srv_id = create_base_service(db_cursor, origin_id=p_orig, dest_id=p_dest)
    db_cursor.execute("""
        INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg)
        VALUES (%s, '2026-10-20 10:00:00+00', '2026-10-25 10:00:00+00', '2026-10-18 10:00:00+00', 60.0, 25000.0)
        RETURNING id;
    """, (srv_id,))
    dep1 = db_cursor.fetchone()[0]

    # Insert CANCELLED booking
    db_cursor.execute("""
        INSERT INTO booking (shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg, chargeable_qty, quoted_rate, quoted_currency, quoted_total)
        VALUES (%s, %s, 'CANCELLED', 8.0, 1500.0, 8.0, 80.0, 'USD', 640.0)
        RETURNING id;
    """, (sh_id, dep1))

    # Now insert a new PENDING booking for same shipment: must SUCCEED
    db_cursor.execute("""
        INSERT INTO booking (shipment_id, departure_id, status, allocated_cbm, allocated_weight_kg, chargeable_qty, quoted_rate, quoted_currency, quoted_total)
        VALUES (%s, %s, 'PENDING', 8.0, 1500.0, 8.0, 85.0, 'USD', 680.0)
        RETURNING id;
    """, (sh_id, dep1))
    new_bk_id = db_cursor.fetchone()[0]
    assert new_bk_id is not None

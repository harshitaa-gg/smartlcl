-- ==============================================================================
-- Migration: 0005_booking.sql
-- Description: Transaction-safe PostgreSQL booking allocation functions.
-- Functions:
-- 1. create_booking(p_shipment_id, p_departure_id, p_as_of) -> BIGINT
-- 2. cancel_booking(p_booking_id) -> VOID
-- 3. confirm_booking(p_booking_id) -> VOID
--
-- Invariants enforced:
-- - Departure row locked FIRST via SELECT ... FOR UPDATE (serialization).
-- - Capacity recomputed dynamically inside the lock (NO stored mutable remaining).
-- - Single source of truth: is_capacity_holding(), chargeable_qty(), get_applicable_rate().
-- - Precise error codes SL001 through SL009.
-- - Atomic snapshot of historical pricing into booking table.
-- - No BEGIN/COMMIT inside functions; transaction boundaries belong to caller.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- Function: create_booking
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_booking(
    p_shipment_id BIGINT,
    p_departure_id BIGINT,
    p_as_of TIMESTAMPTZ DEFAULT now()
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_departure RECORD;
    v_shipment RECORD;
    v_service RECORD;
    v_rate RECORD;
    v_allocated_cbm NUMERIC(8,3);
    v_allocated_weight_kg NUMERIC(10,2);
    v_remaining_cbm NUMERIC(8,3);
    v_remaining_weight_kg NUMERIC(10,2);
    v_chargeable_qty NUMERIC(10,3);
    v_quoted_total NUMERIC(14,2);
    v_booking_id BIGINT;
    v_is_accepted BOOLEAN;
    v_has_holding_booking BOOLEAN;
BEGIN
    -- -------------------------------------------------------------------------
    -- Step A: Lock the departure row first (serialization anchor)
    -- -------------------------------------------------------------------------
    SELECT *
    INTO v_departure
    FROM departure
    WHERE id = p_departure_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Departure % does not exist', p_departure_id
            USING ERRCODE = 'SL009';
    END IF;

    -- -------------------------------------------------------------------------
    -- Step B: Load shipment and associated service
    -- -------------------------------------------------------------------------
    SELECT *
    INTO v_shipment
    FROM shipment
    WHERE id = p_shipment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Shipment % does not exist', p_shipment_id
            USING ERRCODE = 'SL009';
    END IF;

    SELECT *
    INTO v_service
    FROM lcl_service
    WHERE id = v_departure.service_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Associated LCL service % for departure % does not exist',
            v_departure.service_id, p_departure_id
            USING ERRCODE = 'SL009';
    END IF;

    -- -------------------------------------------------------------------------
    -- Step C: Validation Rules (SL001 - SL005)
    -- -------------------------------------------------------------------------
    -- SL001: Departure status must be SCHEDULED
    IF v_departure.status <> 'SCHEDULED' THEN
        RAISE EXCEPTION 'Departure % has status %, but must be SCHEDULED',
            p_departure_id, v_departure.status
            USING ERRCODE = 'SL001';
    END IF;

    -- SL002: Cutoff passed check
    IF p_as_of >= v_departure.cutoff_at THEN
        RAISE EXCEPTION 'Booking time % is at or past departure cutoff %',
            p_as_of, v_departure.cutoff_at
            USING ERRCODE = 'SL002';
    END IF;

    -- SL003: Lane mismatch check
    IF v_shipment.origin_port_id <> v_service.origin_port_id
       OR v_shipment.dest_port_id <> v_service.dest_port_id THEN
        RAISE EXCEPTION 'Shipment ports (% -> %) do not match service lane (% -> %)',
            v_shipment.origin_port_id, v_shipment.dest_port_id,
            v_service.origin_port_id, v_service.dest_port_id
            USING ERRCODE = 'SL003';
    END IF;

    -- SL004: Cargo category acceptance check
    SELECT EXISTS (
        SELECT 1
        FROM service_cargo_acceptance
        WHERE service_id = v_service.id
          AND category_id = v_shipment.category_id
    ) INTO v_is_accepted;

    IF NOT v_is_accepted THEN
        RAISE EXCEPTION 'Service % does not accept cargo category %',
            v_service.id, v_shipment.category_id
            USING ERRCODE = 'SL004';
    END IF;

    -- SL005: Shipment already has a capacity-holding booking
    SELECT EXISTS (
        SELECT 1
        FROM booking
        WHERE shipment_id = v_shipment.id
          AND is_capacity_holding(status)
    ) INTO v_has_holding_booking;

    IF v_has_holding_booking THEN
        RAISE EXCEPTION 'Shipment % already has an active capacity-holding booking',
            v_shipment.id
            USING ERRCODE = 'SL005';
    END IF;

    -- -------------------------------------------------------------------------
    -- Step D: Recompute allocated capacity inside the lock
    -- -------------------------------------------------------------------------
    SELECT
        COALESCE(SUM(allocated_cbm) FILTER (WHERE is_capacity_holding(status)), 0)::NUMERIC(8,3),
        COALESCE(SUM(allocated_weight_kg) FILTER (WHERE is_capacity_holding(status)), 0)::NUMERIC(10,2)
    INTO v_allocated_cbm, v_allocated_weight_kg
    FROM booking
    WHERE departure_id = v_departure.id;

    v_remaining_cbm := v_departure.capacity_cbm - v_allocated_cbm;
    v_remaining_weight_kg := v_departure.capacity_weight_kg - v_allocated_weight_kg;

    -- SL006: Insufficient CBM capacity
    IF v_remaining_cbm < v_shipment.cbm THEN
        RAISE EXCEPTION 'Insufficient CBM capacity: required %, available %',
            v_shipment.cbm, v_remaining_cbm
            USING ERRCODE = 'SL006';
    END IF;

    -- SL007: Insufficient weight capacity
    IF v_remaining_weight_kg < v_shipment.weight_kg THEN
        RAISE EXCEPTION 'Insufficient weight capacity: required % kg, available % kg',
            v_shipment.weight_kg, v_remaining_weight_kg
            USING ERRCODE = 'SL007';
    END IF;

    -- -------------------------------------------------------------------------
    -- Step E: Rate lookup via get_applicable_rate (SL008)
    -- -------------------------------------------------------------------------
    SELECT *
    INTO v_rate
    FROM get_applicable_rate(v_service.id, (v_departure.etd AT TIME ZONE 'UTC')::date);

    IF NOT FOUND OR v_rate.id IS NULL THEN
        RAISE EXCEPTION 'No applicable rate for service % on departure ETD date %',
            v_service.id, (v_departure.etd AT TIME ZONE 'UTC')::date
            USING ERRCODE = 'SL008';
    END IF;

    -- -------------------------------------------------------------------------
    -- Step F: Pricing calculation
    -- -------------------------------------------------------------------------
    v_chargeable_qty := chargeable_qty(v_shipment.cbm, v_shipment.weight_kg);
    v_quoted_total := ROUND(v_chargeable_qty * v_rate.rate_per_wm, 2);

    -- -------------------------------------------------------------------------
    -- Step G: Insert booking snapshot (PENDING)
    -- -------------------------------------------------------------------------
    INSERT INTO booking (
        shipment_id,
        departure_id,
        status,
        allocated_cbm,
        allocated_weight_kg,
        chargeable_qty,
        quoted_rate,
        quoted_currency,
        quoted_total,
        notes,
        created_at,
        updated_at
    )
    VALUES (
        v_shipment.id,
        v_departure.id,
        'PENDING',
        v_shipment.cbm,
        v_shipment.weight_kg,
        v_chargeable_qty,
        v_rate.rate_per_wm,
        v_rate.currency,
        v_quoted_total,
        'Booked via create_booking()',
        p_as_of,
        p_as_of
    )
    RETURNING id INTO v_booking_id;

    -- Audit trail record
    INSERT INTO booking_audit (
        booking_id,
        old_status,
        new_status,
        changed_at,
        changed_by
    )
    VALUES (
        v_booking_id,
        NULL,
        'PENDING',
        p_as_of,
        'create_booking'
    );

    RETURN v_booking_id;
END;
$$;

COMMENT ON FUNCTION create_booking(BIGINT, BIGINT, TIMESTAMPTZ) IS
'Transaction-safe LCL booking allocation procedure.
- The departure row is locked FIRST (SELECT ... FOR UPDATE) before capacity recomputation.
- Capacity is derived dynamically from capacity-holding bookings under the lock.
- Pricing and rate are snapshotted permanently into the booking table.
- Transaction boundaries belong to the caller (no internal BEGIN/COMMIT).
- The call is atomic; errors abort the caller transaction cleanly.';

-- ------------------------------------------------------------------------------
-- Function: cancel_booking
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancel_booking(p_booking_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_booking RECORD;
    v_departure RECORD;
BEGIN
    -- 1. Locate booking
    SELECT *
    INTO v_booking
    FROM booking
    WHERE id = p_booking_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking % does not exist', p_booking_id
            USING ERRCODE = 'SL009';
    END IF;

    -- 2. Lock associated departure row
    SELECT *
    INTO v_departure
    FROM departure
    WHERE id = v_booking.departure_id
    FOR UPDATE;

    -- 3. Re-read booking under lock
    SELECT *
    INTO v_booking
    FROM booking
    WHERE id = p_booking_id;

    -- 4. Cancellation allowed ONLY from PENDING or CONFIRMED
    IF v_booking.status NOT IN ('PENDING', 'CONFIRMED') THEN
        RAISE EXCEPTION 'Cannot cancel booking %: current status is % (must be PENDING or CONFIRMED)',
            p_booking_id, v_booking.status
            USING ERRCODE = '22023';
    END IF;

    -- 5. Transition status to CANCELLED
    UPDATE booking
    SET status = 'CANCELLED',
        updated_at = clock_timestamp()
    WHERE id = p_booking_id;

    -- Audit trail record
    INSERT INTO booking_audit (
        booking_id,
        old_status,
        new_status,
        changed_at,
        changed_by
    )
    VALUES (
        p_booking_id,
        v_booking.status,
        'CANCELLED',
        clock_timestamp(),
        'cancel_booking'
    );
END;
$$;

COMMENT ON FUNCTION cancel_booking(BIGINT) IS
'Transaction-safe cancellation procedure releasing departure capacity.
- Locks the associated departure row (SELECT ... FOR UPDATE).
- Allowed only from PENDING or CONFIRMED states.
- Releases capacity because CANCELLED is not capacity-holding according to is_capacity_holding().
- Transaction boundaries belong to the caller (no internal BEGIN/COMMIT). Call is atomic.';

-- ------------------------------------------------------------------------------
-- Function: confirm_booking
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION confirm_booking(p_booking_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_booking RECORD;
    v_departure RECORD;
BEGIN
    -- 1. Locate booking
    SELECT *
    INTO v_booking
    FROM booking
    WHERE id = p_booking_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking % does not exist', p_booking_id
            USING ERRCODE = 'SL009';
    END IF;

    -- 2. Lock associated departure row
    SELECT *
    INTO v_departure
    FROM departure
    WHERE id = v_booking.departure_id
    FOR UPDATE;

    -- 3. Re-read booking under lock
    SELECT *
    INTO v_booking
    FROM booking
    WHERE id = p_booking_id;

    -- 4. Only PENDING -> CONFIRMED is valid
    IF v_booking.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Cannot confirm booking %: current status is % (must be PENDING)',
            p_booking_id, v_booking.status
            USING ERRCODE = '22023';
    END IF;

    -- 5. Transition status to CONFIRMED
    UPDATE booking
    SET status = 'CONFIRMED',
        updated_at = clock_timestamp()
    WHERE id = p_booking_id;

    -- Audit trail record
    INSERT INTO booking_audit (
        booking_id,
        old_status,
        new_status,
        changed_at,
        changed_by
    )
    VALUES (
        p_booking_id,
        'PENDING',
        'CONFIRMED',
        clock_timestamp(),
        'confirm_booking'
    );
END;
$$;

COMMENT ON FUNCTION confirm_booking(BIGINT) IS
'Transaction-safe booking confirmation procedure (PENDING -> CONFIRMED).
- Locks the associated departure row (SELECT ... FOR UPDATE).
- Does not affect capacity calculation because both PENDING and CONFIRMED hold capacity.
- Transaction boundaries belong to the caller (no internal BEGIN/COMMIT). Call is atomic.';

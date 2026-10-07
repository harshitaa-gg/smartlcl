-- ==============================================================================
-- Migration: 0004_availability_search.sql
-- Description: Core availability derivation and advisory freight search engine.
-- Decisions enforced:
-- 1. chargeable_qty(cbm, weight_kg) single source of truth.
-- 2. is_capacity_holding(status) single source of truth for capacity retention.
-- 3. v_departure_allocation & v_departure_availability: derived capacity views (NO stored mutable remaining).
-- 4. get_applicable_rate(service_id, on_date): temporal rate resolution via daterange.
-- 5. search_departures(...): advisory multi-constraint multi-attribute search.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Function: chargeable_qty
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chargeable_qty(cbm NUMERIC, weight_kg NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT GREATEST(cbm, weight_kg / 1000.0);
$$;

COMMENT ON FUNCTION chargeable_qty(NUMERIC, NUMERIC) IS 
'Single source of truth for chargeable freight quantity (revenue tonnes W/M). Compares CBM directly against weight in metric tonnes.';

-- ------------------------------------------------------------------------------
-- 2. Function: is_capacity_holding
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_capacity_holding(status TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT status IN ('PENDING', 'CONFIRMED');
$$;

COMMENT ON FUNCTION is_capacity_holding(TEXT) IS 
'Single source of truth determining whether a booking consumes departure physical capacity (PENDING or CONFIRMED).';

-- ------------------------------------------------------------------------------
-- 3. View: v_departure_allocation
-- ------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_departure_allocation AS
SELECT
    d.id AS departure_id,
    COALESCE(SUM(b.allocated_cbm) FILTER (WHERE is_capacity_holding(b.status)), 0)::NUMERIC(8,3) AS allocated_cbm,
    COALESCE(SUM(b.allocated_weight_kg) FILTER (WHERE is_capacity_holding(b.status)), 0)::NUMERIC(10,2) AS allocated_weight_kg
FROM departure d
LEFT JOIN booking b ON b.departure_id = d.id
GROUP BY d.id;

COMMENT ON VIEW v_departure_allocation IS 
'Derived allocation per departure aggregated from capacity-holding bookings. Returns 0 when no bookings exist. Never stored on departure.';

-- ------------------------------------------------------------------------------
-- 4. View: v_departure_availability
-- ------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_departure_availability AS
SELECT
    d.id AS departure_id,
    s.id AS service_id,
    p.company_name AS provider_name,
    po.unlocode AS origin_unlocode,
    pd.unlocode AS dest_unlocode,
    d.capacity_cbm,
    d.capacity_weight_kg,
    alloc.allocated_cbm,
    alloc.allocated_weight_kg,
    (d.capacity_cbm - alloc.allocated_cbm)::NUMERIC(8,3) AS remaining_cbm,
    (d.capacity_weight_kg - alloc.allocated_weight_kg)::NUMERIC(10,2) AS remaining_weight_kg,
    ROUND(
        GREATEST(
            (alloc.allocated_cbm / NULLIF(d.capacity_cbm, 0)),
            (alloc.allocated_weight_kg / NULLIF(d.capacity_weight_kg, 0))
        ) * 100.0,
        2
    ) AS utilisation_pct
FROM departure d
JOIN lcl_service s ON s.id = d.service_id
JOIN provider p ON p.id = s.provider_id
JOIN port po ON po.id = s.origin_port_id
JOIN port pd ON pd.id = s.dest_port_id
JOIN v_departure_allocation alloc ON alloc.departure_id = d.id;

COMMENT ON VIEW v_departure_availability IS 
'Derived availability view. NOTE: Availability is derived dynamically; booking re-validates capacity and eligibility under a row lock (SELECT FOR UPDATE) in Sprint 4. No stored remaining capacity columns.';

-- ------------------------------------------------------------------------------
-- 5. Function: get_applicable_rate
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_applicable_rate(
    p_service_id BIGINT,
    p_on_date DATE
)
RETURNS TABLE (
    id BIGINT,
    service_id BIGINT,
    rate_per_wm NUMERIC(12,2),
    currency CHAR(3),
    validity DATERANGE
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT
        r.id,
        r.service_id,
        r.rate_per_wm,
        r.currency,
        r.validity
    FROM rate r
    WHERE r.service_id = p_service_id
      AND r.validity @> p_on_date
    LIMIT 1;
$$;

COMMENT ON FUNCTION get_applicable_rate(BIGINT, DATE) IS 
'Returns the single rate row applicable to the service and date using temporal daterange containment (@>). Returns no rows for dates in deliberate rate gaps.';

-- ------------------------------------------------------------------------------
-- 6. Function: search_departures
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION search_departures(
    p_origin_port_id BIGINT,
    p_dest_port_id BIGINT,
    p_cbm NUMERIC,
    p_weight_kg NUMERIC,
    p_category_id BIGINT,
    p_cargo_ready_date DATE,
    p_as_of TIMESTAMPTZ DEFAULT now()
)
RETURNS TABLE (
    departure_id BIGINT,
    service_id BIGINT,
    provider_name TEXT,
    etd TIMESTAMPTZ,
    eta TIMESTAMPTZ,
    cutoff_at TIMESTAMPTZ,
    remaining_cbm NUMERIC(8,3),
    remaining_weight_kg NUMERIC(10,2),
    chargeable_qty NUMERIC,
    rate_per_wm NUMERIC(12,2),
    currency CHAR(3),
    estimated_total NUMERIC,
    utilisation_pct NUMERIC
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    /*
     * SEARCH IS ADVISORY.
     * Booking re-validates capacity, eligibility, cutoff, category acceptance,
     * and rate under a row lock in Sprint 4.
     */
    SELECT
        d.id AS departure_id,
        s.id AS service_id,
        p.company_name AS provider_name,
        d.etd,
        d.eta,
        d.cutoff_at,
        avail.remaining_cbm,
        avail.remaining_weight_kg,
        chargeable_qty(p_cbm, p_weight_kg) AS chargeable_qty,
        r.rate_per_wm,
        r.currency,
        ROUND((chargeable_qty(p_cbm, p_weight_kg) * r.rate_per_wm), 2) AS estimated_total,
        avail.utilisation_pct
    FROM departure d
    JOIN lcl_service s ON s.id = d.service_id
    JOIN provider p ON p.id = s.provider_id
    JOIN v_departure_availability avail ON avail.departure_id = d.id
    -- Rule 9: Rate availability on ETD date
    CROSS JOIN LATERAL get_applicable_rate(s.id, (d.etd AT TIME ZONE 'UTC')::date) r
    WHERE
        -- Rule 1: Lane match
        s.origin_port_id = p_origin_port_id
        AND s.dest_port_id = p_dest_port_id
        -- Rule 2: Service active
        AND s.is_active = TRUE
        -- Rule 3: Departure status SCHEDULED
        AND d.status = 'SCHEDULED'
        -- Rule 4: Cutoff strictly after as_of time
        AND d.cutoff_at > p_as_of
        -- Rule 5: Cargo ready date on or before cutoff date
        AND p_cargo_ready_date <= (d.cutoff_at AT TIME ZONE 'UTC')::date
        -- Rule 6: Service cargo acceptance
        AND EXISTS (
            SELECT 1
            FROM service_cargo_acceptance sca
            WHERE sca.service_id = s.id
              AND sca.category_id = p_category_id
        )
        -- Rule 7: CBM capacity
        AND avail.remaining_cbm >= p_cbm
        -- Rule 8: Weight capacity
        AND avail.remaining_weight_kg >= p_weight_kg
    ORDER BY
        estimated_total ASC,
        d.etd ASC;
$$;

COMMENT ON FUNCTION search_departures(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, DATE, TIMESTAMPTZ) IS
'SEARCH IS ADVISORY.
Booking re-validates capacity, eligibility, cutoff, category acceptance,
and rate under a row lock in Sprint 4.';

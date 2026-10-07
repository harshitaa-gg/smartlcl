-- ==============================================================================
-- SmartLCL - Sprint 3 Demonstration SQL Queries
-- Location: db/queries/search_demos.sql
-- All queries are deterministic and run on the Sprint 2 seeded database.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- A — Multi-table availability join
-- Business Question:
-- How does dynamic vessel capacity utilization, remaining payload, and voyage
-- progress compare across all active scheduled departures between Chennai and Singapore?
-- ------------------------------------------------------------------------------
SELECT
    avail.departure_id,
    avail.provider_name,
    avail.origin_unlocode || ' -> ' || avail.dest_unlocode AS trade_lane,
    d.etd,
    d.eta,
    d.cutoff_at,
    avail.capacity_cbm,
    avail.allocated_cbm,
    avail.remaining_cbm,
    avail.capacity_weight_kg,
    avail.allocated_weight_kg,
    avail.remaining_weight_kg,
    avail.utilisation_pct
FROM v_departure_availability avail
JOIN departure d ON d.id = avail.departure_id
WHERE avail.origin_unlocode = 'INMAA'
  AND avail.dest_unlocode = 'SGSIN'
  AND d.status = 'SCHEDULED'
ORDER BY d.etd ASC;

-- ------------------------------------------------------------------------------
-- B — NOT EXISTS
-- Business Question:
-- Which services have no departure in the next 30 days from the anchor date (2026-10-12)?
-- Demonstrates deterministic temporal filtering using NOT EXISTS.
-- ------------------------------------------------------------------------------
SELECT
    s.id AS service_id,
    p.company_name AS provider_name,
    po.unlocode AS origin_port,
    pd.unlocode AS dest_port,
    s.transit_days
FROM lcl_service s
JOIN provider p ON p.id = s.provider_id
JOIN port po ON po.id = s.origin_port_id
JOIN port pd ON pd.id = s.dest_port_id
WHERE s.is_active = TRUE
  AND NOT EXISTS (
      SELECT 1
      FROM departure d
      WHERE d.service_id = s.id
        AND d.status = 'SCHEDULED'
        AND d.etd >= '2026-10-12 00:00:00+00'::timestamptz
        AND d.etd <= ('2026-10-12 00:00:00+00'::timestamptz + INTERVAL '30 days')
  )
ORDER BY s.id ASC;

-- ------------------------------------------------------------------------------
-- C — GROUP BY + HAVING
-- Business Question:
-- Which providers have more than 2 departures?
-- Demonstrates relational aggregation over provider voyage offerings.
-- ------------------------------------------------------------------------------
SELECT
    p.company_name AS provider_name,
    COUNT(d.id) AS scheduled_departure_count,
    MIN(d.etd) AS earliest_etd,
    MAX(d.etd) AS latest_etd
FROM provider p
JOIN lcl_service s ON s.provider_id = p.id
JOIN departure d ON d.service_id = s.id
GROUP BY p.id, p.company_name
HAVING COUNT(d.id) > 2
ORDER BY scheduled_departure_count DESC, p.company_name ASC;

-- ------------------------------------------------------------------------------
-- D — CTE + RANK()
-- Business Question:
-- What is the cheapest departure per lane?
-- Demonstrates CTE decomposition and RANK() window function partitioned by origin/destination lane.
-- ------------------------------------------------------------------------------
WITH ranked_lane_departures AS (
    SELECT
        po.unlocode AS origin_unlocode,
        pd.unlocode AS dest_unlocode,
        p.company_name AS provider_name,
        d.id AS departure_id,
        d.etd,
        r.rate_per_wm,
        r.currency,
        RANK() OVER (
            PARTITION BY po.unlocode, pd.unlocode
            ORDER BY r.rate_per_wm ASC, d.etd ASC
        ) AS price_rank
    FROM departure d
    JOIN lcl_service s ON s.id = d.service_id
    JOIN provider p ON p.id = s.provider_id
    JOIN port po ON po.id = s.origin_port_id
    JOIN port pd ON pd.id = s.dest_port_id
    JOIN rate r ON r.service_id = s.id AND r.validity @> (d.etd AT TIME ZONE 'UTC')::date
    WHERE d.status = 'SCHEDULED'
      AND s.is_active = TRUE
)
SELECT
    origin_unlocode || ' -> ' || dest_unlocode AS trade_lane,
    provider_name,
    departure_id,
    etd,
    rate_per_wm,
    currency,
    price_rank
FROM ranked_lane_departures
WHERE price_rank = 1
ORDER BY trade_lane ASC, provider_name ASC;

-- ------------------------------------------------------------------------------
-- E — LEFT JOIN anti-pattern
-- Business Question:
-- Which cargo categories are not accepted by any service?
-- Demonstrates the deliberate LEFT JOIN ... WHERE ... IS NULL anti-join pattern.
-- ------------------------------------------------------------------------------
SELECT
    c.id AS category_id,
    c.code AS category_code,
    c.name AS category_name,
    c.is_dangerous,
    c.is_perishable
FROM cargo_category c
LEFT JOIN service_cargo_acceptance sca ON sca.category_id = c.id
WHERE sca.service_id IS NULL
ORDER BY c.code ASC;

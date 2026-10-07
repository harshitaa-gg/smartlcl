-- ==============================================================================
-- Seed: 003_synthetic_operations.sql
-- Description: Deterministic synthetic operational data:
--              cargo categories (8), services (8), service_cargo_acceptance,
--              departures (4 per service = 32), rates (temporal), shipments (20).
-- NO bookings inserted!
-- Anchor date: 2026-10-12
-- ==============================================================================

-- 1. Cargo Categories (8 categories)
INSERT INTO cargo_category (code, name, is_dangerous, is_perishable)
VALUES
    ('GENERAL', 'General Cargo / Dry Freight', FALSE, FALSE),
    ('TEXTILES', 'Textiles, Garments and Made-ups', FALSE, FALSE),
    ('ELECTRONICS', 'Electronics & High-Tech Components', FALSE, FALSE),
    ('MACHINERY_PARTS', 'Machinery, Pumps and Auto Components', FALSE, FALSE),
    ('PACKAGED_FOOD', 'Packaged Food & Beverages (Dry)', FALSE, FALSE),
    ('NON_HAZ_CHEMICALS', 'Non-Hazardous Industrial Chemicals', FALSE, FALSE),
    ('HAZARDOUS_DG', 'Hazardous & Dangerous Goods (DG)', TRUE, FALSE),
    ('PERISHABLES', 'Temperature-Sensitive Perishables', FALSE, TRUE)
ON CONFLICT (code) DO NOTHING;

-- 2. Services (8 LCL services across realistic lanes)
-- Chennai -> Singapore (2 providers: BlueAnchor, OrientFreight)
-- Tuticorin -> Colombo (Maritime Crossings)
-- Mundra -> Jebel Ali (BlueAnchor)
-- Nhava Sheva -> Rotterdam (Pacific Bay)
-- Cochin -> Jebel Ali (OrientFreight)
-- Visakhapatnam -> Singapore (Zenith Cargo)
-- Kolkata -> Port Klang (Maritime Crossings)

INSERT INTO lcl_service (provider_id, origin_port_id, dest_port_id, transit_days, is_active)
SELECT p.id, po.id, pd.id, s.transit_days, TRUE
FROM (
    VALUES
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', 5),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', 6),
        ('Maritime Crossings Freight', 'INTUT', 'LKCMB', 2),
        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', 4),
        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', 22),
        ('OrientFreight Consolidators', 'INCOK', 'AEJEA', 5),
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', 7),
        ('Maritime Crossings Freight', 'INCCU', 'MYPKG', 6)
) AS s(provider_name, origin_code, dest_code, transit_days)
JOIN provider p ON p.company_name = s.provider_name
JOIN port po ON po.unlocode = s.origin_code
JOIN port pd ON pd.unlocode = s.dest_code
ON CONFLICT (provider_id, origin_port_id, dest_port_id) DO NOTHING;

-- 3. Service Cargo Acceptance (M:N)
-- Rules: Cargo acceptance must vary.
-- At least two services must refuse hazardous cargo (Services 1 & 3 refuse DG).
-- At least two services must refuse perishables (Services 1 & 4 refuse PERISHABLES).
-- S1: BlueAnchor MAA->SIN: Accepts GENERAL, TEXTILES, ELECTRONICS, MACHINERY_PARTS, PACKAGED_FOOD, NON_HAZ_CHEMICALS (Refuses HAZARDOUS_DG, PERISHABLES)
-- S2: OrientFreight MAA->SIN: Accepts ALL 8 categories.
-- S3: Maritime Crossings TUT->CMB: Accepts GENERAL, TEXTILES, MACHINERY_PARTS, PACKAGED_FOOD, PERISHABLES (Refuses HAZARDOUS_DG, ELECTRONICS, NON_HAZ_CHEMICALS)
-- S4: BlueAnchor MUN->JEA: Accepts GENERAL, TEXTILES, ELECTRONICS, MACHINERY_PARTS, NON_HAZ_CHEMICALS, HAZARDOUS_DG (Refuses PERISHABLES, PACKAGED_FOOD)
-- S5: Pacific Bay NSA->RTM: Accepts GENERAL, TEXTILES, ELECTRONICS, MACHINERY_PARTS, NON_HAZ_CHEMICALS, HAZARDOUS_DG (Long haul, refuses PERISHABLES)
-- S6: OrientFreight COK->JEA: Accepts GENERAL, TEXTILES, PACKAGED_FOOD, PERISHABLES, NON_HAZ_CHEMICALS (Refuses HAZARDOUS_DG)
-- S7: Zenith Cargo Network VTZ->SIN: Accepts GENERAL, TEXTILES, ELECTRONICS, MACHINERY_PARTS, PACKAGED_FOOD, NON_HAZ_CHEMICALS, HAZARDOUS_DG
-- S8: Maritime Crossings CCU->PKG: Accepts GENERAL, TEXTILES, MACHINERY_PARTS, PACKAGED_FOOD, NON_HAZ_CHEMICALS

INSERT INTO service_cargo_acceptance (service_id, category_id)
SELECT s.id, c.id
FROM (
    VALUES
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', 'GENERAL'),
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', 'TEXTILES'),
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', 'ELECTRONICS'),
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', 'MACHINERY_PARTS'),
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', 'PACKAGED_FOOD'),
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', 'NON_HAZ_CHEMICALS'),

        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', 'GENERAL'),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', 'TEXTILES'),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', 'ELECTRONICS'),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', 'MACHINERY_PARTS'),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', 'PACKAGED_FOOD'),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', 'NON_HAZ_CHEMICALS'),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', 'HAZARDOUS_DG'),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', 'PERISHABLES'),

        ('Maritime Crossings Freight', 'INTUT', 'LKCMB', 'GENERAL'),
        ('Maritime Crossings Freight', 'INTUT', 'LKCMB', 'TEXTILES'),
        ('Maritime Crossings Freight', 'INTUT', 'LKCMB', 'MACHINERY_PARTS'),
        ('Maritime Crossings Freight', 'INTUT', 'LKCMB', 'PACKAGED_FOOD'),
        ('Maritime Crossings Freight', 'INTUT', 'LKCMB', 'PERISHABLES'),

        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', 'GENERAL'),
        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', 'TEXTILES'),
        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', 'ELECTRONICS'),
        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', 'MACHINERY_PARTS'),
        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', 'NON_HAZ_CHEMICALS'),
        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', 'HAZARDOUS_DG'),

        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', 'GENERAL'),
        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', 'TEXTILES'),
        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', 'ELECTRONICS'),
        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', 'MACHINERY_PARTS'),
        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', 'NON_HAZ_CHEMICALS'),
        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', 'HAZARDOUS_DG'),

        ('OrientFreight Consolidators', 'INCOK', 'AEJEA', 'GENERAL'),
        ('OrientFreight Consolidators', 'INCOK', 'AEJEA', 'TEXTILES'),
        ('OrientFreight Consolidators', 'INCOK', 'AEJEA', 'PACKAGED_FOOD'),
        ('OrientFreight Consolidators', 'INCOK', 'AEJEA', 'PERISHABLES'),
        ('OrientFreight Consolidators', 'INCOK', 'AEJEA', 'NON_HAZ_CHEMICALS'),

        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', 'GENERAL'),
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', 'TEXTILES'),
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', 'ELECTRONICS'),
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', 'MACHINERY_PARTS'),
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', 'PACKAGED_FOOD'),
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', 'NON_HAZ_CHEMICALS'),
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', 'HAZARDOUS_DG'),

        ('Maritime Crossings Freight', 'INCCU', 'MYPKG', 'GENERAL'),
        ('Maritime Crossings Freight', 'INCCU', 'MYPKG', 'TEXTILES'),
        ('Maritime Crossings Freight', 'INCCU', 'MYPKG', 'MACHINERY_PARTS'),
        ('Maritime Crossings Freight', 'INCCU', 'MYPKG', 'PACKAGED_FOOD'),
        ('Maritime Crossings Freight', 'INCCU', 'MYPKG', 'NON_HAZ_CHEMICALS')
) AS sca(provider_name, origin_code, dest_code, cat_code)
JOIN provider p ON p.company_name = sca.provider_name
JOIN port po ON po.unlocode = sca.origin_code
JOIN port pd ON pd.unlocode = sca.dest_code
JOIN lcl_service s ON s.provider_id = p.id AND s.origin_port_id = po.id AND s.dest_port_id = pd.id
JOIN cargo_category c ON c.code = sca.cat_code
ON CONFLICT (service_id, category_id) DO NOTHING;

-- 4. Rates (per service in USD per W/M, temporal validity)
-- Rules:
-- - One service (Service 1: BlueAnchor MAA->SIN) has two adjacent validity periods representing a price change.
-- - One service (Service 2: OrientFreight MAA->SIN) has a deliberate rate-validity gap.
-- - All rate validity periods comply with temporal exclusion constraint (service_id WITH =, validity WITH &&).
-- Anchor date: 2026-10-12
INSERT INTO rate (service_id, rate_per_wm, currency, validity)
SELECT s.id, r.rate_per_wm, r.currency, r.validity
FROM (
    VALUES
        -- S1: BlueAnchor MAA->SIN (Adjacent validity periods: price increase from 65.00 to 72.00)
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', 65.00, 'USD', '[2026-10-01, 2026-10-25)'::daterange),
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', 72.00, 'USD', '[2026-10-25, 2026-11-30)'::daterange),

        -- S2: OrientFreight MAA->SIN (Deliberate rate validity GAP between 2026-10-20 and 2026-10-28)
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', 62.00, 'USD', '[2026-10-01, 2026-10-20)'::daterange),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', 68.00, 'USD', '[2026-10-28, 2026-11-30)'::daterange),

        -- S3: Maritime Crossings TUT->CMB
        ('Maritime Crossings Freight', 'INTUT', 'LKCMB', 45.00, 'USD', '[2026-10-01, 2026-11-30)'::daterange),

        -- S4: BlueAnchor MUN->JEA
        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', 55.00, 'USD', '[2026-10-01, 2026-11-30)'::daterange),

        -- S5: Pacific Bay NSA->RTM
        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', 110.00, 'USD', '[2026-10-01, 2026-11-30)'::daterange),

        -- S6: OrientFreight COK->JEA
        ('OrientFreight Consolidators', 'INCOK', 'AEJEA', 58.00, 'USD', '[2026-10-01, 2026-11-30)'::daterange),

        -- S7: Zenith Cargo Network VTZ->SIN
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', 64.00, 'USD', '[2026-10-01, 2026-11-30)'::daterange),

        -- S8: Maritime Crossings CCU->PKG
        ('Maritime Crossings Freight', 'INCCU', 'MYPKG', 70.00, 'USD', '[2026-10-01, 2026-11-30)'::daterange)
) AS r(provider_name, origin_code, dest_code, rate_per_wm, currency, validity)
JOIN provider p ON p.company_name = r.provider_name
JOIN port po ON po.unlocode = r.origin_code
JOIN port pd ON pd.unlocode = r.dest_code
JOIN lcl_service s ON s.provider_id = p.id AND s.origin_port_id = po.id AND s.dest_port_id = pd.id
ON CONFLICT DO NOTHING;

-- 5. Departures (4 weekly departures per service starting 2026-10-14 = 32 departures)
-- Varied CBM capacity between 20 and 60, weight capacity between 15000 and 35000.
-- Cut-off 3 to 5 days before ETD.
-- Edge Cases:
-- 1. Exactly 10 CBM and 10,000 kg capacity: Departure S1 Week 1 (2026-10-14).
-- 2. Cut-off already passed relative to anchor date 2026-10-12: Departure S1 Week 1 (cutoff 2026-10-10 18:00:00+00).
-- 3. CANCELLED departure: Departure S6 Week 2 (2026-10-21).

INSERT INTO departure (service_id, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg, status)
SELECT s.id, d.etd, d.eta, d.cutoff_at, d.capacity_cbm, d.capacity_weight_kg, d.status
FROM (
    VALUES
        -- Service 1: BlueAnchor MAA -> SGSIN (Transit 5d)
        -- EDGE CASE 1 & 2: 10 CBM, 10,000 kg capacity; Cutoff 2026-10-10 (passed relative to 2026-10-12)
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', '2026-10-14 10:00:00+00'::timestamptz, '2026-10-19 14:00:00+00'::timestamptz, '2026-10-10 18:00:00+00'::timestamptz, 10.000, 10000.00, 'SCHEDULED'),
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', '2026-10-21 10:00:00+00'::timestamptz, '2026-10-26 14:00:00+00'::timestamptz, '2026-10-17 18:00:00+00'::timestamptz, 45.000, 26000.00, 'SCHEDULED'),
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', '2026-10-28 10:00:00+00'::timestamptz, '2026-11-02 14:00:00+00'::timestamptz, '2026-10-24 18:00:00+00'::timestamptz, 50.000, 28000.00, 'SCHEDULED'),
        ('BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', '2026-11-04 10:00:00+00'::timestamptz, '2026-11-09 14:00:00+00'::timestamptz, '2026-10-31 18:00:00+00'::timestamptz, 40.000, 24000.00, 'SCHEDULED'),

        -- Service 2: OrientFreight MAA -> SGSIN (Transit 6d)
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', '2026-10-15 08:00:00+00'::timestamptz, '2026-10-21 12:00:00+00'::timestamptz, '2026-10-12 18:00:00+00'::timestamptz, 40.000, 25000.00, 'SCHEDULED'),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', '2026-10-22 08:00:00+00'::timestamptz, '2026-10-28 12:00:00+00'::timestamptz, '2026-10-19 18:00:00+00'::timestamptz, 55.000, 30000.00, 'SCHEDULED'),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', '2026-10-29 08:00:00+00'::timestamptz, '2026-11-04 12:00:00+00'::timestamptz, '2026-10-26 18:00:00+00'::timestamptz, 35.000, 22000.00, 'SCHEDULED'),
        ('OrientFreight Consolidators', 'INMAA', 'SGSIN', '2026-11-05 08:00:00+00'::timestamptz, '2026-11-11 12:00:00+00'::timestamptz, '2026-11-02 18:00:00+00'::timestamptz, 48.000, 27000.00, 'SCHEDULED'),

        -- Service 3: Maritime Crossings TUT -> LKCMB (Transit 2d)
        ('Maritime Crossings Freight', 'INTUT', 'LKCMB', '2026-10-14 14:00:00+00'::timestamptz, '2026-10-16 18:00:00+00'::timestamptz, '2026-10-11 18:00:00+00'::timestamptz, 25.000, 18000.00, 'SCHEDULED'),
        ('Maritime Crossings Freight', 'INTUT', 'LKCMB', '2026-10-21 14:00:00+00'::timestamptz, '2026-10-23 18:00:00+00'::timestamptz, '2026-10-18 18:00:00+00'::timestamptz, 30.000, 20000.00, 'SCHEDULED'),
        ('Maritime Crossings Freight', 'INTUT', 'LKCMB', '2026-10-28 14:00:00+00'::timestamptz, '2026-10-30 18:00:00+00'::timestamptz, '2026-10-25 18:00:00+00'::timestamptz, 28.000, 19000.00, 'SCHEDULED'),
        ('Maritime Crossings Freight', 'INTUT', 'LKCMB', '2026-11-04 14:00:00+00'::timestamptz, '2026-11-06 18:00:00+00'::timestamptz, '2026-11-01 18:00:00+00'::timestamptz, 32.000, 21000.00, 'SCHEDULED'),

        -- Service 4: BlueAnchor MUN -> AEJEA (Transit 4d)
        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', '2026-10-16 06:00:00+00'::timestamptz, '2026-10-20 12:00:00+00'::timestamptz, '2026-10-13 18:00:00+00'::timestamptz, 50.000, 32000.00, 'SCHEDULED'),
        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', '2026-10-23 06:00:00+00'::timestamptz, '2026-10-27 12:00:00+00'::timestamptz, '2026-10-20 18:00:00+00'::timestamptz, 52.000, 33000.00, 'SCHEDULED'),
        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', '2026-10-30 06:00:00+00'::timestamptz, '2026-11-03 12:00:00+00'::timestamptz, '2026-10-27 18:00:00+00'::timestamptz, 48.000, 30000.00, 'SCHEDULED'),
        ('BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', '2026-11-06 06:00:00+00'::timestamptz, '2026-11-10 12:00:00+00'::timestamptz, '2026-11-03 18:00:00+00'::timestamptz, 55.000, 34000.00, 'SCHEDULED'),

        -- Service 5: Pacific Bay NSA -> NLRTM (Transit 22d)
        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', '2026-10-17 12:00:00+00'::timestamptz, '2026-11-08 16:00:00+00'::timestamptz, '2026-10-13 18:00:00+00'::timestamptz, 60.000, 35000.00, 'SCHEDULED'),
        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', '2026-10-24 12:00:00+00'::timestamptz, '2026-11-15 16:00:00+00'::timestamptz, '2026-10-20 18:00:00+00'::timestamptz, 58.000, 34000.00, 'SCHEDULED'),
        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', '2026-10-31 12:00:00+00'::timestamptz, '2026-11-22 16:00:00+00'::timestamptz, '2026-10-27 18:00:00+00'::timestamptz, 60.000, 35000.00, 'SCHEDULED'),
        ('Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', '2026-11-07 12:00:00+00'::timestamptz, '2026-11-29 16:00:00+00'::timestamptz, '2026-11-03 18:00:00+00'::timestamptz, 55.000, 32000.00, 'SCHEDULED'),

        -- Service 6: OrientFreight COK -> AEJEA (Transit 5d)
        -- EDGE CASE 3: CANCELLED departure on 2026-10-21
        ('OrientFreight Consolidators', 'INCOK', 'AEJEA', '2026-10-14 16:00:00+00'::timestamptz, '2026-10-19 20:00:00+00'::timestamptz, '2026-10-11 18:00:00+00'::timestamptz, 30.000, 20000.00, 'SCHEDULED'),
        ('OrientFreight Consolidators', 'INCOK', 'AEJEA', '2026-10-21 16:00:00+00'::timestamptz, '2026-10-26 20:00:00+00'::timestamptz, '2026-10-18 18:00:00+00'::timestamptz, 30.000, 20000.00, 'CANCELLED'),
        ('OrientFreight Consolidators', 'INCOK', 'AEJEA', '2026-10-28 16:00:00+00'::timestamptz, '2026-11-02 20:00:00+00'::timestamptz, '2026-10-25 18:00:00+00'::timestamptz, 35.000, 22000.00, 'SCHEDULED'),
        ('OrientFreight Consolidators', 'INCOK', 'AEJEA', '2026-11-04 16:00:00+00'::timestamptz, '2026-11-09 20:00:00+00'::timestamptz, '2026-11-01 18:00:00+00'::timestamptz, 32.000, 21000.00, 'SCHEDULED'),

        -- Service 7: Zenith Cargo Network VTZ -> SGSIN (Transit 7d)
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', '2026-10-18 04:00:00+00'::timestamptz, '2026-10-25 10:00:00+00'::timestamptz, '2026-10-14 18:00:00+00'::timestamptz, 40.000, 26000.00, 'SCHEDULED'),
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', '2026-10-25 04:00:00+00'::timestamptz, '2026-11-01 10:00:00+00'::timestamptz, '2026-10-21 18:00:00+00'::timestamptz, 42.000, 27000.00, 'SCHEDULED'),
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', '2026-11-01 04:00:00+00'::timestamptz, '2026-11-08 10:00:00+00'::timestamptz, '2026-10-28 18:00:00+00'::timestamptz, 38.000, 25000.00, 'SCHEDULED'),
        ('Zenith Cargo Network', 'INVTZ', 'SGSIN', '2026-11-08 04:00:00+00'::timestamptz, '2026-11-15 10:00:00+00'::timestamptz, '2026-11-04 18:00:00+00'::timestamptz, 45.000, 28000.00, 'SCHEDULED'),

        -- Service 8: Maritime Crossings CCU -> MYPKG (Transit 6d)
        ('Maritime Crossings Freight', 'INCCU', 'MYPKG', '2026-10-16 10:00:00+00'::timestamptz, '2026-10-22 16:00:00+00'::timestamptz, '2026-10-12 18:00:00+00'::timestamptz, 36.000, 23000.00, 'SCHEDULED'),
        ('Maritime Crossings Freight', 'INCCU', 'MYPKG', '2026-10-23 10:00:00+00'::timestamptz, '2026-10-29 16:00:00+00'::timestamptz, '2026-10-19 18:00:00+00'::timestamptz, 38.000, 24000.00, 'SCHEDULED'),
        ('Maritime Crossings Freight', 'INCCU', 'MYPKG', '2026-10-30 10:00:00+00'::timestamptz, '2026-11-05 16:00:00+00'::timestamptz, '2026-10-26 18:00:00+00'::timestamptz, 35.000, 22000.00, 'SCHEDULED'),
        ('Maritime Crossings Freight', 'INCCU', 'MYPKG', '2026-11-06 10:00:00+00'::timestamptz, '2026-11-12 16:00:00+00'::timestamptz, '2026-11-02 18:00:00+00'::timestamptz, 40.000, 25000.00, 'SCHEDULED')
) AS d(provider_name, origin_code, dest_code, etd, eta, cutoff_at, capacity_cbm, capacity_weight_kg, status)
JOIN provider p ON p.company_name = d.provider_name
JOIN port po ON po.unlocode = d.origin_code
JOIN port pd ON pd.unlocode = d.dest_code
JOIN lcl_service s ON s.provider_id = p.id AND s.origin_port_id = po.id AND s.dest_port_id = pd.id
ON CONFLICT (service_id, etd) DO NOTHING;

-- 6. Shipments (20 synthetic shipments across traders and cargo categories)
-- Edge Cases:
-- 4. Cargo category refused by relevant service:
--    Shipment 19: HAZARDOUS_DG on Chennai (INMAA) -> Singapore (SGSIN) lane.
--    Refused by BlueAnchor (Service 1 does not accept DG).
-- 5. Weight is binding limit rather than CBM:
--    Shipment 20: 3.5 CBM but 14,000.00 kg dense cargo (chargeable_qty = GREATEST(3.5, 14000/1000) = 14.0 WM).
--    Weight dominates volume by 4x.

INSERT INTO shipment (trader_id, origin_port_id, dest_port_id, category_id, cbm, weight_kg, cargo_ready_date, description)
SELECT t.id, po.id, pd.id, c.id, sh.cbm, sh.weight_kg, sh.cargo_ready_date, sh.description
FROM (
    VALUES
        -- 1. Tirupur FineKnits (Textiles, MAA -> SIN)
        ('Tirupur FineKnits Apparel', 'INMAA', 'SGSIN', 'TEXTILES', 8.500, 2200.00, '2026-10-13'::date, 'Cotton knitted t-shirts in cartons'),
        -- 2. Kovai AgroPump (Machinery, MAA -> SIN)
        ('Kovai AgroPump Technologies', 'INMAA', 'SGSIN', 'MACHINERY_PARTS', 12.000, 6500.00, '2026-10-14'::date, 'Submersible water pumps on crates'),
        -- 3. Malabar SpiceCraft (Packaged Food, COK -> JEA)
        ('Malabar SpiceCraft Traders', 'INCOK', 'AEJEA', 'PACKAGED_FOOD', 6.000, 3000.00, '2026-10-13'::date, 'Cardamom and black pepper sealed packs'),
        -- 4. Madras Precision AutoGears (Machinery, MAA -> SIN)
        ('Madras Precision AutoGears', 'INMAA', 'SGSIN', 'MACHINERY_PARTS', 5.200, 4800.00, '2026-10-15'::date, 'Automotive transmission gears'),
        -- 5. Chola Bronze Handicrafts (General, TUT -> CMB)
        ('Chola Bronze & Stone Handicrafts', 'INTUT', 'LKCMB', 'GENERAL', 3.800, 1800.00, '2026-10-13'::date, 'Cast bronze temple craft artifacts'),
        -- 6. Surat Elite Textile (Textiles, MUN -> JEA)
        ('Surat Elite Textile Weavers', 'INMUN', 'AEJEA', 'TEXTILES', 14.500, 4200.00, '2026-10-15'::date, 'Polyester jacquard fabric rolls'),
        -- 7. Bengal Fine Ceramics (General, CCU -> MYPKG)
        ('Bengal Fine Ceramics Works', 'INCCU', 'MYPKG', 'GENERAL', 7.200, 5100.00, '2026-10-14'::date, 'Glazed porcelain sanitary ware'),
        -- 8. Punjab Heavy Valve (Machinery, NSA -> RTM)
        ('Punjab Heavy Valve Industries', 'INNSA', 'NLRTM', 'MACHINERY_PARTS', 15.000, 11500.00, '2026-10-16'::date, 'Industrial cast steel gate valves'),
        -- 9. Mysore Sandalwood (Non-Haz Chem, COK -> JEA)
        ('Mysore Sandalwood & Herbal Essentials', 'INCOK', 'AEJEA', 'NON_HAZ_CHEMICALS', 2.500, 1200.00, '2026-10-13'::date, 'Herbal extract and cosmetic oils'),
        -- 10. Andhra AquaFeed (Non-Haz Chem, VTZ -> SIN)
        ('Andhra AquaFeed Formulations', 'INVTZ', 'SGSIN', 'NON_HAZ_CHEMICALS', 9.000, 6800.00, '2026-10-17'::date, 'Bio-mineral aquaculture feed supplement'),
        -- 11. Tirupur FineKnits (Textiles, TUT -> CMB)
        ('Tirupur FineKnits Apparel', 'INTUT', 'LKCMB', 'TEXTILES', 4.500, 1100.00, '2026-10-14'::date, 'Woven hosiery and garments'),
        -- 12. Kovai AgroPump (Machinery, MUN -> JEA)
        ('Kovai AgroPump Technologies', 'INMUN', 'AEJEA', 'MACHINERY_PARTS', 8.000, 5200.00, '2026-10-18'::date, 'Monobloc agricultural pump sets'),
        -- 13. Malabar SpiceCraft (Perishables, COK -> JEA)
        ('Malabar SpiceCraft Traders', 'INCOK', 'AEJEA', 'PERISHABLES', 4.000, 2100.00, '2026-10-13'::date, 'Fresh vacuum-packed green ginger'),
        -- 14. Madras Precision AutoGears (Electronics, MAA -> SIN)
        ('Madras Precision AutoGears', 'INMAA', 'SGSIN', 'ELECTRONICS', 6.400, 2600.00, '2026-10-19'::date, 'Automotive sensor wiring harnesses'),
        -- 15. Chola Bronze Handicrafts (General, MAA -> SIN)
        ('Chola Bronze & Stone Handicrafts', 'INMAA', 'SGSIN', 'GENERAL', 2.000, 950.00, '2026-10-20'::date, 'Carved stone miniature sculptures'),
        -- 16. Surat Elite Textile (Textiles, NSA -> RTM)
        ('Surat Elite Textile Weavers', 'INNSA', 'NLRTM', 'TEXTILES', 18.000, 5800.00, '2026-10-22'::date, 'Synthetic fabric and upholstery'),
        -- 17. Bengal Fine Ceramics (General, NSA -> RTM)
        ('Bengal Fine Ceramics Works', 'INNSA', 'NLRTM', 'GENERAL', 11.000, 8900.00, '2026-10-21'::date, 'Decorative ceramic stoneware tiles'),
        -- 18. Punjab Heavy Valve (Machinery, MUN -> JEA)
        ('Punjab Heavy Valve Industries', 'INMUN', 'AEJEA', 'MACHINERY_PARTS', 10.500, 7800.00, '2026-10-20'::date, 'Flanged pipeline check valves'),

        -- EDGE CASE 4: Refused cargo category by relevant service
        -- HAZARDOUS_DG on Chennai (INMAA) -> Singapore (SGSIN). BlueAnchor (Service 1) explicitly refuses HAZARDOUS_DG.
        ('Andhra AquaFeed Formulations', 'INMAA', 'SGSIN', 'HAZARDOUS_DG', 4.000, 3200.00, '2026-10-14'::date, 'Class 9 environmentally hazardous aquaculture sanitiser'),

        -- EDGE CASE 5: Weight is binding capacity limit rather than CBM
        -- Dense lead ballast / heavy machinery alloy: 3.5 CBM but 14,000 kg weight (W/M = 14.0, weight binding).
        ('Madras Precision AutoGears', 'INMAA', 'SGSIN', 'MACHINERY_PARTS', 3.500, 14000.00, '2026-10-15'::date, 'High-density alloy die-cast forging blocks')
) AS sh(trader_name, origin_code, dest_code, cat_code, cbm, weight_kg, cargo_ready_date, description)
JOIN trader t ON t.company_name = sh.trader_name
JOIN port po ON po.unlocode = sh.origin_code
JOIN port pd ON pd.unlocode = sh.dest_code
JOIN cargo_category c ON c.code = sh.cat_code
WHERE NOT EXISTS (
    SELECT 1 FROM shipment s2
    WHERE s2.trader_id = t.id
      AND s2.origin_port_id = po.id
      AND s2.dest_port_id = pd.id
      AND s2.category_id = c.id
      AND s2.description = sh.description
);

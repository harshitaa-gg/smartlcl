-- ==============================================================================
-- Seed: 004_synthetic_bookings.sql
-- Description: Deterministic synthetic booking creation (Sprint 4).
-- Rules:
-- 1. Exactly 15 synthetic bookings created exclusively via create_booking().
-- 2. Uses p_as_of = '2026-10-12 09:00:00+05:30' for deterministic behaviour.
-- 3. Includes PENDING, CONFIRMED (via confirm_booking), and CANCELLED (via cancel_booking).
-- 4. Idempotent: checks IF NOT EXISTS before calling create_booking().
-- 5. Concurrency demo departure (10 CBM / 10,000 kg on MAA -> SGSIN 2026-10-14)
--    is left COMPLETELY EMPTY (zero allocated capacity).
-- ==============================================================================

DO $$
DECLARE
    r RECORD;
    v_shipment_id BIGINT;
    v_departure_id BIGINT;
    v_booking_id BIGINT;
BEGIN
    FOR r IN
        SELECT * FROM (
            VALUES
                -- 1. PENDING -> CONFIRMED: OrientFreight MAA->SIN
                ('Cotton knitted t-shirts in cartons', 'OrientFreight Consolidators', 'INMAA', 'SGSIN', '2026-10-15 08:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 2. PENDING -> CONFIRMED: Maritime Crossings TUT->CMB
                ('Woven hosiery and garments', 'Maritime Crossings Freight', 'INTUT', 'LKCMB', '2026-10-21 14:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 3. PENDING -> CONFIRMED: OrientFreight MAA->SIN
                ('Submersible water pumps on crates', 'OrientFreight Consolidators', 'INMAA', 'SGSIN', '2026-10-15 08:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 4. PENDING -> CONFIRMED: BlueAnchor MUN->JEA
                ('Monobloc agricultural pump sets', 'BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', '2026-10-16 06:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 5. PENDING -> CONFIRMED: OrientFreight COK->JEA
                ('Fresh vacuum-packed green ginger', 'OrientFreight Consolidators', 'INCOK', 'AEJEA', '2026-10-28 16:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 6. PENDING -> CONFIRMED: OrientFreight COK->JEA
                ('Cardamom and black pepper sealed packs', 'OrientFreight Consolidators', 'INCOK', 'AEJEA', '2026-10-28 16:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 7. PENDING -> CONFIRMED: BlueAnchor MAA->SIN
                ('Automotive transmission gears', 'BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', '2026-10-21 10:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 8. PENDING -> CANCELLED: BlueAnchor MAA->SIN (releases capacity)
                ('High-density alloy die-cast forging blocks', 'BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', '2026-10-21 10:00:00+00'::timestamptz, 'CANCELLED'),
                -- 9. PENDING -> CONFIRMED: OrientFreight MAA->SIN
                ('Automotive sensor wiring harnesses', 'OrientFreight Consolidators', 'INMAA', 'SGSIN', '2026-10-29 08:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 10. PENDING -> CONFIRMED: BlueAnchor MAA->SIN
                ('Carved stone miniature sculptures', 'BlueAnchor Logistics Lines', 'INMAA', 'SGSIN', '2026-10-28 10:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 11. PENDING -> CONFIRMED: Maritime Crossings TUT->CMB
                ('Cast bronze temple craft artifacts', 'Maritime Crossings Freight', 'INTUT', 'LKCMB', '2026-10-28 14:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 12. PENDING -> CONFIRMED: BlueAnchor MUN->JEA
                ('Polyester jacquard fabric rolls', 'BlueAnchor Logistics Lines', 'INMUN', 'AEJEA', '2026-10-23 06:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 13. PENDING -> CONFIRMED: Pacific Bay NSA->RTM
                ('Synthetic fabric and upholstery', 'Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', '2026-10-17 12:00:00+00'::timestamptz, 'CONFIRMED'),
                -- 14. PENDING: Pacific Bay NSA->RTM
                ('Decorative ceramic stoneware tiles', 'Pacific Bay Shipping Solutions', 'INNSA', 'NLRTM', '2026-10-24 12:00:00+00'::timestamptz, 'PENDING'),
                -- 15. PENDING: Maritime Crossings CCU->PKG
                ('Glazed porcelain sanitary ware', 'Maritime Crossings Freight', 'INCCU', 'MYPKG', '2026-10-16 10:00:00+00'::timestamptz, 'PENDING')
        ) AS t(shipment_desc, provider_name, origin_unlocode, dest_unlocode, departure_etd, target_status)
    LOOP
        -- Lookup shipment
        SELECT sh.id INTO v_shipment_id
        FROM shipment sh
        WHERE sh.description = r.shipment_desc;

        -- Lookup departure
        SELECT d.id INTO v_departure_id
        FROM departure d
        JOIN lcl_service s ON s.id = d.service_id
        JOIN provider p ON p.id = s.provider_id
        JOIN port po ON po.id = s.origin_port_id
        JOIN port pd ON pd.id = s.dest_port_id
        WHERE p.company_name = r.provider_name
          AND po.unlocode = r.origin_unlocode
          AND pd.unlocode = r.dest_unlocode
          AND d.etd = r.departure_etd;

        -- Check if booking already created for this shipment
        IF NOT EXISTS (SELECT 1 FROM booking WHERE shipment_id = v_shipment_id) THEN
            v_booking_id := create_booking(
                p_shipment_id := v_shipment_id,
                p_departure_id := v_departure_id,
                p_as_of := '2026-10-12 09:00:00+05:30'::timestamptz
            );

            IF r.target_status = 'CONFIRMED' THEN
                PERFORM confirm_booking(v_booking_id);
            ELSIF r.target_status = 'CANCELLED' THEN
                PERFORM cancel_booking(v_booking_id);
            END IF;
        END IF;
    END LOOP;
END $$;

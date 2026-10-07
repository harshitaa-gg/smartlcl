-- ==============================================================================
-- Migration: 0003_operational.sql
-- Description: Core operational tables (lcl_service, service_cargo_acceptance, departure,
--              rate, shipment, booking, booking_audit)
-- Enforces: Temporal rate exclusion, partial unique capacity holding, derived capacity.
-- Strict naming convention: <table>_<column>_<suffix> (pk, fk, uk, ck, ex)
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- Table: lcl_service
-- ------------------------------------------------------------------------------
CREATE TABLE lcl_service (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    provider_id BIGINT NOT NULL,
    origin_port_id BIGINT NOT NULL,
    dest_port_id BIGINT NOT NULL,
    transit_days INTEGER NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT lcl_service_id_pk PRIMARY KEY (id),
    CONSTRAINT lcl_service_provider_id_fk FOREIGN KEY (provider_id) REFERENCES provider(id) ON DELETE RESTRICT,
    CONSTRAINT lcl_service_origin_port_id_fk FOREIGN KEY (origin_port_id) REFERENCES port(id) ON DELETE RESTRICT,
    CONSTRAINT lcl_service_dest_port_id_fk FOREIGN KEY (dest_port_id) REFERENCES port(id) ON DELETE RESTRICT,
    CONSTRAINT lcl_service_transit_days_ck CHECK (transit_days > 0),
    CONSTRAINT lcl_service_origin_dest_ck CHECK (origin_port_id <> dest_port_id),
    CONSTRAINT lcl_service_provider_origin_dest_uk UNIQUE (provider_id, origin_port_id, dest_port_id)
);

CREATE INDEX lcl_service_provider_id_idx ON lcl_service(provider_id);
CREATE INDEX lcl_service_origin_port_id_idx ON lcl_service(origin_port_id);
CREATE INDEX lcl_service_dest_port_id_idx ON lcl_service(dest_port_id);

COMMENT ON TABLE lcl_service IS 'Recurring freight service definition offered by a provider between two ports.';
COMMENT ON COLUMN lcl_service.transit_days IS 'Estimated port-to-port voyage duration in calendar days.';

-- ------------------------------------------------------------------------------
-- Table: service_cargo_acceptance (M:N)
-- ------------------------------------------------------------------------------
CREATE TABLE service_cargo_acceptance (
    service_id BIGINT NOT NULL,
    category_id BIGINT NOT NULL,
    CONSTRAINT service_cargo_acceptance_service_category_pk PRIMARY KEY (service_id, category_id),
    CONSTRAINT service_cargo_acceptance_service_id_fk FOREIGN KEY (service_id) REFERENCES lcl_service(id) ON DELETE RESTRICT,
    CONSTRAINT service_cargo_acceptance_category_id_fk FOREIGN KEY (category_id) REFERENCES cargo_category(id) ON DELETE RESTRICT
);

CREATE INDEX service_cargo_acceptance_category_id_idx ON service_cargo_acceptance(category_id);

COMMENT ON TABLE service_cargo_acceptance IS 'Explicit mapping of cargo categories accepted on a recurring service.';

-- ------------------------------------------------------------------------------
-- Table: departure
-- ------------------------------------------------------------------------------
CREATE TABLE departure (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    service_id BIGINT NOT NULL,
    etd TIMESTAMPTZ NOT NULL,
    eta TIMESTAMPTZ NOT NULL,
    cutoff_at TIMESTAMPTZ NOT NULL,
    capacity_cbm NUMERIC(8,3) NOT NULL,
    capacity_weight_kg NUMERIC(10,2) NOT NULL,
    status TEXT NOT NULL DEFAULT 'SCHEDULED',
    CONSTRAINT departure_id_pk PRIMARY KEY (id),
    CONSTRAINT departure_service_id_fk FOREIGN KEY (service_id) REFERENCES lcl_service(id) ON DELETE RESTRICT,
    CONSTRAINT departure_capacity_cbm_ck CHECK (capacity_cbm > 0),
    CONSTRAINT departure_capacity_weight_kg_ck CHECK (capacity_weight_kg > 0),
    CONSTRAINT departure_status_ck CHECK (status IN ('SCHEDULED', 'CLOSED', 'DEPARTED', 'CANCELLED')),
    CONSTRAINT departure_eta_after_etd_ck CHECK (eta > etd),
    CONSTRAINT departure_cutoff_before_etd_ck CHECK (cutoff_at <= etd),
    CONSTRAINT departure_service_etd_uk UNIQUE (service_id, etd)
);

CREATE INDEX departure_service_id_idx ON departure(service_id);

COMMENT ON TABLE departure IS 'A specific dated voyage instance of an LCL service with bounded physical capacity.';
COMMENT ON COLUMN departure.capacity_cbm IS 'Total volume capacity allocated to this voyage in cubic meters (no mutable remaining column).';
COMMENT ON COLUMN departure.capacity_weight_kg IS 'Total payload weight capacity allocated to this voyage in kilograms.';
COMMENT ON COLUMN departure.cutoff_at IS 'Container gate cut-off deadline for cargo reception at the origin terminal.';

-- ------------------------------------------------------------------------------
-- Table: rate
-- ------------------------------------------------------------------------------
CREATE TABLE rate (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    service_id BIGINT NOT NULL,
    rate_per_wm NUMERIC(12,2) NOT NULL,
    currency CHAR(3) NOT NULL,
    validity DATERANGE NOT NULL,
    CONSTRAINT rate_id_pk PRIMARY KEY (id),
    CONSTRAINT rate_service_id_fk FOREIGN KEY (service_id) REFERENCES lcl_service(id) ON DELETE RESTRICT,
    CONSTRAINT rate_rate_per_wm_ck CHECK (rate_per_wm > 0),
    CONSTRAINT rate_validity_ck CHECK (NOT isempty(validity)),
    CONSTRAINT rate_service_validity_ex EXCLUDE USING gist (service_id WITH =, validity WITH &&)
);

CREATE INDEX rate_service_id_idx ON rate(service_id);

COMMENT ON TABLE rate IS 'Temporal freight tariff per revenue tonne (W/M) with non-overlapping validity.';
COMMENT ON COLUMN rate.rate_per_wm IS 'Freight charge per revenue tonne (GREATEST(CBM, weight_kg/1000.0)).';
COMMENT ON COLUMN rate.validity IS 'Temporal date range during which this rate is valid for departure ETD matching.';

-- ------------------------------------------------------------------------------
-- Table: shipment
-- ------------------------------------------------------------------------------
CREATE TABLE shipment (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    trader_id BIGINT NOT NULL,
    origin_port_id BIGINT NOT NULL,
    dest_port_id BIGINT NOT NULL,
    category_id BIGINT NOT NULL,
    cbm NUMERIC(8,3) NOT NULL,
    weight_kg NUMERIC(10,2) NOT NULL,
    cargo_ready_date DATE NOT NULL,
    description TEXT,
    CONSTRAINT shipment_id_pk PRIMARY KEY (id),
    CONSTRAINT shipment_trader_id_fk FOREIGN KEY (trader_id) REFERENCES trader(id) ON DELETE RESTRICT,
    CONSTRAINT shipment_origin_port_id_fk FOREIGN KEY (origin_port_id) REFERENCES port(id) ON DELETE RESTRICT,
    CONSTRAINT shipment_dest_port_id_fk FOREIGN KEY (dest_port_id) REFERENCES port(id) ON DELETE RESTRICT,
    CONSTRAINT shipment_category_id_fk FOREIGN KEY (category_id) REFERENCES cargo_category(id) ON DELETE RESTRICT,
    CONSTRAINT shipment_cbm_ck CHECK (cbm > 0 AND cbm <= 70.000),
    CONSTRAINT shipment_weight_kg_ck CHECK (weight_kg > 0 AND weight_kg <= 30000.00),
    CONSTRAINT shipment_origin_dest_ck CHECK (origin_port_id <> dest_port_id)
);

CREATE INDEX shipment_trader_id_idx ON shipment(trader_id);
CREATE INDEX shipment_origin_port_id_idx ON shipment(origin_port_id);
CREATE INDEX shipment_dest_port_id_idx ON shipment(dest_port_id);
CREATE INDEX shipment_category_id_idx ON shipment(category_id);

COMMENT ON TABLE shipment IS 'Cargo requirement submitted by a trader seeking transportation.';
COMMENT ON COLUMN shipment.cbm IS 'Required volume in cubic meters (bounded to maximum standard container envelope of 70 CBM).';
COMMENT ON COLUMN shipment.weight_kg IS 'Required payload weight in kilograms (bounded to maximum container payload of 30,000 kg).';

-- ------------------------------------------------------------------------------
-- Table: booking
-- ------------------------------------------------------------------------------
CREATE TABLE booking (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    shipment_id BIGINT NOT NULL,
    departure_id BIGINT NOT NULL,
    status TEXT NOT NULL DEFAULT 'PENDING',
    allocated_cbm NUMERIC(8,3) NOT NULL,
    allocated_weight_kg NUMERIC(10,2) NOT NULL,
    chargeable_qty NUMERIC(10,3) NOT NULL,
    quoted_rate NUMERIC(12,2) NOT NULL,
    quoted_currency CHAR(3) NOT NULL,
    quoted_total NUMERIC(14,2) NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT booking_id_pk PRIMARY KEY (id),
    CONSTRAINT booking_shipment_id_fk FOREIGN KEY (shipment_id) REFERENCES shipment(id) ON DELETE RESTRICT,
    CONSTRAINT booking_departure_id_fk FOREIGN KEY (departure_id) REFERENCES departure(id) ON DELETE RESTRICT,
    CONSTRAINT booking_status_ck CHECK (status IN ('PENDING', 'CONFIRMED', 'CANCELLED', 'REJECTED')),
    CONSTRAINT booking_allocated_cbm_ck CHECK (allocated_cbm > 0),
    CONSTRAINT booking_allocated_weight_kg_ck CHECK (allocated_weight_kg > 0),
    CONSTRAINT booking_chargeable_qty_ck CHECK (chargeable_qty > 0),
    CONSTRAINT booking_quoted_rate_ck CHECK (quoted_rate > 0),
    CONSTRAINT booking_quoted_total_ck CHECK (quoted_total > 0)
);

CREATE INDEX booking_shipment_id_idx ON booking(shipment_id);
CREATE INDEX booking_departure_id_idx ON booking(departure_id);

-- Enforce at most one active capacity-holding booking per shipment
CREATE UNIQUE INDEX booking_shipment_capacity_uk ON booking (shipment_id) 
WHERE status IN ('PENDING', 'CONFIRMED');

COMMENT ON TABLE booking IS 'Authoritative allocation of a shipment requirement onto a dated departure.';
COMMENT ON COLUMN booking.allocated_cbm IS 'Snapshot of volume capacity held by this booking.';
COMMENT ON COLUMN booking.quoted_rate IS 'Historical snapshot of rate per revenue tonne at booking creation.';
COMMENT ON COLUMN booking.quoted_total IS 'Historical snapshot of total freight cost (chargeable_qty * quoted_rate).';

-- ------------------------------------------------------------------------------
-- Table: booking_audit
-- ------------------------------------------------------------------------------
CREATE TABLE booking_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    booking_id BIGINT NOT NULL,
    old_status TEXT,
    new_status TEXT NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    changed_by TEXT NOT NULL,
    CONSTRAINT booking_audit_id_pk PRIMARY KEY (id),
    CONSTRAINT booking_audit_booking_id_fk FOREIGN KEY (booking_id) REFERENCES booking(id) ON DELETE RESTRICT,
    CONSTRAINT booking_audit_old_status_ck CHECK (old_status IS NULL OR old_status IN ('PENDING', 'CONFIRMED', 'CANCELLED', 'REJECTED')),
    CONSTRAINT booking_audit_new_status_ck CHECK (new_status IN ('PENDING', 'CONFIRMED', 'CANCELLED', 'REJECTED'))
);

CREATE INDEX booking_audit_booking_id_idx ON booking_audit(booking_id);

COMMENT ON TABLE booking_audit IS 'Audit trail tracking status transitions and actor lifecycle changes on bookings.';

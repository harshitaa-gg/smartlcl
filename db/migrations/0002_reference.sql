-- ==============================================================================
-- Migration: 0002_reference.sql
-- Description: Core reference entities (port, cargo_category, app_user, provider, trader)
-- Strict naming convention: <table>_<column>_<suffix> (pk, fk, uk, ck, ex)
-- ==============================================================================

CREATE EXTENSION IF NOT EXISTS citext;

-- ------------------------------------------------------------------------------
-- Table: port
-- ------------------------------------------------------------------------------
CREATE TABLE port (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    unlocode TEXT NOT NULL,
    name TEXT NOT NULL,
    country_code CHAR(2) NOT NULL,
    data_origin TEXT NOT NULL,
    CONSTRAINT port_id_pk PRIMARY KEY (id),
    CONSTRAINT port_unlocode_uk UNIQUE (unlocode),
    CONSTRAINT port_unlocode_ck CHECK (unlocode ~ '^[A-Z]{2}[A-Z0-9]{3}$'),
    CONSTRAINT port_data_origin_ck CHECK (data_origin IN ('REAL', 'SYNTHETIC'))
);

COMMENT ON TABLE port IS 'Seaports and Inland Container Depots (ICDs) identified by UN/LOCODE standard.';
COMMENT ON COLUMN port.unlocode IS 'Standard 5-character UN/LOCODE identifying country and location.';
COMMENT ON COLUMN port.data_origin IS 'Data provenance indicator distinguishing real geographic reference data from synthetic test fixtures.';

-- ------------------------------------------------------------------------------
-- Table: cargo_category
-- ------------------------------------------------------------------------------
CREATE TABLE cargo_category (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    is_dangerous BOOLEAN NOT NULL DEFAULT FALSE,
    is_perishable BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT cargo_category_id_pk PRIMARY KEY (id),
    CONSTRAINT cargo_category_code_uk UNIQUE (code)
);

COMMENT ON TABLE cargo_category IS 'Standardized cargo classifications for compatibility and acceptance checking.';
COMMENT ON COLUMN cargo_category.code IS 'Machine-readable identifier for category (e.g., GENERAL, HAZMAT, REEFER).';
COMMENT ON COLUMN cargo_category.is_dangerous IS 'Flag indicating hazardous goods requiring special handling or certification.';
COMMENT ON COLUMN cargo_category.is_perishable IS 'Flag indicating temperature-sensitive or perishable goods.';

-- ------------------------------------------------------------------------------
-- Table: app_user
-- ------------------------------------------------------------------------------
CREATE TABLE app_user (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    email CITEXT NOT NULL,
    full_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT app_user_id_pk PRIMARY KEY (id),
    CONSTRAINT app_user_email_uk UNIQUE (email)
);

COMMENT ON TABLE app_user IS 'Authentication and identity principal for system actors.';
COMMENT ON COLUMN app_user.email IS 'Case-insensitive unique email address enforced via citext data type.';

-- ------------------------------------------------------------------------------
-- Table: provider
-- ------------------------------------------------------------------------------
CREATE TABLE provider (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    app_user_id BIGINT NOT NULL,
    company_name TEXT NOT NULL,
    data_origin TEXT NOT NULL,
    CONSTRAINT provider_id_pk PRIMARY KEY (id),
    CONSTRAINT provider_app_user_id_uk UNIQUE (app_user_id),
    CONSTRAINT provider_app_user_id_fk FOREIGN KEY (app_user_id) REFERENCES app_user(id) ON DELETE RESTRICT,
    CONSTRAINT provider_company_name_uk UNIQUE (company_name),
    CONSTRAINT provider_data_origin_ck CHECK (data_origin IN ('REAL', 'SYNTHETIC'))
);

CREATE INDEX provider_app_user_id_idx ON provider(app_user_id);

COMMENT ON TABLE provider IS 'Freight forwarders, consolidators, and logistics service providers publishing capacity.';
COMMENT ON COLUMN provider.app_user_id IS 'One-to-one foreign key linking the provider entity to its authenticating user.';

-- ------------------------------------------------------------------------------
-- Table: trader
-- ------------------------------------------------------------------------------
CREATE TABLE trader (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    app_user_id BIGINT NOT NULL,
    company_name TEXT NOT NULL,
    home_city TEXT NOT NULL,
    data_origin TEXT NOT NULL,
    CONSTRAINT trader_id_pk PRIMARY KEY (id),
    CONSTRAINT trader_app_user_id_uk UNIQUE (app_user_id),
    CONSTRAINT trader_app_user_id_fk FOREIGN KEY (app_user_id) REFERENCES app_user(id) ON DELETE RESTRICT,
    CONSTRAINT trader_data_origin_ck CHECK (data_origin IN ('REAL', 'SYNTHETIC'))
);

CREATE INDEX trader_app_user_id_idx ON trader(app_user_id);

COMMENT ON TABLE trader IS 'Exporters, shippers, and MSME merchants seeking LCL freight allocations.';
COMMENT ON COLUMN trader.app_user_id IS 'One-to-one foreign key linking the trader entity to its authenticating user.';

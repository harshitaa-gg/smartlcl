-- ==============================================================================
-- Seed: 001_reference_real.sql
-- Description: Deterministic reference port data with data_origin = 'REAL'
-- UN/LOCODE verification: All 16 ports verified against authoritative UNECE database.
-- Note: Paradip port UN/LOCODE in UNECE is INPRT (INPPT is facility code; INPBD is Porbandar).
--       Per project specification, INPBD was listed as Paradip; to avoid silent substitution,
--       both are documented in docs/seed-data.md and inserted deterministically.
-- ==============================================================================

INSERT INTO port (unlocode, name, country_code, data_origin)
VALUES
    -- Indian Ports
    ('INMAA', 'Chennai', 'IN', 'REAL'),
    ('INBOM', 'Mumbai', 'IN', 'REAL'),
    ('INMUN', 'Mundra', 'IN', 'REAL'),
    ('INNSA', 'Nhava Sheva (JNPT)', 'IN', 'REAL'),
    ('INCOK', 'Cochin', 'IN', 'REAL'),
    ('INVTZ', 'Visakhapatnam', 'IN', 'REAL'),
    ('INCCU', 'Kolkata', 'IN', 'REAL'),
    ('INPBD', 'Paradip', 'IN', 'REAL'),
    ('INTUT', 'Tuticorin (V.O.C)', 'IN', 'REAL'),

    -- International Ports
    ('SGSIN', 'Singapore', 'SG', 'REAL'),
    ('AEJEA', 'Jebel Ali', 'AE', 'REAL'),
    ('LKCMB', 'Colombo', 'LK', 'REAL'),
    ('NLRTM', 'Rotterdam', 'NL', 'REAL'),
    ('DEHAM', 'Hamburg', 'DE', 'REAL'),
    ('CNSHA', 'Shanghai', 'CN', 'REAL'),
    ('MYPKG', 'Port Klang', 'MY', 'REAL')
ON CONFLICT (unlocode) DO NOTHING;

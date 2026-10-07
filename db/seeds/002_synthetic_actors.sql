-- ==============================================================================
-- Seed: 002_synthetic_actors.sql
-- Description: Deterministic synthetic providers, traders, and app_users.
-- Rules: data_origin = 'SYNTHETIC', example.com emails, no names matching
--        carrier|port|route|user\d+ case-insensitively.
-- ==============================================================================

-- 1. App Users for Providers
INSERT INTO app_user (email, full_name)
VALUES
    ('ops@blueanchor-logistics.example.com', 'Vikramaditya Singhania'),
    ('ocean@orientfreight-consol.example.com', 'Ananya Banerjee'),
    ('bookings@maritime-crossings.example.com', 'Karthik Ramanathan'),
    ('lcl@pacific-bay-shipping.example.com', 'Farhan Qureshi'),
    ('trade@zenith-cargo-network.example.com', 'Meera Venkatesh')
ON CONFLICT (email) DO NOTHING;

-- 2. Synthetic Providers (linked via app_user email)
INSERT INTO provider (app_user_id, company_name, data_origin)
SELECT u.id, p.company_name, 'SYNTHETIC'
FROM (
    VALUES
        ('ops@blueanchor-logistics.example.com', 'BlueAnchor Logistics Lines'),
        ('ocean@orientfreight-consol.example.com', 'OrientFreight Consolidators'),
        ('bookings@maritime-crossings.example.com', 'Maritime Crossings Freight'),
        ('lcl@pacific-bay-shipping.example.com', 'Pacific Bay Shipping Solutions'),
        ('trade@zenith-cargo-network.example.com', 'Zenith Cargo Network')
) AS p(email, company_name)
JOIN app_user u ON u.email = p.email
ON CONFLICT (company_name) DO NOTHING;

-- 3. App Users for Traders (10 SME merchants)
INSERT INTO app_user (email, full_name)
VALUES
    ('contact@tirupur-fineknits.example.com', 'Senthil Murugan'),
    ('sales@kovai-agropumps.example.com', 'Rajeswari Natarajan'),
    ('exports@malabar-spicecraft.example.com', 'Babu Thomas'),
    ('admin@madras-precisiongears.example.com', 'Sundaram Krishnamurthy'),
    ('info@chola-bronze-handicrafts.example.com', 'Devi Kamakshi'),
    ('trade@surat-textile-weavers.example.com', 'Harishbhai Patel'),
    ('orders@bengal-fineceramics.example.com', 'Subhashish Roy'),
    ('sales@punjab-valve-industries.example.com', 'Gurpreet Singh'),
    ('export@mysore-sandal-essentials.example.com', 'Manjunath Hegde'),
    ('dispatch@andhra-aquafeed-chem.example.com', 'Venkata Satyanarayana')
ON CONFLICT (email) DO NOTHING;

-- 4. Synthetic Traders (linked via app_user email)
INSERT INTO trader (app_user_id, company_name, home_city, data_origin)
SELECT u.id, t.company_name, t.home_city, 'SYNTHETIC'
FROM (
    VALUES
        ('contact@tirupur-fineknits.example.com', 'Tirupur FineKnits Apparel', 'Tirupur'),
        ('sales@kovai-agropumps.example.com', 'Kovai AgroPump Technologies', 'Coimbatore'),
        ('exports@malabar-spicecraft.example.com', 'Malabar SpiceCraft Traders', 'Kochi'),
        ('admin@madras-precisiongears.example.com', 'Madras Precision AutoGears', 'Chennai'),
        ('info@chola-bronze-handicrafts.example.com', 'Chola Bronze & Stone Handicrafts', 'Thanjavur'),
        ('trade@surat-textile-weavers.example.com', 'Surat Elite Textile Weavers', 'Surat'),
        ('orders@bengal-fineceramics.example.com', 'Bengal Fine Ceramics Works', 'Kolkata'),
        ('sales@punjab-valve-industries.example.com', 'Punjab Heavy Valve Industries', 'Jalandhar'),
        ('export@mysore-sandal-essentials.example.com', 'Mysore Sandalwood & Herbal Essentials', 'Mysuru'),
        ('dispatch@andhra-aquafeed-chem.example.com', 'Andhra AquaFeed Formulations', 'Vijayawada')
) AS t(email, company_name, home_city)
JOIN app_user u ON u.email = t.email
ON CONFLICT (app_user_id) DO NOTHING;

# SmartLCL - Seed Data Specification & Reference Notes

This document describes the provenance, structure, and design rationale for the seed fixtures created in **Sprint 2** (`db/seeds/`).

---

## 1. REAL Reference Data vs. SYNTHETIC Data

The project strictly distinguishes between authoritative real geographic reference entities and synthetic demonstration fixtures using the column `data_origin CHECK (data_origin IN ('REAL', 'SYNTHETIC'))`.

| Entity Type | Source / Table | Provenance (`data_origin`) | Rationale |
|:---|:---|:---|:---|
| **Ports** | `port` | **`REAL`** | Real seaports identified by the official UNECE UN/LOCODE standard. |
| **App Users** | `app_user` | (Implicit in actor) | Fictional contact actors using `@*.example.com` domains. |
| **LCL Providers** | `provider` | **`SYNTHETIC`** | Fictional non-vessel operating common carriers (NVOCCs) / consolidators. |
| **SME Traders** | `trader` | **`SYNTHETIC`** | Believable fictional small-and-medium enterprise exporters. |
| **Cargo Categories** | `cargo_category` | **`SYNTHETIC`** | Standardized domain classification categories for freight acceptance. |
| **Services** | `lcl_service` | **`SYNTHETIC`** | Believable trade lanes connecting Indian export hubs with international transshipment ports. |
| **Cargo Acceptance** | `service_cargo_acceptance` | **`SYNTHETIC`** | Explicit policy matrix governing accepted/refused cargo classes per service. |
| **Departures** | `departure` | **`SYNTHETIC`** | Dated voyage instances with fixed CBM and payload weight capacities. |
| **Rates** | `rate` | **`SYNTHETIC`** | Illustrative synthetic freight tariffs per revenue tonne (W/M) with temporal date ranges. |
| **Shipments** | `shipment` | **`SYNTHETIC`** | Demand requirements submitted by fictional SME traders. |
| **Bookings** | `booking` | *(None Seeded)* | **Zero bookings are seeded.** All allocations must pass transaction-safely through `create_booking` in Sprint 4. |

---

## 2. Fixed Anchor Date: `2026-10-12`

All dates in seed files and operational demos are anchored to **`2026-10-12`** ("today").
* **No `now()` or `clock_timestamp()`** is used for business timestamps.
* Weekly departure schedules start on **`2026-10-14`**.
* Cargo-ready dates are anchored between `2026-10-13` and `2026-10-22`.
* Cut-off deadlines are fixed between 3 and 5 days prior to voyage ETD.

---

## 3. Authoritative UN/LOCODE Verification & Findings

Every port UN/LOCODE was checked against the official **United Nations Economic Commission for Europe (UNECE)** UN/LOCODE standard.

### Indian Ports (9 ports)
1. **Chennai** — `INMAA` (Verified: UNECE India, Madras/Chennai)
2. **Mumbai** — `INBOM` (Verified: UNECE India, Bombay/Mumbai)
3. **Mundra** — `INMUN` (Verified: UNECE India, Mundra Port)
4. **Nhava Sheva (JNPT)** — `INNSA` (Verified: UNECE India, Nhava Sheva)
5. **Cochin** — `INCOK` (Verified: UNECE India, Cochin/Kochi)
6. **Visakhapatnam** — `INVTZ` (Verified: UNECE India, Visakhapatnam)
7. **Kolkata** — `INCCU` (Verified: UNECE India, Calcutta/Kolkata)
8. **Paradip** — `INPBD` *(See verification finding below)*
9. **Tuticorin** — `INTUT` (Verified: UNECE India, Tuticorin / V.O. Chidambaranar)

### International Ports (7 ports)
10. **Singapore** — `SGSIN` (Verified: UNECE Singapore)
11. **Jebel Ali** — `AEJEA` (Verified: UNECE United Arab Emirates, Jebel Ali Dubai)
12. **Colombo** — `LKCMB` (Verified: UNECE Sri Lanka, Colombo)
13. **Rotterdam** — `NLRTM` (Verified: UNECE Netherlands, Rotterdam)
14. **Hamburg** — `DEHAM` (Verified: UNECE Germany, Hamburg)
15. **Shanghai** — `CNSHA` (Verified: UNECE China, Shanghai; also `CNSHG` for deep sea terminal)
16. **Port Klang** — `MYPKG` (Verified: UNECE Malaysia, Port Kelang)

### ⚠️ UN/LOCODE Verification Finding: Paradip vs. `INPBD`
* **Official UNECE Finding**: In the authoritative UNECE UN/LOCODE database, the port of Paradip is officially coded as **`INPRT`** (location Paradip Garh; port terminal code `INPPT`). The code **`INPBD`** officially designates **Porbandar** (Gujarat).
* **Project Handling**: In strict accordance with the project rule (*"Do not invent or silently correct a code. Tell me which codes could not be verified against the authoritative UN/LOCODE source."*), the prompt-specified code `INPBD` has been retained in `001_reference_real.sql` and explicitly documented here to prevent silent discrepancy.

---

## 4. Documented Edge Cases

The operational seed data incorporates 5 specific edge cases required for later sprint demos:

1. **Exact 10 CBM and 10,000 kg Capacity**:
   * *Departure*: Service 1 (BlueAnchor MAA → SGSIN), ETD `2026-10-14 10:00:00+00`.
   * *Purpose*: Designed specifically for the Sprint 5 concurrency stress test where two concurrent booking transactions attempt to claim capacity simultaneously on a tight vessel boundary.
2. **Cut-off Passed Relative to Anchor Date**:
   * *Departure*: Service 1 (BlueAnchor MAA → SGSIN), Cut-off `2026-10-10 18:00:00+00` (anchor is `2026-10-12`).
   * *Purpose*: Demonstrates that the booking allocation engine rejects booking attempts where cargo reception has closed.
3. **`CANCELLED` Departure Status**:
   * *Departure*: Service 6 (OrientFreight COK → AEJEA), ETD `2026-10-21 16:00:00+00`.
   * *Purpose*: Demonstrates that search queries and booking procedures strictly filter out non-`SCHEDULED` departures.
4. **Refused Cargo Category**:
   * *Shipment*: Shipment 19 (`HAZARDOUS_DG` from Chennai to Singapore).
   * *Service*: BlueAnchor MAA → SGSIN (Service 1) explicitly omits `HAZARDOUS_DG` from `service_cargo_acceptance`.
   * *Purpose*: Proves that the search and allocation engine prevents booking cargo categories that a carrier refuses to accept.
5. **Weight as Binding Capacity Limit (W/M Rule)**:
   * *Shipment*: Shipment 20 (`Madras Precision AutoGears`, high-density alloy forging blocks, 3.5 CBM, 14,000.00 kg).
   * *Pricing*: Chargeable quantity = $\max(3.5, 14000 / 1000) = 14.0\text{ W/M}$.
   * *Purpose*: Demonstrates that freight billing and vessel capacity depletion are properly bounded by mass rather than volume for heavy industrial cargo.

---

## 5. Explicit Statements & Disclaimers

1. **Fictional Actors**: All provider company names (e.g., *BlueAnchor Logistics Lines*, *OrientFreight Consolidators*), SME trader company names (e.g., *Tirupur FineKnits Apparel*, *Kovai AgroPump Technologies*), contact persons, and `@*.example.com` email addresses are completely **synthetic and fictional**. None correspond to actual operating companies.
2. **Illustrative Synthetic Rates**: All ocean freight rates (e.g., \$45.00 – \$110.00 / W/M) are purely **illustrative synthetic values** created for database logic and constraint demonstration.
3. **No Real Prices or Schedules Claimed**: **No claim is made that any prices, sailing schedules, transit durations, or capacity numbers represent real-world commercial market rates or actual carrier operations.**

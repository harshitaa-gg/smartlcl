# SmartLCL Schema Design Notes

This document connects the binding architectural decisions in `AGENTS.md` to their physical implementation in PostgreSQL 18.

---

### Binding Design Decisions & Physical Implementation

| # | Binding Decision | Engineering Rationale | Implementing Table, Constraint, or Mechanism |
|---|---|---|---|
| **1** | **Capacity belongs to dated departure, not recurring service** | Recurring service defines the route schedule template; physical containers, cut-offs, and payload limits are committed to specific dated voyages. | `departure` table (`capacity_cbm`, `capacity_weight_kg`, `cutoff_at`, `etd`, `eta`). `lcl_service` maintains only route definition. |
| **2** | **No stored mutable `remaining_cbm` / derived capacity** | Stored mutable counters cause race conditions, lost updates, and drift under concurrency. Single source of truth derived dynamically. | Derived calculation: `departure.capacity_cbm - SUM(booking.allocated_cbm) WHERE is_capacity_holding(status)`. Zero remaining columns in `departure`. |
| **3** | **`shipment` and `booking` are separate tables** | A trader requirement exists independently of vessel allocations. Shippers may query, cancel, or re-attempt bookings without destroying cargo specs. | `shipment` (demand: CBM, weight, ready date) vs. `booking` (allocation: link between `shipment_id` and `departure_id`). |
| **4** | **Cargo restrictions via relational categories (M:N)** | Free-text restrictions prevent indexable queries and allow human error. Normalized categories permit deterministic filtering. | `cargo_category` table and `service_cargo_acceptance` bridge table (`service_id`, `category_id`). |
| **5** | **Temporal rates with exclusion constraints** | Freight tariffs vary seasonally. Tariff overlaps on a single service lead to ambiguous pricing disputes. | `rate` table with `validity daterange NOT EMPTY` and `CONSTRAINT rate_service_validity_ex EXCLUDE USING gist (service_id WITH =, validity WITH &&)`. |
| **6** | **Historical quoted price snapshot on `booking`** | Future tariff revisions must not retroactively alter the agreed financial settlement of past bookings (justified denormalization). | `booking` columns (`allocated_cbm`, `allocated_weight_kg`, `chargeable_qty`, `quoted_rate`, `quoted_currency`, `quoted_total`). |
| **7** | **Authoritative chargeable quantity (W/M rule)** | Maritime shipping charges by Revenue Tonne (greater of volume vs weight/1000). Must be computed identically across system. | Implemented via SQL expression / function `GREATEST(cbm, weight_kg / 1000.0)`. Enforced on `booking.chargeable_qty`. |
| **8** | **Capacity-holding statuses & single active booking** | Shippers must not double-book a cargo requirement across multiple voyages. Only `PENDING` and `CONFIRMED` statuses consume capacity. | Partial unique index: `CREATE UNIQUE INDEX booking_shipment_capacity_uk ON booking (shipment_id) WHERE status IN ('PENDING', 'CONFIRMED');`. |
| **9** | **Authoritative DB allocation & audit triggers** | Concurrency safety requires pessimistic row locks (`SELECT ... FOR UPDATE`) in PostgreSQL. Triggers handle audit trails, not capacity logic. | `booking_audit` table tracking `old_status`, `new_status`, and `changed_by`. Allocation logic targeted for DB function in Sprint 4. |

---

### Key Relational Integrity Guarantees
* **Case-Insensitive Uniqueness:** `app_user.email` uses the `citext` extension, preventing duplicate accounts differing only in casing.
* **UN/LOCODE Standard Validation:** `port.unlocode` constrained by regex `^[A-Z]{2}[A-Z0-9]{3}$`.
* **Chronological Integrity:** `departure.eta > departure.etd` and `departure.cutoff_at <= departure.etd` enforced by check constraints.
* **Geographical Non-Triviality:** `lcl_service` and `shipment` enforce `origin_port_id <> dest_port_id`.
* **Foreign Key Protection:** All foreign keys specify `ON DELETE RESTRICT` with explicit supporting B-Tree indexes.

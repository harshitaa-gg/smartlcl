# ADR 0001: Binding Architectural Decisions for PostgreSQL-Centred SmartLCL

* **Status:** Accepted
* **Date:** 2026-10-06
* **Scope:** BCSE302P Database Systems Lab (Track T11: Mobility & Urban Living)

---

## Context
SmartLCL is an LCL freight capacity discovery and booking platform evaluated as a core Database Systems project. It addresses the real-world operational problem of container dead-freight and capacity discovery friction for small exporters (MSMEs).

---

## Decision Log

1. **Departure-Level Capacity Ownership:**
   Capacity belongs strictly to a dated departure (`departure`), never to the recurring service definition (`lcl_service`).
2. **Derived Remaining Capacity:**
   There is no stored mutable `remaining_cbm` or `remaining_weight_kg`. Remaining capacity is dynamically derived by subtracting active, capacity-holding bookings from the departure's total capacity:
   $$\text{Remaining CBM} = \text{departure.total\_cbm} - \sum_{\text{status } \in \text{ACTIVE}} \text{booking.cbm}$$
3. **Decoupled Demand and Allocation:**
   `shipment` (the trader's cargo requirement) and `booking` (the physical allocation to a dated departure) are distinct, separate entities.
4. **Structured Cargo Category Acceptance:**
   Cargo restrictions are modeled relationally using `cargo_category` and a many-to-many `service_cargo_acceptance` table. Free-text restrictions are prohibited.
5. **Temporal Rates with Exclusion Constraints:**
   Rates possess validity periods (`tstzrange`). Overlapping validity intervals for the same service are prevented at the database level using `EXCLUDE USING gist` constraints (`btree_gist` extension).
6. **Historical Price Snapshotting on Booking:**
   A booking stores its quoted price at confirmation time as a historical snapshot (justified and documented denormalization).
7. **Authoritative Revenue Tonne (W/M):**
   Chargeable quantity is computed consistently using the rule:
   $$\text{Chargeable Quantity} = \max\left(\text{cbm},\, \frac{\text{weight\_kg}}{1000.0}\right)$$
   enforced via a shared database function.
8. **Authoritative DB-Level Booking Allocation:**
   Allocation logic resides exclusively in a PostgreSQL stored function that locks the departure row (`SELECT ... FOR UPDATE`), recalculates allocated capacity, validates constraints, and commits or rolls back atomically.
9. **Triggers Only for Auditing & State Guards:**
   Triggers are reserved for audit trails (`booking_audit`) and state transition validations. They are never used as the primary capacity allocation mechanism.
10. **Disciplined Relational Surface:**
    Candidate tables: `port`, `provider`, `app_user`, `trader`, `cargo_category`, `lcl_service`, `service_cargo_acceptance`, `departure`, `rate`, `shipment`, `booking`, `booking_audit`. Excluded from scope: payments, invoices, live tracking, and physical container fleet management.

---

## Consequences
All business invariants, concurrency protections, and pricing calculations are enforced inside PostgreSQL 18, ensuring full relational integrity independent of application clients.

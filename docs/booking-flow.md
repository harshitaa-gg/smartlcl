# SmartLCL - Transaction-Safe Booking Workflow & Concurrency Architecture

This document describes the internal execution flow of the `create_booking()` PostgreSQL database function, the serialization mechanism, and the rationale behind pessimistic row locking.

---

## 1. Flowchart of `create_booking()`

```mermaid
flowchart TD
    Start(["Start create_booking(p_shipment_id, p_departure_id, p_as_of)"])
    --> Lock["Step A: Lock departure row<br/>SELECT * FROM departure WHERE id = p_dep FOR UPDATE"]

    Lock --> CheckDepExists{"Departure exists?"}
    CheckDepExists -- No --> ErrSL009_Dep["RAISE EXCEPTION (SL009)<br/>Departure does not exist"]
    CheckDepExists -- Yes --> LoadShip["Step B: Load shipment & service"]

    LoadShip --> CheckShipExists{"Shipment & service exist?"}
    CheckShipExists -- No --> ErrSL009_Ship["RAISE EXCEPTION (SL009)<br/>Shipment or service not found"]
    CheckShipExists -- Yes --> CheckStatus{"Departure status == 'SCHEDULED'?"}

    CheckStatus -- No --> ErrSL001["RAISE EXCEPTION (SL001)<br/>Departure not SCHEDULED"]
    CheckStatus -- Yes --> CheckCutoff{"p_as_of &lt; departure.cutoff_at?"}

    CheckCutoff -- No --> ErrSL002["RAISE EXCEPTION (SL002)<br/>Booking cutoff has passed"]
    CheckCutoff -- Yes --> CheckLane{"Shipment lane == Service lane?"}

    CheckLane -- No --> ErrSL003["RAISE EXCEPTION (SL003)<br/>Lane mismatch"]
    CheckLane -- Yes --> CheckCategory{"Service accepts cargo category?"}

    CheckCategory -- No --> ErrSL004["RAISE EXCEPTION (SL004)<br/>Cargo category refused"]
    CheckCategory -- Yes --> CheckHolding{"Shipment already allocated?<br/>is_capacity_holding(status)"}

    CheckHolding -- Yes --> ErrSL005["RAISE EXCEPTION (SL005)<br/>Shipment already allocated"]
    CheckHolding -- No --> Recompute["Step D: Recompute allocation under lock<br/>SUM(allocated) FILTER WHERE is_capacity_holding()"]

    Recompute --> CheckCBM{"remaining_cbm &gt;= shipment.cbm?"}
    CheckCBM -- No --> ErrSL006["RAISE EXCEPTION (SL006)<br/>Insufficient CBM capacity"]
    CheckCBM -- Yes --> CheckWeight{"remaining_weight_kg &gt;= shipment.weight_kg?"}

    CheckWeight -- No --> ErrSL007["RAISE EXCEPTION (SL007)<br/>Insufficient weight capacity"]
    CheckWeight -- Yes --> LookupRate["Step E: Lookup applicable rate<br/>get_applicable_rate(service, departure.etd::date)"]

    LookupRate --> CheckRate{"Rate found?"}
    CheckRate -- No --> ErrSL008["RAISE EXCEPTION (SL008)<br/>No applicable rate on ETD"]
    CheckRate -- Yes --> CalcPrice["Step F: Calculate pricing snapshot<br/>chargeable_qty = GREATEST(cbm, wt/1000)<br/>total = ROUND(qty * rate, 2)"]

    CalcPrice --> InsertSnap["Step G: Insert booking snapshot (PENDING)<br/>Insert booking_audit trail record"]
    InsertSnap --> Done(["Return booking_id"])
```

---

## 2. Core Concurrency Rationale (The Viva Defense)

### Question:
> **Why do we lock the departure row before recalculating capacity?**

### Authoritative Answer:
Because in a high-volume freight booking system, multiple concurrent client transactions can issue booking requests simultaneously for the same voyage.

1. **The Concurrency Hazard**: If transactions relied on cached or unlocked queries (such as reading `v_departure_availability`), both transactions would simultaneously see the same unallocated physical capacity (e.g. 15 CBM available). Transaction A would create a 10 CBM booking, and Transaction B would concurrently create an 8 CBM booking. Both would commit, resulting in **18 CBM allocated on a 15 CBM vessel (an illegal physical oversell)**.
2. **The Serialization Anchor**: By executing:
   ```sql
   SELECT * FROM departure WHERE id = p_departure_id FOR UPDATE;
   ```
   as the **very first operation**, PostgreSQL acquires an exclusive row-level write lock on the target departure.
3. **Queueing & Fresh State**: If Transaction B arrives while Transaction A is executing, Transaction B's thread **blocks and sleeps on the lock**. As soon as Transaction A commits, Transaction B wakes up, obtains the lock, and **dynamically recomputes the allocated capacity from the `booking` table**. Transaction B immediately sees Transaction A's newly committed 10 CBM allocation, detects that only 5 CBM remains, and cleanly aborts with `SL006 (Insufficient CBM capacity)`.
4. **No Mutable State Stored**: No mutable columns like `remaining_cbm` or `remaining_weight_kg` exist on the `departure` row. The departure row serves purely as the serialization mutex, while capacity is derived on-demand from the historical ledger of capacity-holding bookings.

# SmartLCL - Database Error Codes Specification

This document defines the authoritative, standardized custom error codes (`SL001` through `SL009`) raised by the PostgreSQL database functions during booking allocation and operational validation.

---

## Error Code Reference Table

| Code | Condition | Meaning & Remediation |
|:---|:---|:---|
| **`SL001`** | Departure is not `SCHEDULED` | The target voyage instance is `CLOSED`, `CANCELLED`, or `DEPARTED`. Bookings can only be attached to actively scheduled departures. |
| **`SL002`** | Booking time is after departure cut-off | The booking request timestamp (`p_as_of`) is at or past the departure terminal cargo cut-off (`cutoff_at`). The cargo gate is closed. |
| **`SL003`** | Shipment lane does not match service lane | The shipment's origin/destination port pair does not match the service corridor offered by the provider. |
| **`SL004`** | Service does not accept shipment cargo category | The service's cargo policy matrix (`service_cargo_acceptance`) does not accept the requested commodity category (e.g. hazardous DG, temperature-controlled reefer). |
| **`SL005`** | Shipment already has a capacity-holding booking | The shipment already has an active `PENDING` or `CONFIRMED` booking. Shipments cannot be split or double-booked across departures. |
| **`SL006`** | Insufficient CBM capacity | The physical cubic volume requested by the shipment exceeds the remaining unallocated volume on the locked departure (`remaining_cbm < shipment.cbm`). |
| **`SL007`** | Insufficient weight capacity | The payload mass requested by the shipment exceeds the remaining payload weight capacity on the locked departure (`remaining_weight_kg < shipment.weight_kg`). |
| **`SL008`** | No applicable rate for departure ETD | No valid freight tariff covers the departure ETD date in the temporal `rate` table for this service. |
| **`SL009`** | Required record does not exist | The specified `shipment_id`, `departure_id`, `service_id`, or `booking_id` was not found in the database. |

---

## Implementation Details

All errors are raised explicitly within PL/pgSQL using PostgreSQL's custom exception handler syntax:

```sql
RAISE EXCEPTION 'Human-readable message explaining the specific failure context'
    USING ERRCODE = 'SLxxx';
```

When client applications or test runners catch database exceptions, they can reliably match on `exc.value.sqlstate == 'SLxxx'` to determine the exact validation failure reason without parsing free-text error strings.

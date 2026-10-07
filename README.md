# SmartLCL: Database Systems Platform

A PostgreSQL-centred Less-than-Container-Load (LCL) freight capacity discovery and booking platform built for the university Database Systems Lab (BCSE302P, Track T11: Mobility & Urban Living).

SmartLCL addresses the real-world problem of unutilized container dead-freight and opaque capacity discovery for small exporters/MSMEs through multi-constraint parametric relational queries, strict ACID concurrency controls, and dynamic capacity derivations in PostgreSQL 18.

---

## Architecture & Guiding Principles

* **Database-First Design:** Authoritative capacity computation, allocation locking, rate temporal validity, and status audit transitions are enforced in PostgreSQL. No capacity or pricing logic resides in ephemeral application memory.
* **Derived Capacity:** Remaining container capacity is dynamically derived (`departure_capacity - SUM(allocated_bookings)`). No mutable remaining capacity columns.
* **ACID Integrity:** Row-level locks (`SELECT ... FOR UPDATE`) ensure zero overbooking during concurrent spot bookings.
* **Deterministic Migrations & Seeds:** Forward-only SQL migrations tracked with SHA-256 checksums in `schema_migrations`.
* **Zero UI Overhead in Phase 0:** Pure database engineering, migration tooling, and automated test harness.

---

## Directory Layout

```
smartlcl/
├── .github/workflows/    # CI automation workflows
├── db/
│   ├── migrations/       # Numbered, forward-only SQL migrations
│   ├── seeds/            # Deterministic seed data (fixed anchor dates)
│   ├── queries/          # Complex analytical & operational SQL queries
│   └── demo/             # Interactive viva and evaluation demonstration scripts
├── docs/
│   ├── adr/              # Architecture Decision Records (ADRs)
│   ├── diagrams/         # Relational schemas and EER diagrams
│   └── evidence/         # Query profiling logs, EXPLAIN ANALYZE, benchmark reports
├── scripts/
│   ├── migrate.sh        # Idempotent transactional SQL migration runner
│   └── reset_db.sh       # Database rebuild and seed utility
├── tests/
│   ├── conftest.py       # psycopg 3 fixtures and environment configuration
│   ├── requirements.txt  # Python test tooling dependencies
│   └── test_smoke.py     # Initial connectivity and schema verification test
├── docker-compose.yml    # PostgreSQL 18 service with health check
├── Makefile              # Reproducible developer command targets
├── prd.md                # Master prompt specification and binding decisions
├── .env.example          # Template environment configuration
└── README.md
```

---

## Quick Start

### 1. Prerequisites
* [Docker](https://docs.docker.com/get-docker/) & Docker Compose
* Python 3.10+ (for `pytest` test harness)
* `make` and `bash`

### 2. Environment Setup
Clone the repository and copy the example environment file:
```bash
cp .env.example .env
```

Create and activate a Python virtual environment:
```bash
python -m venv .venv
source .venv/bin/activate   # On Windows: .venv\Scripts\activate
pip install -r tests/requirements.txt
```

### 3. Start Database Service
Start the PostgreSQL 18 Alpine container:
```bash
make up
```

### 4. Initialize Database & Run Migrations
Rebuild the database and run all migrations:
```bash
make reset
```

### 5. Run Test Suite
Run the automated pytest test suite:
```bash
make test
```

### 6. Interactive Database Session
Open an interactive `psql` session inside the running container:
```bash
make psql
```

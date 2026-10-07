# ==============================================================================
# SmartLCL - Makefile
# Reproducible developer workflow for PostgreSQL 18 DBMS platform
# Windows PowerShell & Linux compatible (recipes only call docker compose or python)
# ==============================================================================

-include .env
export

.PHONY: up down reset migrate seed test psql lint help

help:
	@echo SmartLCL Database Engineering Targets:
	@echo   make up       - Start PostgreSQL 18 container via docker compose
	@echo   make down     - Stop PostgreSQL 18 container
	@echo   make migrate  - Run pending SQL migrations (Python runner)
	@echo   make seed     - Apply seed scripts
	@echo   make reset    - Drop, recreate database and apply migrations
	@echo   make test     - Run pytest test suite
	@echo   make psql     - Open interactive psql session in PostgreSQL container
	@echo   make lint     - Placeholder linter target

up:
	docker compose up -d

down:
	docker compose down

migrate:
	python scripts/migrate.py

seed:
	python scripts/reset_db.py --seed

reset:
	python scripts/reset_db.py

test:
	python -m pytest tests/ -v

psql:
	docker compose exec postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

lint:
	python -c "print('Linting check passed (placeholder).')"

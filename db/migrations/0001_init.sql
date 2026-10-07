-- Migration: 0001_init.sql
-- Description: Enable foundational PostgreSQL extensions required for temporal exclusion constraints
-- Reference: ADR 0001 - Binding Architectural Decision 5

CREATE EXTENSION IF NOT EXISTS btree_gist;

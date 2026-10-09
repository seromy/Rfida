"""Tiny forward-only schema upgrader.

`db.create_all()` creates missing *tables* but never adds columns to tables that
already exist, so an office that already runs a database from an earlier version
would crash on the first query. This adds the missing columns (and cleans legacy
data) in place without needing a migration framework for a single-file SQLite DB.
"""

from sqlalchemy import inspect, text

from .extensions import db

# (table, column, DDL type + default). New NOT NULL columns need a default.
_NEW_COLUMNS = [
    ("equipment", "location", "VARCHAR(100) NOT NULL DEFAULT ''"),
    ("equipment", "note", "TEXT NOT NULL DEFAULT ''"),
    ("equipment", "condition", "VARCHAR(20) NOT NULL DEFAULT 'good'"),
    ("equipment", "created_at", "DATETIME"),
    ("equipment", "updated_at", "DATETIME"),
    ("company", "contact_name", "VARCHAR(100) NOT NULL DEFAULT ''"),
    ("company", "phone", "VARCHAR(50) NOT NULL DEFAULT ''"),
    ("company", "email", "VARCHAR(120) NOT NULL DEFAULT ''"),
    ("company", "note", "TEXT NOT NULL DEFAULT ''"),
    ("company", "created_at", "DATETIME"),
    ("jobs", "created_at", "DATETIME"),
]

_INDEXES = [
    ("ix_equipment_status", "equipment", "status"),
    ("ix_jobs_status", "jobs", "status"),
    ("ix_movements_job_id", "movements", "job_id"),
    ("ix_movements_created_at", "movements", "created_at"),
]


def upgrade_schema():
    engine = db.engine
    inspector = inspect(engine)
    existing_tables = set(inspector.get_table_names())

    with engine.begin() as conn:
        for table, column, ddl in _NEW_COLUMNS:
            if table not in existing_tables:
                continue
            have = {c["name"] for c in inspect(conn).get_columns(table)}
            if column not in have:
                conn.execute(text(f'ALTER TABLE "{table}" ADD COLUMN "{column}" {ddl}'))

        for name, table, column in _INDEXES:
            if table in existing_tables:
                conn.execute(
                    text(f'CREATE INDEX IF NOT EXISTS "{name}" ON "{table}" ("{column}")')
                )

        _backfill(conn, existing_tables)


def _backfill(conn, existing_tables):
    if "equipment" in existing_tables:
        conn.execute(
            text(
                "UPDATE equipment SET created_at = COALESCE(last_seen_at, CURRENT_TIMESTAMP) "
                "WHERE created_at IS NULL"
            )
        )
        conn.execute(
            text("UPDATE equipment SET updated_at = created_at WHERE updated_at IS NULL")
        )
        # EPCs are case-insensitive hex. Older builds stored whatever was typed, so
        # upper-case them (skipping any row where that would collide with another).
        conn.execute(
            text(
                "UPDATE equipment SET epc = UPPER(TRIM(epc)) "
                "WHERE epc != UPPER(TRIM(epc)) "
                "AND NOT EXISTS (SELECT 1 FROM equipment e2 "
                "WHERE e2.epc = UPPER(TRIM(equipment.epc)) AND e2.id != equipment.id)"
            )
        )
    # An older release let a company be deleted while documents still pointed at it.
    for table, column, parent in (
        ("movements", "company_id", "company"),
        ("movements", "job_id", "jobs"),
        ("inventory_sessions", "company_id", "company"),
    ):
        if table in existing_tables and parent in existing_tables:
            conn.execute(
                text(
                    f"UPDATE {table} SET {column} = NULL WHERE {column} IS NOT NULL "
                    f"AND {column} NOT IN (SELECT id FROM {parent})"
                )
            )
    for table in ("company", "jobs"):
        if table in existing_tables:
            conn.execute(
                text(f"UPDATE {table} SET created_at = CURRENT_TIMESTAMP WHERE created_at IS NULL")
            )

"""Upgrading a database created by an earlier release."""

import sqlite3

import pytest

from rfida_server import create_app
from rfida_server.models import Equipment

LEGACY = """
CREATE TABLE equipment (id INTEGER PRIMARY KEY, epc VARCHAR(64) NOT NULL UNIQUE, name VARCHAR(200) NOT NULL,
  category VARCHAR(100) NOT NULL, serial_number VARCHAR(100) NOT NULL, status VARCHAR(20) NOT NULL, last_seen_at DATETIME);
CREATE TABLE company (id INTEGER PRIMARY KEY, name VARCHAR(200) NOT NULL);
CREATE TABLE jobs (id INTEGER PRIMARY KEY, name VARCHAR(200) NOT NULL, date DATETIME NOT NULL, status VARCHAR(20) NOT NULL);
CREATE TABLE movements (id INTEGER PRIMARY KEY, job_id INTEGER, company_id INTEGER, direction VARCHAR(10) NOT NULL,
  epcs JSON NOT NULL, missing_epcs JSON, note TEXT, created_at DATETIME NOT NULL);
CREATE TABLE inventory_sessions (id INTEGER PRIMARY KEY, company_id INTEGER, batch_label VARCHAR(100) NOT NULL,
  scanned_epcs JSON NOT NULL, unknown_epcs JSON NOT NULL, timestamp DATETIME NOT NULL, created_at DATETIME NOT NULL);
INSERT INTO equipment VALUES (1, 'e2801160600002042bb8a1c1', 'Old lens', '鏡頭', 'S1', 'in_stock', '2026-09-10 09:00:00');
INSERT INTO equipment VALUES (2, 'AB12', 'Body', '機身', '', 'checked_out', NULL);
INSERT INTO company VALUES (1, 'Kept Co');
INSERT INTO jobs VALUES (1, 'Old job', '2026-09-05 00:00:00', 'closed');
INSERT INTO movements VALUES (1, 1, 99, 'out', '["AB12"]', NULL, NULL, '2026-09-05 08:00:00');
INSERT INTO movements VALUES (2, 77, 1, 'in', '[]', '["AB12"]', 'lost', '2026-09-06 08:00:00');
INSERT INTO inventory_sessions VALUES (1, 99, 'A', '[]', '[]', '2026-09-07 08:00:00', '2026-09-07 08:00:00');
"""


@pytest.fixture()
def legacy_app(tmp_path):
    path = tmp_path / "old.sqlite"
    con = sqlite3.connect(path)
    con.executescript(LEGACY)
    con.commit()
    con.close()
    app = create_app({"TESTING": True, "SQLALCHEMY_DATABASE_URI": f"sqlite:///{path}", "CSRF_ENABLED": False, "SECRET_KEY": "k"})
    with app.app_context():
        yield app


def test_old_database_is_upgraded_in_place(legacy_app):
    client = legacy_app.test_client()
    # every page works against the upgraded schema
    for path in ("/", "/equipment", "/equipment/1", "/company/1", "/jobs/1", "/movements", "/movements/1", "/loans", "/loans/new", "/reports/stock", "/api/equipment"):
        assert client.get(path).status_code == 200, path

    lens = Equipment.query.filter_by(id=1).one()
    assert lens.epc == "E2801160600002042BB8A1C1"  # upper-cased
    assert lens.location == "" and lens.condition == "good" and lens.created_at is not None


def test_dangling_references_from_the_old_company_delete_bug_are_cleared(legacy_app):
    from rfida_server.models import InventorySession, Movement

    assert Movement.query.filter_by(id=1).one().company_id is None  # pointed at deleted company 99
    assert Movement.query.filter_by(id=2).one().job_id is None  # pointed at deleted job 77
    assert InventorySession.query.one().company_id is None


def test_upgrade_is_idempotent(legacy_app):
    from rfida_server.schema import upgrade_schema

    upgrade_schema()
    upgrade_schema()
    assert legacy_app.test_client().get("/equipment").status_code == 200

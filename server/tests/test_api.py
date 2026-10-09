"""Handheld REST API: contract stability and input hardening."""

from rfida_server.models import Equipment, Movement
from rfida_server.services import create_loan

from conftest import future, make_equipment


def test_equipment_contract_shape(client):
    make_equipment("E2801160600002042BB8A1C3", "Sony A7IV", category="機身", serial_number="123")
    data = client.get("/api/equipment").get_json()
    assert data == [
        {
            "id": 1,
            "epc": "E2801160600002042BB8A1C3",
            "name": "Sony A7IV",
            "category": "機身",
            "serialNumber": "123",
            "status": "in_stock",
            "lastSeenAt": None,
        }
    ]


def test_equipment_status_never_leaves_the_ios_enum(client):
    """The iOS app decodes status as a strict 3-value enum: on loan must not add a value."""
    eq = make_equipment("AA01")
    create_loan({"borrower_name": "Bob", "due_date": future()}, equipment_ids=[eq.id])
    statuses = {e["status"] for e in client.get("/api/equipment").get_json()}
    assert statuses <= {"in_stock", "checked_out", "missing"}


def test_register_normalises_and_rejects_duplicates_case_insensitively(client):
    r = client.post("/api/equipment/register", json={"epc": " e2801160600002042bb8a1c1 ", "name": "A"})
    assert r.status_code == 201
    assert r.get_json()["epc"] == "E2801160600002042BB8A1C1"

    dup = client.post("/api/equipment/register", json={"epc": "E2801160600002042bb8a1c1", "name": "B"})
    assert dup.status_code == 409
    assert "error" in dup.get_json()


def test_register_requires_name_and_valid_epc(client):
    assert client.post("/api/equipment/register", json={"epc": "AB12"}).status_code == 400
    assert client.post("/api/equipment/register", json={"epc": "has space", "name": "x"}).status_code == 400
    assert client.post("/api/equipment/register", json={"name": "x"}).status_code == 400
    assert client.post("/api/equipment/register", json=["not", "an", "object"]).status_code == 400


def test_register_accepts_128_char_epc(client):
    epc = "AB" * 64
    r = client.post("/api/equipment/register", json={"epc": epc, "name": "long"})
    assert r.status_code == 201


def test_movement_out_in_and_missing(client):
    a, b, c = (make_equipment(e) for e in ("AA01", "AA02", "AA03"))
    out = client.post("/api/movements", json={"direction": "out", "epcs": ["aa01", "AA02", "AA03"]})
    assert out.status_code == 201
    assert {e.status for e in Equipment.query.all()} == {"checked_out"}

    back = client.post(
        "/api/movements",
        json={"direction": "in", "epcs": ["AA01"], "missingEpcs": ["AA03", "AA01"]},
    )
    assert back.status_code == 201
    statuses = {e.epc: e.status for e in Equipment.query.all()}
    # a scanned EPC is never "missing", even if the client listed it in both arrays
    assert statuses == {"AA01": "in_stock", "AA02": "checked_out", "AA03": "missing"}
    assert back.get_json()["missingEpcs"] == ["AA03"]


def test_movement_reports_unknown_epcs(client):
    make_equipment("AA01")
    r = client.post("/api/movements", json={"direction": "out", "epcs": ["AA01", "ZZ99"]})
    assert r.get_json()["unknownEpcs"] == ["ZZ99"]


def test_movement_validation_returns_json_400_not_500(client):
    for body in (
        {"direction": "sideways", "epcs": []},
        {"direction": "out", "epcs": "ABC"},
        {"direction": "out", "epcs": [1, 2]},
        {"direction": "out", "epcs": [], "jobId": 999},
        {"direction": "out", "epcs": [], "companyId": 999},
    ):
        r = client.post("/api/movements", json=body)
        assert r.status_code == 400, body
        assert r.is_json and "error" in r.get_json()
    assert Movement.query.count() == 0


def test_returning_from_job_does_not_free_an_item_on_loan(client):
    eq = make_equipment("AA01")
    create_loan({"borrower_name": "Bob", "due_date": future()}, equipment_ids=[eq.id])
    client.post("/api/movements", json={"direction": "in", "epcs": ["AA01"]})
    assert Equipment.query.first().status == "checked_out"


def test_inventory_bad_timestamp_is_400_and_missing_item_is_found(client):
    eq = make_equipment("AA01")
    eq.status = "missing"
    from rfida_server.extensions import db

    db.session.commit()

    bad = client.post("/api/inventory-sessions", json={"scannedEpcs": ["AA01"], "timestamp": "garbage"})
    assert bad.status_code == 400

    ok = client.post(
        "/api/inventory-sessions",
        json={"scannedEpcs": ["aa01", "AA01", "NEW9"], "batchLabel": "A", "timestamp": "2026-09-11T10:30:00Z"},
    )
    assert ok.status_code == 201
    body = ok.get_json()
    assert body["scannedEpcs"] == ["AA01", "NEW9"]  # normalised + de-duplicated
    assert body["unknownEpcs"] == ["NEW9"]
    assert body["timestamp"] == "2026-09-11T10:30:00Z"
    assert Equipment.query.first().status == "in_stock"


def test_api_errors_are_json(client):
    r = client.get("/api/does-not-exist")
    assert r.status_code == 404 and r.is_json
    r = client.get("/api/jobs/999/expected-items")
    assert r.status_code == 404 and r.is_json
    r = client.put("/api/equipment")
    assert r.status_code == 405 and r.is_json


def test_timestamps_are_ios_decodable(client):
    """iOS uses .iso8601 which rejects fractional seconds."""
    make_equipment("AA01")
    client.post("/api/movements", json={"direction": "out", "epcs": ["AA01"]})
    created = client.get("/api/equipment").get_json()[0]["lastSeenAt"]
    import re

    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", created)


def test_loan_api_roundtrip(client):
    make_equipment("AA01")
    make_equipment("AA02")
    r = client.post(
        "/api/loans",
        json={"borrowerName": "Bob", "dueDate": future(2), "epcs": ["aa01", "AA02"], "purpose": "shoot"},
    )
    assert r.status_code == 201
    loan = r.get_json()
    assert loan["docNo"] == "LN-000001" and loan["status"] == "active" and len(loan["items"]) == 2

    partial = client.post(
        f"/api/loans/{loan['id']}/return",
        json={"items": [{"epc": "AA01", "condition": "damaged", "note": "scratch"}]},
    ).get_json()
    assert partial["status"] == "partial"

    extended = client.post(f"/api/loans/{loan['id']}/extend", json={"dueDate": future(10)}).get_json()
    assert extended["dueDate"] == future(10)

    done = client.post(f"/api/loans/{loan['id']}/return", json={"returnAll": True}).get_json()
    assert done["status"] == "returned"
    assert client.get("/api/loans?status=returned").get_json()[0]["id"] == loan["id"]

    bad = client.post("/api/loans", json={"borrowerName": "x", "dueDate": "2001-01-01", "epcs": ["AA01"]})
    assert bad.status_code == 400

from datetime import datetime, timezone

from flask import Blueprint, jsonify, request

from .extensions import db
from .models import (
    Equipment,
    InventorySession,
    Job,
    Movement,
    Staff,
    VALID_DIRECTIONS,
    utcnow,
)

api_bp = Blueprint("api", __name__, url_prefix="/api")


def parse_iso(value):
    if not value:
        return None
    text = value.replace("Z", "+00:00")
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).replace(tzinfo=None)


@api_bp.get("/equipment")
def list_equipment():
    items = Equipment.query.order_by(Equipment.id).all()
    return jsonify([item.to_dict() for item in items])


@api_bp.get("/staff")
def list_staff():
    items = Staff.query.order_by(Staff.id).all()
    return jsonify([item.to_dict() for item in items])


@api_bp.get("/jobs")
def list_jobs():
    query = Job.query
    status = request.args.get("status")
    if status:
        query = query.filter_by(status=status)
    items = query.order_by(Job.date.desc()).all()
    return jsonify([item.to_dict() for item in items])


@api_bp.get("/jobs/<int:job_id>/expected-items")
def job_expected_items(job_id):
    job = Job.query.get_or_404(job_id)
    movement = job.latest_out_movement()
    if not movement:
        return jsonify([])
    epcs = movement.epcs or []
    equipment_by_epc = {
        e.epc: e.id for e in Equipment.query.filter(Equipment.epc.in_(epcs)).all()
    }
    result = [
        {"epc": epc, "equipmentId": equipment_by_epc[epc]}
        for epc in epcs
        if epc in equipment_by_epc
    ]
    return jsonify(result)


@api_bp.post("/equipment/register")
def register_equipment():
    body = request.get_json(silent=True) or {}
    epc = (body.get("epc") or "").strip()
    if not epc:
        return jsonify({"error": "epc is required"}), 400

    existing = Equipment.query.filter_by(epc=epc).first()
    if existing:
        return jsonify({"error": f"epc {epc} 已經登記咗"}), 409

    equipment = Equipment(
        epc=epc,
        name=body.get("name") or "",
        category=body.get("category") or "",
        serial_number=body.get("serialNumber") or "",
        status="in_stock",
    )
    db.session.add(equipment)
    db.session.commit()
    return jsonify(equipment.to_dict()), 201


@api_bp.post("/movements")
def create_movement():
    body = request.get_json(silent=True) or {}
    direction = body.get("direction")
    if direction not in VALID_DIRECTIONS:
        return jsonify({"error": "direction must be 'out' or 'in'"}), 400

    epcs = body.get("epcs") or []
    missing_epcs = body.get("missingEpcs")

    movement = Movement(
        job_id=body.get("jobId"),
        staff_id=body.get("staffId"),
        direction=direction,
        epcs=epcs,
        missing_epcs=missing_epcs,
        note=body.get("note"),
    )
    db.session.add(movement)

    now = utcnow()
    if direction == "out":
        Equipment.query.filter(Equipment.epc.in_(epcs)).update(
            {"status": "checked_out", "last_seen_at": now},
            synchronize_session=False,
        )
    else:
        if epcs:
            Equipment.query.filter(Equipment.epc.in_(epcs)).update(
                {"status": "in_stock", "last_seen_at": now},
                synchronize_session=False,
            )
        if missing_epcs:
            Equipment.query.filter(Equipment.epc.in_(missing_epcs)).update(
                {"status": "missing"}, synchronize_session=False
            )

    db.session.commit()
    return jsonify(movement.to_dict()), 201


@api_bp.post("/inventory-sessions")
def create_inventory_session():
    body = request.get_json(silent=True) or {}
    scanned_epcs = body.get("scannedEpcs") or []
    timestamp = parse_iso(body.get("timestamp")) or utcnow()

    known = {
        e.epc: e for e in Equipment.query.filter(Equipment.epc.in_(scanned_epcs)).all()
    }
    unknown_epcs = [epc for epc in scanned_epcs if epc not in known]

    for equipment in known.values():
        equipment.last_seen_at = timestamp
        if equipment.status == "missing":
            equipment.status = "in_stock"

    session = InventorySession(
        staff_id=body.get("staffId"),
        batch_label=body.get("batchLabel") or "",
        scanned_epcs=scanned_epcs,
        unknown_epcs=unknown_epcs,
        timestamp=timestamp,
    )
    db.session.add(session)
    db.session.commit()
    return jsonify(session.to_dict()), 201

"""REST API consumed by the iPhone handheld app (docs/API_CONTRACT.md).

Contract rules that must not drift:
  * equipment `status` is one of in_stock / checked_out / missing
  * timestamps are ISO-8601 UTC without fractions (`2026-09-11T10:30:00Z`)
  * errors come back as `{"error": "<text>"}`; the app shows the body verbatim
"""

from flask import Blueprint, jsonify, request

from . import services
from .extensions import db
from .models import Company, Equipment, Job, Loan
from .services import ServiceError
from .utils import normalize_epc_list, parse_iso_datetime, to_int

api_bp = Blueprint("api", __name__, url_prefix="/api")


def json_body():
    body = request.get_json(silent=True)
    if body is None:
        return {}
    if not isinstance(body, dict):
        raise ServiceError("request body must be a JSON object")
    return body


@api_bp.errorhandler(ServiceError)
def handle_service_error(err):
    return jsonify({"error": "; ".join(err.messages)}), err.status


# ------------------------------------------------------------------ read


@api_bp.get("/equipment")
def list_equipment():
    items = Equipment.query.order_by(Equipment.id).all()
    return jsonify([item.to_dict() for item in items])


@api_bp.get("/company")
def list_companies():
    items = Company.query.order_by(Company.id).all()
    return jsonify([item.to_dict() for item in items])


@api_bp.get("/jobs")
def list_jobs():
    query = Job.query
    status = request.args.get("status")
    if status:
        query = query.filter_by(status=status)
    items = query.order_by(Job.date.desc(), Job.id.desc()).all()
    return jsonify([item.to_dict() for item in items])


@api_bp.get("/jobs/<int:job_id>/expected-items")
def job_expected_items(job_id):
    job = db.get_or_404(Job, job_id)
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


# ------------------------------------------------------------------ handheld writes


@api_bp.post("/equipment/register")
def register_equipment():
    body = json_body()
    equipment = services.create_equipment(
        {
            "epc": body.get("epc"),
            "name": body.get("name"),
            "category": body.get("category"),
            "serial_number": body.get("serialNumber"),
        },
        source="handheld",
    )
    return jsonify(equipment.to_dict()), 201


@api_bp.post("/movements")
def create_movement():
    body = json_body()
    movement, unknown = services.record_movement(
        direction=body.get("direction"),
        epcs=body.get("epcs"),
        missing_epcs=body.get("missingEpcs"),
        job_id=to_int(body.get("jobId")),
        company_id=to_int(body.get("companyId")),
        note=body.get("note"),
        source="handheld",
    )
    data = movement.to_dict()
    data["unknownEpcs"] = unknown
    return jsonify(data), 201


@api_bp.post("/inventory-sessions")
def create_inventory_session():
    body = json_body()
    try:
        timestamp = parse_iso_datetime(body.get("timestamp"))
    except ValueError:
        raise ServiceError("timestamp must be an ISO-8601 date-time, e.g. 2026-09-11T10:30:00Z")
    session = services.record_inventory(
        company_id=to_int(body.get("companyId")),
        batch_label=body.get("batchLabel"),
        scanned_epcs=body.get("scannedEpcs"),
        timestamp=timestamp,
        source="handheld",
    )
    return jsonify(session.to_dict()), 201


# ------------------------------------------------------------------ loans
# Additive to the handheld contract: used by the web dashboard's loan service and
# available to any future client. Document in docs/API_CONTRACT.md.


@api_bp.get("/loans")
def list_loans():
    query = Loan.query
    status = request.args.get("status")
    if status == "overdue":
        query = services.overdue_loans_query()
    elif status:
        query = query.filter_by(status=status)
    equipment_id = to_int(request.args.get("equipmentId"))
    if equipment_id is not None:
        query = query.filter(Loan.items.any(equipment_id=equipment_id))
    items = query.order_by(Loan.due_date, Loan.id).all()
    return jsonify([item.to_dict() for item in items])


@api_bp.get("/loans/<int:loan_id>")
def get_loan(loan_id):
    return jsonify(db.get_or_404(Loan, loan_id).to_dict())


@api_bp.post("/loans")
def create_loan():
    body = json_body()
    epcs = body.get("epcs")
    loan = services.create_loan(
        {
            "company_id": body.get("companyId"),
            "borrower_name": body.get("borrowerName"),
            "contact": body.get("contact"),
            "purpose": body.get("purpose"),
            "handled_by": body.get("handledBy"),
            "due_date": body.get("dueDate"),
            "loan_date": body.get("loanDate"),
            "note": body.get("note"),
        },
        epcs=epcs if epcs is not None else [],
        source="api",
    )
    return jsonify(loan.to_dict()), 201


@api_bp.post("/loans/<int:loan_id>/return")
def return_loan(loan_id):
    loan = db.get_or_404(Loan, loan_id)
    body = json_body()
    if body.get("returnAll"):
        services.return_all_good(loan, source="api")
        return jsonify(loan.to_dict())

    entries = body.get("items")
    if not isinstance(entries, list) or not entries:
        raise ServiceError('provide "items": [{"epc": ..., "condition": "good|damaged|lost"}] or "returnAll": true')
    by_epc = {i.equipment.epc: i for i in loan.items}
    returns = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ServiceError("each item must be an object")
        clean, _ = normalize_epc_list([entry.get("epc")])
        item = by_epc.get(clean[0]) if clean else None
        if item is None:
            raise ServiceError(f"EPC {entry.get('epc')} 不屬於此借出單。")
        returns.append(
            {"item_id": item.id, "condition": entry.get("condition") or "good", "note": entry.get("note")}
        )
    services.return_loan_items(loan, returns, source="api")
    return jsonify(loan.to_dict())


@api_bp.post("/loans/<int:loan_id>/extend")
def extend_loan(loan_id):
    loan = db.get_or_404(Loan, loan_id)
    body = json_body()
    services.extend_loan(loan, body.get("dueDate"), reason=body.get("reason") or "", source="api")
    return jsonify(loan.to_dict())


@api_bp.post("/loans/<int:loan_id>/cancel")
def cancel_loan(loan_id):
    loan = db.get_or_404(Loan, loan_id)
    services.cancel_loan(loan, reason=json_body().get("reason") or "", source="api")
    return jsonify(loan.to_dict())

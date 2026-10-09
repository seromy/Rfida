from flask import render_template, request
from sqlalchemy.orm import joinedload

from ..extensions import db
from ..models import Company, Equipment, InventorySession, parse_doc_no
from . import dashboard_bp
from .common import apply_sort, audit_for, contains, local_day_range, paginate

SORT_COLUMNS = {
    "id": InventorySession.id,
    "time": InventorySession.timestamp,
    "batch": InventorySession.batch_label,
}


@dashboard_bp.get("/inventory-sessions")
def inventory_list():
    args = request.args
    q = args.get("q", "").strip()
    company_id = args.get("company_id", "")
    date_from, date_to = args.get("date_from", ""), args.get("date_to", "")
    only_unknown = args.get("unknown") == "1"

    query = InventorySession.query.options(joinedload(InventorySession.company))
    if company_id.isdigit():
        query = query.filter(InventorySession.company_id == int(company_id))
    start, end = local_day_range(date_from, date_to)
    if start:
        query = query.filter(InventorySession.timestamp >= start)
    if end:
        query = query.filter(InventorySession.timestamp < end)
    if only_unknown:
        query = query.filter(db.func.json_array_length(InventorySession.unknown_epcs) > 0)
    if q:
        clauses = [contains(InventorySession.batch_label, q)]
        parsed = parse_doc_no(q)
        if parsed and parsed[0] == "inventory":
            clauses.append(InventorySession.id == parsed[1])
        query = query.filter(db.or_(*clauses))

    query, sort, direction = apply_sort(
        query, SORT_COLUMNS, "time", default_dir="desc", tiebreak=InventorySession.id
    )
    page = paginate(query)
    return render_template(
        "dashboard/inventory_sessions.html",
        page=page,
        items=page.items,
        q=q,
        company_id=company_id,
        date_from=date_from,
        date_to=date_to,
        unknown=only_unknown,
        sort=sort,
        dir=direction,
        companies=Company.query.order_by(Company.name).all(),
    )


@dashboard_bp.get("/inventory-sessions/<int:session_id>")
def inventory_detail(session_id):
    session = db.get_or_404(InventorySession, session_id)
    scanned = session.scanned_epcs or []
    by_epc = (
        {e.epc: e for e in Equipment.query.filter(Equipment.epc.in_(scanned)).all()}
        if scanned
        else {}
    )
    return render_template(
        "dashboard/inventory_detail.html",
        s=session,
        known=[by_epc[e] for e in scanned if e in by_epc],
        unknown=[e for e in scanned if e not in by_epc],
        audit=audit_for("inventory", session.id),
    )

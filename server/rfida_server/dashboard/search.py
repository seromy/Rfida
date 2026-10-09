from flask import redirect, request, url_for

from ..extensions import db
from ..models import Company, Equipment, InventorySession, Job, Loan, Movement, parse_doc_no
from ..utils import normalize_epc
from . import dashboard_bp

_DOC_TARGETS = {
    "equipment": (Equipment, "dashboard.equipment_detail", "equipment_id"),
    "company": (Company, "dashboard.company_detail", "company_id"),
    "job": (Job, "dashboard.job_detail", "job_id"),
    "movement": (Movement, "dashboard.movement_detail", "movement_id"),
    "inventory": (InventorySession, "dashboard.inventory_detail", "session_id"),
    "loan": (Loan, "dashboard.loan_detail", "loan_id"),
}


@dashboard_bp.get("/search")
def search():
    """Shell-bar search: jump straight to a document number or an exact EPC,
    otherwise fall back to the equipment list report."""
    q = request.args.get("q", "").strip()
    if not q:
        return redirect(url_for("dashboard.equipment_list"))

    parsed = parse_doc_no(q)
    if parsed:
        model, endpoint, param = _DOC_TARGETS[parsed[0]]
        if db.session.get(model, parsed[1]) is not None:
            return redirect(url_for(endpoint, **{param: parsed[1]}))

    epc = normalize_epc(q)
    if epc:
        match = Equipment.query.filter_by(epc=epc).first()
        if match:
            return redirect(url_for("dashboard.equipment_detail", equipment_id=match.id))

    return redirect(url_for("dashboard.equipment_list", q=q))

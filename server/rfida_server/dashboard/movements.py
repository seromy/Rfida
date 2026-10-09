from flask import render_template, request
from sqlalchemy import String, cast
from sqlalchemy.orm import joinedload

from ..extensions import db
from ..models import Company, Equipment, Job, Movement, parse_doc_no
from ..services import DIRECTION_LABELS
from . import dashboard_bp
from .common import (
    apply_sort,
    audit_for,
    contains,
    csv_response,
    local_day_range,
    paginate,
)

SORT_COLUMNS = {
    "id": Movement.id,
    "created": Movement.created_at,
    "direction": (Movement.direction, Movement.created_at),
}


def filtered_movements():
    args = request.args
    q = args.get("q", "").strip()
    direction = args.get("direction", "")
    job_id = args.get("job_id", "")
    company_id = args.get("company_id", "")
    date_from = args.get("date_from", "")
    date_to = args.get("date_to", "")

    query = Movement.query.options(joinedload(Movement.job), joinedload(Movement.company))
    if direction in ("out", "in"):
        query = query.filter(Movement.direction == direction)
    if job_id.isdigit():
        query = query.filter(Movement.job_id == int(job_id))
    if company_id.isdigit():
        query = query.filter(Movement.company_id == int(company_id))
    start, end = local_day_range(date_from, date_to)
    if start:
        query = query.filter(Movement.created_at >= start)
    if end:
        query = query.filter(Movement.created_at < end)
    if q:
        clauses = [
            contains(cast(Movement.epcs, String), q),
            contains(cast(Movement.missing_epcs, String), q),
            contains(Movement.note, q),
            Movement.job.has(contains(Job.name, q)),
            Movement.company.has(contains(Company.name, q)),
        ]
        parsed = parse_doc_no(q)
        if parsed and parsed[0] == "movement":
            clauses.append(Movement.id == parsed[1])
        query = query.filter(db.or_(*clauses))
    filters = {
        "q": q,
        "direction": direction,
        "job_id": job_id,
        "company_id": company_id,
        "date_from": date_from,
        "date_to": date_to,
    }
    return query, filters


def _lookup_lists():
    return (
        Job.query.order_by(Job.date.desc(), Job.id.desc()).all(),
        Company.query.order_by(Company.name).all(),
    )


@dashboard_bp.get("/movements")
def movement_list():
    query, filters = filtered_movements()
    query, sort, direction = apply_sort(
        query, SORT_COLUMNS, "created", default_dir="desc", tiebreak=Movement.id
    )
    page = paginate(query)
    jobs, companies = _lookup_lists()
    return render_template(
        "dashboard/movements.html",
        page=page,
        items=page.items,
        sort=sort,
        dir=direction,
        jobs=jobs,
        companies=companies,
        **filters,
    )


@dashboard_bp.get("/movements/export.csv")
def movement_export():
    query, _ = filtered_movements()
    rows = []
    for mv in query.order_by(Movement.created_at.desc(), Movement.id.desc()).all():
        rows.append(
            [
                mv.doc_no,
                mv.created_at.strftime("%Y-%m-%d %H:%M:%S"),
                DIRECTION_LABELS[mv.direction],
                mv.job.name if mv.job else "",
                mv.company.name if mv.company else "",
                len(mv.epcs or []),
                " ".join(mv.epcs or []),
                " ".join(mv.missing_epcs or []),
                mv.note or "",
            ]
        )
    return csv_response(
        "movements.csv",
        ["單號", "時間(UTC)", "方向", "Job", "公司", "數量", "EPC", "缺件 EPC", "備註"],
        rows,
    )


@dashboard_bp.get("/movements/<int:movement_id>")
def movement_detail(movement_id):
    movement = db.get_or_404(Movement, movement_id)
    all_epcs = list(movement.epcs or []) + list(movement.missing_epcs or [])
    by_epc = (
        {e.epc: e for e in Equipment.query.filter(Equipment.epc.in_(all_epcs)).all()}
        if all_epcs
        else {}
    )
    return render_template(
        "dashboard/movement_detail.html",
        mv=movement,
        scanned=[(epc, by_epc.get(epc)) for epc in movement.epcs or []],
        missing=[(epc, by_epc.get(epc)) for epc in movement.missing_epcs or []],
        audit=audit_for("movement", movement.id),
    )

from flask import flash, redirect, render_template, request, url_for
from sqlalchemy.orm import joinedload, selectinload

from .. import services
from ..extensions import db
from ..models import Equipment, LoanItem
from ..services import STATUS_LABELS, ServiceError
from . import dashboard_bp
from .common import (
    apply_sort,
    audit_for,
    contains,
    csv_response,
    movements_containing,
    paginate,
)
from .home import equipment_stats

SORT_COLUMNS = {
    "id": Equipment.id,
    "name": Equipment.name,
    "category": (Equipment.category, Equipment.name),
    "epc": Equipment.epc,
    "serial": Equipment.serial_number,
    "location": (Equipment.location, Equipment.name),
    "status": (Equipment.status, Equipment.name),
    "seen": Equipment.last_seen_at,
}

FORM_FIELDS = ("epc", "name", "category", "serial_number", "location", "note")


def _on_loan():
    return Equipment.loan_items.any(LoanItem.state == "out")


def filtered_equipment():
    q = request.args.get("q", "").strip()
    status = request.args.get("status", "")
    category = request.args.get("category", "")
    location = request.args.get("location", "").strip()

    query = Equipment.query.options(
        selectinload(Equipment.loan_items).joinedload(LoanItem.loan)
    )
    if q:
        query = query.filter(
            db.or_(
                contains(Equipment.name, q),
                contains(Equipment.epc, q),
                contains(Equipment.serial_number, q),
                contains(Equipment.category, q),
                contains(Equipment.location, q),
            )
        )
    if category:
        query = query.filter(Equipment.category == category)
    if location:
        query = query.filter(Equipment.location == location)
    if status == "on_loan":
        query = query.filter(_on_loan())
    elif status == "checked_out":
        query = query.filter(Equipment.status == "checked_out", ~_on_loan())
    elif status == "damaged":
        query = query.filter(Equipment.condition == "damaged")
    elif status in ("in_stock", "missing"):
        query = query.filter(Equipment.status == status)
    return query, {"q": q, "status": status, "category": category, "location": location}


def _distinct(column):
    rows = db.session.query(column).filter(column != "").distinct().order_by(column).all()
    return [r[0] for r in rows]


def _form_values(equipment=None):
    if request.method == "POST":
        return {k: request.form.get(k, "") for k in FORM_FIELDS}
    if equipment is not None:
        return {
            "epc": equipment.epc,
            "name": equipment.name,
            "category": equipment.category,
            "serial_number": equipment.serial_number,
            "location": equipment.location,
            "note": equipment.note,
        }
    return {k: request.args.get(k, "") for k in FORM_FIELDS}


def _form_page(equipment, errors=None):
    return render_template(
        "dashboard/equipment_form.html",
        equipment=equipment,
        form=_form_values(equipment),
        errors=errors or [],
        categories=_distinct(Equipment.category),
        locations=_distinct(Equipment.location),
    )


@dashboard_bp.get("/equipment")
def equipment_list():
    query, filters = filtered_equipment()
    query, sort, direction = apply_sort(
        query, SORT_COLUMNS, "name", tiebreak=Equipment.id
    )
    page = paginate(query)
    return render_template(
        "dashboard/equipment.html",
        page=page,
        items=page.items,
        sort=sort,
        dir=direction,
        counts=equipment_stats(),
        categories=_distinct(Equipment.category),
        locations=_distinct(Equipment.location),
        **filters,
    )


@dashboard_bp.get("/equipment/export.csv")
def equipment_export():
    query, _ = filtered_equipment()
    rows = []
    for eq in query.order_by(Equipment.id).all():
        item = eq.open_loan_item
        rows.append(
            [
                eq.doc_no,
                eq.name,
                eq.category,
                eq.epc,
                eq.serial_number,
                eq.location,
                "借出中" if item else STATUS_LABELS[eq.status],
                "損壞" if eq.is_damaged else "正常",
                item.loan.doc_no if item else "",
                eq.last_seen_at.strftime("%Y-%m-%d %H:%M:%S") if eq.last_seen_at else "",
            ]
        )
    return csv_response(
        "equipment.csv",
        ["編號", "名稱", "分類", "EPC", "序號", "存放位置", "狀態", "狀況", "借出單", "最後偵測(UTC)"],
        rows,
    )


@dashboard_bp.route("/equipment/new", methods=["GET", "POST"])
def equipment_create():
    if request.method == "GET":
        return _form_page(None)
    try:
        equipment = services.create_equipment(_form_values(), source="web")
    except ServiceError as err:
        return _form_page(None, err.messages), err.status
    flash(f"已登記器材「{equipment.name}」({equipment.doc_no})", "success")
    return redirect(url_for("dashboard.equipment_detail", equipment_id=equipment.id))


@dashboard_bp.get("/equipment/<int:equipment_id>")
def equipment_detail(equipment_id):
    equipment = db.get_or_404(Equipment, equipment_id)
    loan_history = (
        LoanItem.query.filter_by(equipment_id=equipment.id)
        .options(joinedload(LoanItem.loan))
        .order_by(LoanItem.id.desc())
        .all()
    )
    return render_template(
        "dashboard/equipment_detail.html",
        eq=equipment,
        loan_item=equipment.open_loan_item,
        loan_history=loan_history,
        movements=movements_containing(equipment.epc),
        audit=audit_for("equipment", equipment.id),
        status_labels=STATUS_LABELS,
    )


@dashboard_bp.route("/equipment/<int:equipment_id>/edit", methods=["GET", "POST"])
def equipment_edit(equipment_id):
    equipment = db.get_or_404(Equipment, equipment_id)
    if request.method == "GET":
        return _form_page(equipment)
    try:
        _, changes = services.update_equipment(equipment, _form_values(), source="web")
    except ServiceError as err:
        db.session.rollback()
        return _form_page(equipment, err.messages), err.status
    flash("已儲存變更" if changes else "沒有任何變更", "success" if changes else "info")
    return redirect(url_for("dashboard.equipment_detail", equipment_id=equipment.id))


@dashboard_bp.post("/equipment/<int:equipment_id>/status")
def equipment_status(equipment_id):
    equipment = db.get_or_404(Equipment, equipment_id)
    new_status = request.form.get("status", "")
    try:
        changed = services.change_equipment_status(
            equipment, new_status, reason=request.form.get("reason", ""), source="web"
        )
    except ServiceError as err:
        db.session.rollback()
        for message in err.messages:
            flash(message, "error")
    else:
        flash(
            f"「{equipment.name}」狀態已更新為{STATUS_LABELS[new_status]}" if changed else "狀態沒有改變",
            "success" if changed else "info",
        )
    return redirect(url_for("dashboard.equipment_detail", equipment_id=equipment.id))


@dashboard_bp.post("/equipment/<int:equipment_id>/condition")
def equipment_condition(equipment_id):
    equipment = db.get_or_404(Equipment, equipment_id)
    condition = request.form.get("condition", "")
    try:
        if services.set_equipment_condition(
            equipment, condition, reason=request.form.get("reason", ""), source="web"
        ):
            services.commit()
            flash("器材狀況已更新", "success")
    except ServiceError as err:
        db.session.rollback()
        for message in err.messages:
            flash(message, "error")
    return redirect(url_for("dashboard.equipment_detail", equipment_id=equipment.id))


@dashboard_bp.post("/equipment/<int:equipment_id>/delete")
def equipment_delete(equipment_id):
    equipment = db.get_or_404(Equipment, equipment_id)
    try:
        label = services.delete_equipment(equipment, source="web")
    except ServiceError as err:
        db.session.rollback()
        for message in err.messages:
            flash(message, "error")
        return redirect(url_for("dashboard.equipment_detail", equipment_id=equipment_id))
    flash(f"已刪除器材「{label}」", "success")
    return redirect(url_for("dashboard.equipment_list"))

from flask import flash, redirect, render_template, request, url_for
from sqlalchemy.orm import selectinload

from .. import services
from ..extensions import db
from ..models import Company, InventorySession, Loan, Movement
from ..services import ServiceError
from . import dashboard_bp
from .common import apply_sort, audit_for, contains, paginate

SORT_COLUMNS = {
    "id": Company.id,
    "name": Company.name,
    "contact": Company.contact_name,
}
FORM_FIELDS = ("name", "contact_name", "phone", "email", "note")


def _form_values(company=None):
    if request.method == "POST":
        return {k: request.form.get(k, "") for k in FORM_FIELDS}
    if company is not None:
        return {k: getattr(company, k) for k in FORM_FIELDS}
    return {k: "" for k in FORM_FIELDS}


def _form_page(company, errors=None):
    return render_template(
        "dashboard/company_form.html",
        company=company,
        form=_form_values(company),
        errors=errors or [],
    )


@dashboard_bp.get("/company")
def company_list():
    q = request.args.get("q", "").strip()
    query = Company.query.options(selectinload(Company.loans))
    if q:
        query = query.filter(
            db.or_(
                contains(Company.name, q),
                contains(Company.contact_name, q),
                contains(Company.phone, q),
                contains(Company.email, q),
            )
        )
    query, sort, direction = apply_sort(query, SORT_COLUMNS, "name", tiebreak=Company.id)
    page = paginate(query)
    return render_template(
        "dashboard/company.html", page=page, items=page.items, q=q, sort=sort, dir=direction
    )


@dashboard_bp.route("/company/new", methods=["GET", "POST"])
def company_create():
    if request.method == "GET":
        return _form_page(None)
    try:
        company = services.create_company(_form_values(), source="web")
    except ServiceError as err:
        return _form_page(None, err.messages), err.status
    flash(f"已新增公司「{company.name}」({company.doc_no})", "success")
    return redirect(url_for("dashboard.company_detail", company_id=company.id))


@dashboard_bp.get("/company/<int:company_id>")
def company_detail(company_id):
    company = db.get_or_404(Company, company_id)
    return render_template(
        "dashboard/company_detail.html",
        company=company,
        loans=Loan.query.filter_by(company_id=company.id)
        .order_by(Loan.id.desc())
        .all(),
        movements=Movement.query.filter_by(company_id=company.id)
        .order_by(Movement.created_at.desc(), Movement.id.desc())
        .limit(50)
        .all(),
        inventories=InventorySession.query.filter_by(company_id=company.id)
        .order_by(InventorySession.timestamp.desc())
        .limit(50)
        .all(),
        usage=services.company_usage(company),
        audit=audit_for("company", company.id),
    )


@dashboard_bp.route("/company/<int:company_id>/edit", methods=["GET", "POST"])
def company_edit(company_id):
    company = db.get_or_404(Company, company_id)
    if request.method == "GET":
        return _form_page(company)
    try:
        _, changes = services.update_company(company, _form_values(), source="web")
    except ServiceError as err:
        db.session.rollback()
        return _form_page(company, err.messages), err.status
    flash("已儲存變更" if changes else "沒有任何變更", "success" if changes else "info")
    return redirect(url_for("dashboard.company_detail", company_id=company.id))


@dashboard_bp.post("/company/<int:company_id>/delete")
def company_delete(company_id):
    company = db.get_or_404(Company, company_id)
    try:
        label = services.delete_company(company, source="web")
    except ServiceError as err:
        db.session.rollback()
        for message in err.messages:
            flash(message, "error")
        return redirect(url_for("dashboard.company_detail", company_id=company_id))
    flash(f"已刪除公司「{label}」", "success")
    return redirect(url_for("dashboard.company_list"))

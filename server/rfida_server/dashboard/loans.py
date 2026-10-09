from flask import flash, redirect, render_template, request, url_for
from sqlalchemy.orm import joinedload, selectinload

from .. import services
from ..extensions import db
from ..models import Company, Equipment, Loan, LoanItem, parse_doc_no
from ..services import LOAN_STATUS_LABELS, ServiceError
from ..utils import local_today, split_epc_text
from . import dashboard_bp
from .common import apply_sort, audit_for, contains, csv_response, paginate

SORT_COLUMNS = {
    "id": Loan.id,
    "borrower": (Loan.borrower_name, Loan.id),
    "loan_date": Loan.loan_date,
    "due": (Loan.due_date, Loan.id),
    "status": (Loan.status, Loan.due_date),
}

FORM_FIELDS = ("company_id", "borrower_name", "contact", "purpose", "handled_by", "due_date", "note")


def _open():
    return Loan.status.in_(("active", "partial"))


def loan_counts():
    today = local_today()
    return {
        "all": Loan.query.count(),
        "open": Loan.query.filter(_open()).count(),
        "overdue": Loan.query.filter(_open(), Loan.due_date < today).count(),
        "returned": Loan.query.filter_by(status="returned").count(),
        "cancelled": Loan.query.filter_by(status="cancelled").count(),
    }


def filtered_loans():
    args = request.args
    status = args.get("status", "")
    q = args.get("q", "").strip()
    company_id = args.get("company_id", "")
    due_from, due_to = args.get("due_from", ""), args.get("due_to", "")

    query = Loan.query.options(
        joinedload(Loan.company), selectinload(Loan.items).joinedload(LoanItem.equipment)
    )
    if status == "open":
        query = query.filter(_open())
    elif status == "overdue":
        query = query.filter(_open(), Loan.due_date < local_today())
    elif status in ("returned", "cancelled", "active", "partial"):
        query = query.filter(Loan.status == status)
    if company_id.isdigit():
        query = query.filter(Loan.company_id == int(company_id))
    from ..utils import parse_date

    for text, op in ((due_from, "ge"), (due_to, "le")):
        try:
            day = parse_date(text)
        except ValueError:
            day = None
        if day:
            query = query.filter(Loan.due_date >= day if op == "ge" else Loan.due_date <= day)
    if q:
        clauses = [
            contains(Loan.borrower_name, q),
            contains(Loan.contact, q),
            contains(Loan.purpose, q),
            Loan.company.has(contains(Company.name, q)),
            Loan.items.any(
                LoanItem.equipment.has(db.or_(contains(Equipment.name, q), contains(Equipment.epc, q)))
            ),
        ]
        parsed = parse_doc_no(q)
        if parsed and parsed[0] == "loan":
            clauses.append(Loan.id == parsed[1])
        query = query.filter(db.or_(*clauses))
    filters = {
        "status": status,
        "q": q,
        "company_id": company_id,
        "due_from": due_from,
        "due_to": due_to,
    }
    return query, filters


@dashboard_bp.get("/loans")
def loan_list():
    query, filters = filtered_loans()
    query, sort, direction = apply_sort(
        query, SORT_COLUMNS, "id", default_dir="desc", tiebreak=Loan.id
    )
    page = paginate(query)
    return render_template(
        "dashboard/loans.html",
        page=page,
        items=page.items,
        sort=sort,
        dir=direction,
        counts=loan_counts(),
        companies=Company.query.order_by(Company.name).all(),
        **filters,
    )


@dashboard_bp.get("/loans/export.csv")
def loan_export():
    query, _ = filtered_loans()
    rows = []
    for loan in query.order_by(Loan.id.desc()).all():
        rows.append(
            [
                loan.doc_no,
                LOAN_STATUS_LABELS[loan.display_status],
                loan.company.name if loan.company else "",
                loan.borrower_name,
                loan.contact,
                loan.purpose,
                loan.handled_by,
                loan.loan_date.strftime("%Y-%m-%d %H:%M:%S"),
                loan.due_date.isoformat(),
                loan.days_overdue,
                loan.item_count,
                loan.outstanding_count,
                "; ".join(f"{i.equipment.name} ({i.equipment.epc})" for i in loan.items if i.state != "cancelled"),
            ]
        )
    return csv_response(
        "loans.csv",
        ["單號", "狀態", "公司", "借用人", "聯絡方式", "用途", "經手人", "借出時間(UTC)", "到期日", "逾期日數", "件數", "未還", "器材"],
        rows,
    )


# ------------------------------------------------------------------ create


def _form_values():
    if request.method == "POST":
        return {k: request.form.get(k, "") for k in FORM_FIELDS}
    # Default due date: one week from today.
    from datetime import timedelta

    return {
        **{k: "" for k in FORM_FIELDS},
        "company_id": request.args.get("company_id", ""),
        "due_date": (local_today() + timedelta(days=7)).isoformat(),
    }


def _new_page(errors=None, status=200):
    if request.method == "POST":
        selected = {int(v) for v in request.form.getlist("equipment_id") if v.isdigit()}
        pasted = request.form.get("epc_paste", "")
    else:
        selected = {int(v) for v in request.args.getlist("equipment") if v.isdigit()}
        pasted = ""
    equipment = (
        Equipment.query.options(selectinload(Equipment.loan_items).joinedload(LoanItem.loan))
        .order_by(Equipment.category, Equipment.name, Equipment.id)
        .all()
    )
    rows = [
        {"eq": eq, "reason": services.loanability(eq), "selected": eq.id in selected}
        for eq in equipment
    ]
    return (
        render_template(
            "dashboard/loan_form.html",
            form=_form_values(),
            errors=errors or [],
            rows=rows,
            pasted=pasted,
            companies=Company.query.order_by(Company.name).all(),
            categories=sorted({r["eq"].category or "未分類" for r in rows}),
            today=local_today().isoformat(),
        ),
        status,
    )


@dashboard_bp.route("/loans/new", methods=["GET", "POST"])
def loan_create():
    if request.method == "GET":
        body, status = _new_page()
        return body, status
    try:
        loan = services.create_loan(
            _form_values(),
            equipment_ids=request.form.getlist("equipment_id"),
            epcs=split_epc_text(request.form.get("epc_paste", "")),
            source="web",
        )
    except ServiceError as err:
        db.session.rollback()
        return _new_page(err.messages, err.status)
    flash(f"已建立借出單 {loan.doc_no},共 {loan.item_count} 件器材", "success")
    return redirect(url_for("dashboard.loan_detail", loan_id=loan.id))


# ------------------------------------------------------------------ object page


def _loan_or_404(loan_id):
    return db.get_or_404(Loan, loan_id)


@dashboard_bp.get("/loans/<int:loan_id>")
def loan_detail(loan_id):
    loan = _loan_or_404(loan_id)
    return render_template(
        "dashboard/loan_detail.html",
        loan=loan,
        audit=audit_for("loan", loan.id),
        today=local_today().isoformat(),
        status_labels=LOAN_STATUS_LABELS,
    )


@dashboard_bp.get("/loans/<int:loan_id>/print")
def loan_print(loan_id):
    loan = _loan_or_404(loan_id)
    return render_template("dashboard/loan_print.html", loan=loan)


def _fail(err, loan_id):
    db.session.rollback()
    for message in err.messages:
        flash(message, "error")
    return redirect(url_for("dashboard.loan_detail", loan_id=loan_id))


@dashboard_bp.post("/loans/<int:loan_id>/return")
def loan_return(loan_id):
    loan = _loan_or_404(loan_id)
    returns = []
    for raw in request.form.getlist("return_item"):
        if not raw.isdigit():
            continue
        returns.append(
            {
                "item_id": int(raw),
                "condition": request.form.get(f"condition_{raw}", "good"),
                "note": request.form.get(f"note_{raw}", ""),
            }
        )
    try:
        services.return_loan_items(loan, returns, note=request.form.get("note", ""), source="web")
    except ServiceError as err:
        return _fail(err, loan_id)
    if loan.status == "returned":
        flash(f"{loan.doc_no} 全部器材已歸還,借出單完結", "success")
    else:
        flash(f"已登記歸還 {len(returns)} 件,尚餘 {loan.outstanding_count} 件未還", "success")
    return redirect(url_for("dashboard.loan_detail", loan_id=loan.id))


@dashboard_bp.post("/loans/<int:loan_id>/return-all")
def loan_return_all(loan_id):
    loan = _loan_or_404(loan_id)
    try:
        services.return_all_good(loan, source="web")
    except ServiceError as err:
        return _fail(err, loan_id)
    flash(f"{loan.doc_no} 全部器材已正常歸還,借出單完結", "success")
    return redirect(url_for("dashboard.loan_detail", loan_id=loan.id))


@dashboard_bp.post("/loans/<int:loan_id>/extend")
def loan_extend(loan_id):
    loan = _loan_or_404(loan_id)
    try:
        services.extend_loan(
            loan, request.form.get("due_date"), reason=request.form.get("reason", ""), source="web"
        )
    except ServiceError as err:
        return _fail(err, loan_id)
    flash(f"已延期至 {loan.due_date.isoformat()}", "success")
    return redirect(url_for("dashboard.loan_detail", loan_id=loan.id))


@dashboard_bp.post("/loans/<int:loan_id>/cancel")
def loan_cancel(loan_id):
    loan = _loan_or_404(loan_id)
    try:
        services.cancel_loan(loan, reason=request.form.get("reason", ""), source="web")
    except ServiceError as err:
        return _fail(err, loan_id)
    flash(f"借出單 {loan.doc_no} 已取消,器材已回復在庫", "success")
    return redirect(url_for("dashboard.loan_detail", loan_id=loan.id))


@dashboard_bp.post("/loans/<int:loan_id>/update")
def loan_update(loan_id):
    loan = _loan_or_404(loan_id)
    try:
        _, changes = services.update_loan_details(
            loan, {k: request.form.get(k, "") for k in FORM_FIELDS}, source="web"
        )
    except ServiceError as err:
        return _fail(err, loan_id)
    flash("已儲存變更" if changes else "沒有任何變更", "success" if changes else "info")
    return redirect(url_for("dashboard.loan_detail", loan_id=loan.id))

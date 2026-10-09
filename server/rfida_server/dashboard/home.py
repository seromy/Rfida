from flask import render_template

from .. import services
from ..models import AuditLog, Equipment, Job, Loan, LoanItem
from . import dashboard_bp


def equipment_stats():
    """Counts shared by the launchpad tiles and the shell navigation badges."""
    on_loan_q = Equipment.loan_items.any(LoanItem.state == "out")
    return {
        "total": Equipment.query.count(),
        "in_stock": Equipment.query.filter_by(status="in_stock").count(),
        "checked_out": Equipment.query.filter(
            Equipment.status == "checked_out", ~on_loan_q
        ).count(),
        "on_loan": Equipment.query.filter(on_loan_q).count(),
        "missing": Equipment.query.filter_by(status="missing").count(),
        "damaged": Equipment.query.filter_by(condition="damaged").count(),
    }


@dashboard_bp.get("/")
def index():
    stats = equipment_stats()
    stats["open_jobs"] = Job.query.filter_by(status="open").count()
    stats["open_loans"] = Loan.query.filter(Loan.status.in_(("active", "partial"))).count()
    overdue_q = services.overdue_loans_query()
    stats["overdue"] = overdue_q.count()

    return render_template(
        "dashboard/index.html",
        stats=stats,
        overdue_loans=overdue_q.order_by(Loan.due_date, Loan.id).limit(8).all(),
        due_soon=services.due_soon_loans(3),
        missing_equipment=Equipment.query.filter_by(status="missing")
        .order_by(Equipment.name)
        .limit(8)
        .all(),
        damaged_equipment=Equipment.query.filter_by(condition="damaged")
        .order_by(Equipment.name)
        .limit(8)
        .all(),
        open_jobs=Job.query.filter_by(status="open")
        .order_by(Job.date.desc(), Job.id.desc())
        .limit(6)
        .all(),
        activity=AuditLog.query.order_by(AuditLog.created_at.desc(), AuditLog.id.desc())
        .limit(8)
        .all(),
    )

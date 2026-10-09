from flask import flash, redirect, render_template, request, url_for
from sqlalchemy import func

from .. import services
from ..extensions import db
from ..models import Equipment, Job, Movement
from ..services import ServiceError
from ..utils import local_today
from . import dashboard_bp
from .common import apply_sort, audit_for, contains, paginate

SORT_COLUMNS = {
    "id": Job.id,
    "name": Job.name,
    "date": Job.date,
    "status": (Job.status, Job.date),
}


def _form_values(job=None):
    if request.method == "POST":
        return {k: request.form.get(k, "") for k in ("name", "date")}
    if job is not None:
        return {"name": job.name, "date": job.date.strftime("%Y-%m-%d")}
    return {"name": "", "date": local_today().isoformat()}


def _form_page(job, errors=None):
    return render_template(
        "dashboard/job_form.html", job=job, form=_form_values(job), errors=errors or []
    )


@dashboard_bp.get("/jobs")
def job_list():
    status = request.args.get("status", "")
    q = request.args.get("q", "").strip()
    query = Job.query
    if status in ("open", "closed"):
        query = query.filter_by(status=status)
    if q:
        query = query.filter(contains(Job.name, q))
    query, sort, direction = apply_sort(
        query, SORT_COLUMNS, "date", default_dir="desc", tiebreak=Job.id
    )
    page = paginate(query)

    counts = dict(db.session.query(Job.status, func.count()).group_by(Job.status).all())
    movement_counts = dict(
        db.session.query(Movement.job_id, func.count())
        .filter(Movement.job_id.in_([j.id for j in page.items] or [0]))
        .group_by(Movement.job_id)
        .all()
    )
    return render_template(
        "dashboard/jobs.html",
        page=page,
        items=page.items,
        status=status,
        q=q,
        sort=sort,
        dir=direction,
        counts={
            "all": sum(counts.values()),
            "open": counts.get("open", 0),
            "closed": counts.get("closed", 0),
        },
        movement_counts=movement_counts,
    )


@dashboard_bp.route("/jobs/new", methods=["GET", "POST"])
def job_create():
    if request.method == "GET":
        return _form_page(None)
    try:
        job = services.create_job(_form_values(), source="web")
    except ServiceError as err:
        return _form_page(None, err.messages), err.status
    flash(f"已建立 Job「{job.name}」({job.doc_no})", "success")
    return redirect(url_for("dashboard.job_detail", job_id=job.id))


@dashboard_bp.get("/jobs/<int:job_id>")
def job_detail(job_id):
    job = db.get_or_404(Job, job_id)
    out = job.latest_out_movement()
    expected_epcs = (out.epcs or []) if out else []
    by_epc = (
        {e.epc: e for e in Equipment.query.filter(Equipment.epc.in_(expected_epcs)).all()}
        if expected_epcs
        else {}
    )
    expected_items = [by_epc[e] for e in expected_epcs if e in by_epc]
    return render_template(
        "dashboard/job_detail.html",
        job=job,
        expected_items=expected_items,
        out_movement=out,
        movements=job.movements,
        audit=audit_for("job", job.id),
    )


@dashboard_bp.route("/jobs/<int:job_id>/edit", methods=["GET", "POST"])
def job_edit(job_id):
    job = db.get_or_404(Job, job_id)
    if request.method == "GET":
        return _form_page(job)
    try:
        _, changes = services.update_job(job, _form_values(), source="web")
    except ServiceError as err:
        db.session.rollback()
        return _form_page(job, err.messages), err.status
    flash("已儲存變更" if changes else "沒有任何變更", "success" if changes else "info")
    return redirect(url_for("dashboard.job_detail", job_id=job.id))


def _set_status(job_id, status, message):
    job = db.get_or_404(Job, job_id)
    try:
        services.set_job_status(job, status, source="web")
    except ServiceError as err:
        db.session.rollback()
        for m in err.messages:
            flash(m, "error")
    else:
        flash(message.format(name=job.name), "success")
    return redirect(url_for("dashboard.job_detail", job_id=job.id))


@dashboard_bp.post("/jobs/<int:job_id>/close")
def job_close(job_id):
    return _set_status(job_id, "closed", "Job「{name}」已結束")


@dashboard_bp.post("/jobs/<int:job_id>/reopen")
def job_reopen(job_id):
    return _set_status(job_id, "open", "Job「{name}」已重新開啟")


@dashboard_bp.post("/jobs/<int:job_id>/delete")
def job_delete(job_id):
    job = db.get_or_404(Job, job_id)
    try:
        label = services.delete_job(job, source="web")
    except ServiceError as err:
        db.session.rollback()
        for m in err.messages:
            flash(m, "error")
        return redirect(url_for("dashboard.job_detail", job_id=job_id))
    flash(f"已刪除 Job「{label}」", "success")
    return redirect(url_for("dashboard.job_list"))

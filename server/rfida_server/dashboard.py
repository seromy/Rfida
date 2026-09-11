from flask import Blueprint, flash, redirect, render_template, request, url_for

from .extensions import db
from .models import Equipment, InventorySession, Job, Movement, Staff, utcnow

dashboard_bp = Blueprint("dashboard", __name__, template_folder="templates")


@dashboard_bp.get("/")
def index():
    stats = {
        "total": Equipment.query.count(),
        "in_stock": Equipment.query.filter_by(status="in_stock").count(),
        "checked_out": Equipment.query.filter_by(status="checked_out").count(),
        "missing": Equipment.query.filter_by(status="missing").count(),
        "open_jobs": Job.query.filter_by(status="open").count(),
        "staff": Staff.query.count(),
    }
    recent_movements = (
        Movement.query.order_by(Movement.created_at.desc()).limit(6).all()
    )
    open_jobs = Job.query.filter_by(status="open").order_by(Job.date.desc()).all()
    missing_equipment = (
        Equipment.query.filter_by(status="missing").order_by(Equipment.name).all()
    )
    return render_template(
        "dashboard/index.html",
        stats=stats,
        recent_movements=recent_movements,
        open_jobs=open_jobs,
        missing_equipment=missing_equipment,
    )


@dashboard_bp.get("/equipment")
def equipment_list():
    query = Equipment.query
    q = request.args.get("q", "").strip()
    status = request.args.get("status", "")
    if q:
        like = f"%{q}%"
        query = query.filter(
            db.or_(
                Equipment.name.ilike(like),
                Equipment.epc.ilike(like),
                Equipment.serial_number.ilike(like),
                Equipment.category.ilike(like),
            )
        )
    if status:
        query = query.filter_by(status=status)
    items = query.order_by(Equipment.id.desc()).all()
    return render_template(
        "dashboard/equipment.html", items=items, q=q, status=status
    )


@dashboard_bp.post("/equipment")
def equipment_create():
    epc = request.form.get("epc", "").strip()
    name = request.form.get("name", "").strip()
    if not epc or not name:
        flash("EPC 同器材名稱為必填", "error")
        return redirect(url_for("dashboard.equipment_list"))

    if Equipment.query.filter_by(epc=epc).first():
        flash(f"EPC {epc} 已經登記咗", "error")
        return redirect(url_for("dashboard.equipment_list"))

    equipment = Equipment(
        epc=epc,
        name=name,
        category=request.form.get("category", "").strip(),
        serial_number=request.form.get("serialNumber", "").strip(),
        status="in_stock",
    )
    db.session.add(equipment)
    db.session.commit()
    flash(f"已登記器材「{equipment.name}」", "success")
    return redirect(url_for("dashboard.equipment_list"))


@dashboard_bp.post("/equipment/<int:equipment_id>/status")
def equipment_update_status(equipment_id):
    equipment = Equipment.query.get_or_404(equipment_id)
    new_status = request.form.get("status")
    if new_status in ("in_stock", "checked_out", "missing"):
        equipment.status = new_status
        equipment.last_seen_at = utcnow()
        db.session.commit()
        flash(f"「{equipment.name}」狀態已更新", "success")
    return redirect(url_for("dashboard.equipment_list"))


@dashboard_bp.post("/equipment/<int:equipment_id>/delete")
def equipment_delete(equipment_id):
    equipment = Equipment.query.get_or_404(equipment_id)
    db.session.delete(equipment)
    db.session.commit()
    flash(f"已刪除器材「{equipment.name}」", "success")
    return redirect(url_for("dashboard.equipment_list"))


@dashboard_bp.get("/staff")
def staff_list():
    items = Staff.query.order_by(Staff.id.desc()).all()
    return render_template("dashboard/staff.html", items=items)


@dashboard_bp.post("/staff")
def staff_create():
    name = request.form.get("name", "").strip()
    if not name:
        flash("員工姓名為必填", "error")
        return redirect(url_for("dashboard.staff_list"))
    db.session.add(Staff(name=name))
    db.session.commit()
    flash(f"已新增員工「{name}」", "success")
    return redirect(url_for("dashboard.staff_list"))


@dashboard_bp.post("/staff/<int:staff_id>/delete")
def staff_delete(staff_id):
    staff = Staff.query.get_or_404(staff_id)
    db.session.delete(staff)
    db.session.commit()
    flash(f"已刪除員工「{staff.name}」", "success")
    return redirect(url_for("dashboard.staff_list"))


@dashboard_bp.get("/jobs")
def job_list():
    status = request.args.get("status", "")
    query = Job.query
    if status:
        query = query.filter_by(status=status)
    items = query.order_by(Job.date.desc()).all()
    return render_template("dashboard/jobs.html", items=items, status=status)


@dashboard_bp.post("/jobs")
def job_create():
    name = request.form.get("name", "").strip()
    date_str = request.form.get("date", "").strip()
    if not name:
        flash("Job 名稱為必填", "error")
        return redirect(url_for("dashboard.job_list"))
    job = Job(name=name, status="open")
    if date_str:
        from datetime import datetime

        try:
            job.date = datetime.fromisoformat(date_str)
        except ValueError:
            pass
    db.session.add(job)
    db.session.commit()
    flash(f"已建立 Job「{job.name}」", "success")
    return redirect(url_for("dashboard.job_list"))


@dashboard_bp.get("/jobs/<int:job_id>")
def job_detail(job_id):
    job = Job.query.get_or_404(job_id)
    movement = job.latest_out_movement()
    expected_epcs = movement.epcs if movement else []
    expected_items = (
        Equipment.query.filter(Equipment.epc.in_(expected_epcs)).all()
        if expected_epcs
        else []
    )
    movements = (
        Movement.query.filter_by(job_id=job_id)
        .order_by(Movement.created_at.desc())
        .all()
    )
    return render_template(
        "dashboard/job_detail.html",
        job=job,
        expected_items=expected_items,
        movements=movements,
    )


@dashboard_bp.post("/jobs/<int:job_id>/close")
def job_close(job_id):
    job = Job.query.get_or_404(job_id)
    job.status = "closed"
    db.session.commit()
    flash(f"Job「{job.name}」已結束", "success")
    return redirect(url_for("dashboard.job_detail", job_id=job.id))


@dashboard_bp.post("/jobs/<int:job_id>/reopen")
def job_reopen(job_id):
    job = Job.query.get_or_404(job_id)
    job.status = "open"
    db.session.commit()
    flash(f"Job「{job.name}」已重新開啟", "success")
    return redirect(url_for("dashboard.job_detail", job_id=job.id))


@dashboard_bp.get("/movements")
def movement_list():
    items = Movement.query.order_by(Movement.created_at.desc()).all()
    return render_template("dashboard/movements.html", items=items)


@dashboard_bp.get("/inventory-sessions")
def inventory_session_list():
    items = (
        InventorySession.query.order_by(InventorySession.timestamp.desc()).all()
    )
    return render_template("dashboard/inventory_sessions.html", items=items)

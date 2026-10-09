from flask import render_template, request
from sqlalchemy.orm import selectinload

from ..models import AuditLog, Equipment
from . import dashboard_bp
from .common import contains, csv_response, local_day_range, paginate

ENTITY_TYPES = {
    "equipment": "器材",
    "company": "公司",
    "job": "Job",
    "loan": "借出單",
    "movement": "出入紀錄",
    "inventory": "盤點",
}
ACTIONS = {
    "create": "建立",
    "update": "更新",
    "delete": "刪除",
    "status": "狀態變更",
    "condition": "狀況變更",
    "loan_out": "借出",
    "loan_return": "歸還",
    "extend": "延期",
    "cancel": "取消",
    "return": "歸還",
}
SOURCES = {"web": "網頁", "handheld": "手提機", "api": "API"}


def stock_rows():
    """Per-category stock position, the 'stock overview' report."""
    items = Equipment.query.options(selectinload(Equipment.loan_items)).all()
    rows = {}
    for eq in items:
        cat = eq.category or "未分類"
        row = rows.setdefault(
            cat,
            {"category": cat, "total": 0, "in_stock": 0, "checked_out": 0, "on_loan": 0, "missing": 0, "damaged": 0, "available": 0},
        )
        row["total"] += 1
        if eq.is_damaged:
            row["damaged"] += 1
        if eq.on_loan:
            row["on_loan"] += 1
        elif eq.status == "checked_out":
            row["checked_out"] += 1
        elif eq.status == "missing":
            row["missing"] += 1
        else:
            row["in_stock"] += 1
            if not eq.is_damaged:
                row["available"] += 1
    ordered = sorted(rows.values(), key=lambda r: r["category"])
    total = {k: sum(r[k] for r in ordered) for k in ("total", "in_stock", "checked_out", "on_loan", "missing", "damaged", "available")}
    return ordered, total


@dashboard_bp.get("/reports/stock")
def report_stock():
    rows, total = stock_rows()
    return render_template("dashboard/report_stock.html", rows=rows, total=total)


@dashboard_bp.get("/reports/stock.csv")
def report_stock_export():
    rows, total = stock_rows()
    header = ["分類", "總數", "在庫", "可借出", "已出Job", "借出中", "遺失", "損壞"]
    body = [[r["category"], r["total"], r["in_stock"], r["available"], r["checked_out"], r["on_loan"], r["missing"], r["damaged"]] for r in rows]
    body.append(["合計", total["total"], total["in_stock"], total["available"], total["checked_out"], total["on_loan"], total["missing"], total["damaged"]])
    return csv_response("stock-overview.csv", header, body)


@dashboard_bp.get("/reports/changes")
def report_changes():
    args = request.args
    q = args.get("q", "").strip()
    entity = args.get("entity", "")
    action = args.get("action", "")
    source = args.get("source", "")
    date_from, date_to = args.get("date_from", ""), args.get("date_to", "")

    query = AuditLog.query
    if entity in ENTITY_TYPES:
        query = query.filter(AuditLog.entity_type == entity)
    if action in ACTIONS:
        query = query.filter(AuditLog.action == action)
    if source in SOURCES:
        query = query.filter(AuditLog.source == source)
    start, end = local_day_range(date_from, date_to)
    if start:
        query = query.filter(AuditLog.created_at >= start)
    if end:
        query = query.filter(AuditLog.created_at < end)
    if q:
        query = query.filter(
            (contains(AuditLog.summary, q)) | (contains(AuditLog.entity_label, q))
        )
    query = query.order_by(AuditLog.created_at.desc(), AuditLog.id.desc())
    page = paginate(query, per_page=30)
    return render_template(
        "dashboard/report_changes.html",
        page=page,
        items=page.items,
        q=q,
        entity=entity,
        action=action,
        source=source,
        date_from=date_from,
        date_to=date_to,
        entity_types=ENTITY_TYPES,
        actions=ACTIONS,
        sources=SOURCES,
    )

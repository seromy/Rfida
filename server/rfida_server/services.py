"""Business rules shared by the REST API (handheld) and the web dashboard.

Every state transition lives here so both entry points enforce the same rules and
write the same change documents (AuditLog). Functions commit on success and raise
`ServiceError` (nothing persisted) on a rule violation.
"""

from datetime import datetime, timedelta

from sqlalchemy import func
from sqlalchemy.exc import IntegrityError

from .extensions import db
from .models import (
    AuditLog,
    Company,
    Equipment,
    InventorySession,
    Job,
    Loan,
    LoanItem,
    Movement,
    RETURN_CONDITIONS,
    VALID_DIRECTIONS,
    VALID_EQUIPMENT_STATUS,
)
from .utils import (
    local_today,
    EPC_MAX_LENGTH,
    normalize_epc,
    normalize_epc_list,
    parse_date,
    parse_iso_datetime,
    to_int,
    utcnow_naive,
)

STATUS_LABELS = {"in_stock": "在庫", "checked_out": "已出Job", "missing": "遺失"}
CONDITION_LABELS = {"good": "正常", "damaged": "損壞", "lost": "遺失"}
DIRECTION_LABELS = {"out": "出Job", "in": "歸還"}
LOAN_STATUS_LABELS = {
    "active": "借出中",
    "partial": "部分歸還",
    "returned": "已歸還",
    "cancelled": "已取消",
    "overdue": "已逾期",
}
FIELD_LABELS = {
    "epc": "EPC",
    "name": "名稱",
    "category": "分類",
    "serial_number": "序號",
    "location": "存放位置",
    "note": "備註",
    "contact_name": "聯絡人",
    "phone": "電話",
    "email": "電郵",
    "date": "日期",
    "due_date": "到期日",
}

_MAX = {
    "epc": EPC_MAX_LENGTH,
    "name": 200,
    "category": 100,
    "serial_number": 100,
    "location": 100,
    "contact_name": 100,
    "phone": 50,
    "email": 120,
    "borrower_name": 200,
    "contact": 200,
    "purpose": 200,
    "handled_by": 100,
    "batch_label": 100,
    "return_note": 300,
}
NOTE_MAX = 2000


class ServiceError(Exception):
    def __init__(self, messages, status=400):
        if isinstance(messages, str):
            messages = [messages]
        self.messages = list(messages)
        self.status = status
        super().__init__("; ".join(self.messages))


# ------------------------------------------------------------------ plumbing


def commit():
    try:
        db.session.commit()
    except IntegrityError:
        db.session.rollback()
        raise ServiceError("資料重複或已被其他操作更改,請重新整理後再試。", 409)


def _clean(value):
    return value.strip() if isinstance(value, str) else ("" if value is None else str(value).strip())


def _check_lengths(values, errors):
    for key, value in values.items():
        limit = NOTE_MAX if key == "note" else _MAX.get(key)
        if limit and len(value) > limit:
            errors.append(f"「{FIELD_LABELS.get(key, key)}」最多 {limit} 個字元。")


def label_of(entity_type, entity):
    if entity is None:
        return ""
    if entity_type in ("equipment", "company", "job"):
        return entity.name
    if entity_type == "loan":
        return f"{entity.doc_no} {entity.borrower_display}"
    return entity.doc_no


def audit(entity_type, entity, action, summary, *, source="web", changes=None, entity_id=None, label=None):
    """Queue a change document. `entity` must already have an id (flush first)."""
    entry = AuditLog(
        entity_type=entity_type,
        entity_id=entity.id if entity is not None else entity_id,
        entity_label=(label if label is not None else label_of(entity_type, entity))[:200],
        action=action,
        summary=summary,
        changes=changes,
        source=source,
    )
    db.session.add(entry)
    return entry


def _diff(obj, new_values):
    """Apply `new_values` to `obj`; return {field: [old, new]} for what changed."""
    changes = {}
    for key, new in new_values.items():
        old = getattr(obj, key)
        if old != new:
            changes[key] = [old, new]
            setattr(obj, key, new)
    return changes


def _change_summary(changes):
    return "更新:" + "、".join(FIELD_LABELS.get(k, k) for k in changes)


# ------------------------------------------------------------------ equipment


def open_loan_map(equipment_ids=None):
    """{equipment_id: LoanItem} for every item currently out on loan."""
    query = LoanItem.query.filter(LoanItem.state == "out")
    if equipment_ids is not None:
        if not equipment_ids:
            return {}
        query = query.filter(LoanItem.equipment_id.in_(equipment_ids))
    return {item.equipment_id: item for item in query.all()}


def _equipment_fields(data, errors, *, require_epc=True):
    fields = {
        "name": _clean(data.get("name")),
        "category": _clean(data.get("category")),
        "serial_number": _clean(data.get("serial_number")),
        "location": _clean(data.get("location")),
        "note": _clean(data.get("note")),
    }
    if not fields["name"]:
        errors.append("器材名稱為必填。")
    _check_lengths(fields, errors)
    epc = None
    if require_epc:
        raw = data.get("epc")
        epc = normalize_epc(raw)
        if epc is None:
            errors.append(
                "EPC 為必填。"
                if not _clean(raw)
                else f"EPC「{_clean(raw)[:40]}」格式不正確(只可以用英數字同 - _ : . 符號,最多 {EPC_MAX_LENGTH} 個字元)。"
            )
    return epc, fields


def create_equipment(data, *, source="web"):
    errors = []
    epc, fields = _equipment_fields(data, errors)
    if epc and Equipment.query.filter_by(epc=epc).first():
        raise ServiceError(f"EPC {epc} 已經登記咗。", 409)
    if errors:
        raise ServiceError(errors)

    equipment = Equipment(epc=epc, status="in_stock", **fields)
    db.session.add(equipment)
    db.session.flush()
    audit("equipment", equipment, "create", f"登記器材 EPC {epc}", source=source)
    commit()
    return equipment


def update_equipment(equipment, data, *, source="web"):
    errors = []
    epc, fields = _equipment_fields(data, errors)
    if epc and epc != equipment.epc:
        clash = Equipment.query.filter(Equipment.epc == epc, Equipment.id != equipment.id).first()
        if clash:
            errors.append(f"EPC {epc} 已經登記喺「{clash.name}」。")
    if errors:
        raise ServiceError(errors)

    changes = _diff(equipment, {"epc": epc, **fields})
    if changes:
        audit("equipment", equipment, "update", _change_summary(changes), source=source, changes=changes)
        commit()
    return equipment, changes


def set_equipment_status(
    equipment, new_status, *, reason="", source="web", seen_at=None, log=True
):
    """Single choke point for status changes. Returns True when it changed.

    `log=False` lets callers that write their own, richer change document (loan
    out / return) avoid a duplicate entry.
    """
    if new_status not in VALID_EQUIPMENT_STATUS:
        raise ServiceError(f"不正確嘅狀態:{new_status}")
    if seen_at is not None:
        equipment.last_seen_at = seen_at
    old = equipment.status
    if old == new_status:
        return False
    equipment.status = new_status
    if log:
        suffix = f"({reason})" if reason else ""
        audit(
            "equipment",
            equipment,
            "status",
            f"狀態 {STATUS_LABELS[old]} → {STATUS_LABELS[new_status]}{suffix}",
            source=source,
            changes={"status": [old, new_status]},
        )
    return True


def change_equipment_status(equipment, new_status, *, reason="", source="web"):
    if equipment.on_loan and new_status != "checked_out":
        item = equipment.open_loan_item
        raise ServiceError(
            f"「{equipment.name}」喺借出單 {item.loan.doc_no} 借出中,請先辦理歸還。"
        )
    if set_equipment_status(equipment, new_status, reason=reason or "手動變更", source=source, seen_at=utcnow_naive()):
        commit()
        return True
    return False


def set_equipment_condition(equipment, condition, *, reason="", source="web"):
    if condition not in ("good", "damaged"):
        raise ServiceError("不正確嘅器材狀況。")
    if equipment.condition == condition:
        return False
    old = equipment.condition
    equipment.condition = condition
    audit(
        "equipment",
        equipment,
        "condition",
        f"狀況 {CONDITION_LABELS[old]} → {CONDITION_LABELS[condition]}" + (f"({reason})" if reason else ""),
        source=source,
        changes={"condition": [old, condition]},
    )
    return True


def delete_equipment(equipment, *, source="web"):
    if LoanItem.query.filter_by(equipment_id=equipment.id).first():
        raise ServiceError(
            f"「{equipment.name}」有借出紀錄,不可刪除(保留紀錄完整性)。如已報廢,請標記為遺失。"
        )
    label, eq_id, epc = equipment.name, equipment.id, equipment.epc
    audit("equipment", None, "delete", f"刪除器材 EPC {epc}", source=source, entity_id=eq_id, label=label)
    db.session.delete(equipment)
    commit()
    return label


# ------------------------------------------------------------------ company


def _company_fields(data, errors):
    fields = {
        "name": _clean(data.get("name")),
        "contact_name": _clean(data.get("contact_name")),
        "phone": _clean(data.get("phone")),
        "email": _clean(data.get("email")),
        "note": _clean(data.get("note")),
    }
    if not fields["name"]:
        errors.append("公司名稱為必填。")
    _check_lengths(fields, errors)
    if fields["email"] and ("@" not in fields["email"] or " " in fields["email"]):
        errors.append("電郵格式不正確。")
    return fields


def create_company(data, *, source="web"):
    errors = []
    fields = _company_fields(data, errors)
    if not errors and Company.query.filter(func.lower(Company.name) == fields["name"].lower()).first():
        errors.append(f"公司「{fields['name']}」已經存在。")
    if errors:
        raise ServiceError(errors)
    company = Company(**fields)
    db.session.add(company)
    db.session.flush()
    audit("company", company, "create", "新增公司", source=source)
    commit()
    return company


def update_company(company, data, *, source="web"):
    errors = []
    fields = _company_fields(data, errors)
    if not errors:
        clash = Company.query.filter(
            func.lower(Company.name) == fields["name"].lower(), Company.id != company.id
        ).first()
        if clash:
            errors.append(f"公司「{fields['name']}」已經存在。")
    if errors:
        raise ServiceError(errors)
    changes = _diff(company, fields)
    if changes:
        audit("company", company, "update", _change_summary(changes), source=source, changes=changes)
        commit()
    return company, changes


def company_usage(company):
    return {
        "loans": Loan.query.filter_by(company_id=company.id).count(),
        "movements": Movement.query.filter_by(company_id=company.id).count(),
        "inventory": InventorySession.query.filter_by(company_id=company.id).count(),
    }


def delete_company(company, *, source="web"):
    usage = company_usage(company)
    if any(usage.values()):
        raise ServiceError(
            f"「{company.name}」已有紀錄(借出單 {usage['loans']}、出入紀錄 {usage['movements']}、"
            f"盤點 {usage['inventory']}),不可刪除。"
        )
    label, cid = company.name, company.id
    audit("company", None, "delete", "刪除公司", source=source, entity_id=cid, label=label)
    db.session.delete(company)
    commit()
    return label


# ------------------------------------------------------------------ jobs


def _job_fields(data, errors):
    name = _clean(data.get("name"))
    if not name:
        errors.append("Job 名稱為必填。")
    elif len(name) > _MAX["name"]:
        errors.append(f"「名稱」最多 {_MAX['name']} 個字元。")
    raw_date = _clean(data.get("date"))
    try:
        day = parse_date(raw_date) if raw_date else local_today()
    except ValueError:
        errors.append(f"日期「{raw_date}」格式不正確,請用 YYYY-MM-DD。")
        day = None
    return name, (datetime(day.year, day.month, day.day) if day else None)


def create_job(data, *, source="web"):
    errors = []
    name, when = _job_fields(data, errors)
    if errors:
        raise ServiceError(errors)
    job = Job(name=name, date=when, status="open")
    db.session.add(job)
    db.session.flush()
    audit("job", job, "create", "建立 Job", source=source)
    commit()
    return job


def update_job(job, data, *, source="web"):
    errors = []
    name, when = _job_fields(data, errors)
    if errors:
        raise ServiceError(errors)
    changes = _diff(job, {"name": name, "date": when})
    if changes:
        # datetimes are not JSON serialisable
        shown = {k: [str(a), str(b)] if k == "date" else [a, b] for k, (a, b) in changes.items()}
        audit("job", job, "update", _change_summary(changes), source=source, changes=shown)
        commit()
    return job, changes


def set_job_status(job, status, *, source="web"):
    if status not in ("open", "closed"):
        raise ServiceError("不正確嘅 Job 狀態。")
    if job.status == status:
        return False
    old = job.status
    job.status = status
    audit(
        "job",
        job,
        "status",
        "結束 Job" if status == "closed" else "重新開啟 Job",
        source=source,
        changes={"status": [old, status]},
    )
    commit()
    return True


def delete_job(job, *, source="web"):
    if job.movements:
        raise ServiceError(f"Job「{job.name}」已有 {len(job.movements)} 筆出入紀錄,不可刪除。")
    label, jid = job.name, job.id
    audit("job", None, "delete", "刪除 Job", source=source, entity_id=jid, label=label)
    db.session.delete(job)
    commit()
    return label


# ------------------------------------------------------------------ movements


def _ensure_ref(model, ref_id, what):
    if ref_id is None:
        return None
    obj = db.session.get(model, ref_id)
    if obj is None:
        raise ServiceError(f"找不到{what} (id={ref_id})。", 400)
    return obj


def record_movement(
    *, direction, epcs, missing_epcs=None, job_id=None, company_id=None, note=None, source="handheld"
):
    if direction not in VALID_DIRECTIONS:
        raise ServiceError("direction must be 'out' or 'in'")
    try:
        epcs, bad = normalize_epc_list(epcs)
        missing, bad_missing = normalize_epc_list(missing_epcs)
    except ValueError:
        raise ServiceError("epcs / missingEpcs must be arrays of strings")
    if bad or bad_missing:
        raise ServiceError(f"EPC 格式不正確:{', '.join((bad + bad_missing)[:5])}")
    if missing_epcs is not None and direction == "out":
        missing = []
    # An EPC that was scanned is by definition not missing.
    missing = [e for e in missing if e not in set(epcs)]

    job = _ensure_ref(Job, job_id, "Job")
    company = _ensure_ref(Company, company_id, "公司")
    note = _clean(note)
    if len(note) > NOTE_MAX:
        raise ServiceError(f"備註最多 {NOTE_MAX} 個字元。")

    movement = Movement(
        job_id=job.id if job else None,
        company_id=company.id if company else None,
        direction=direction,
        epcs=epcs,
        missing_epcs=(missing if missing_epcs is not None and direction == "in" else None),
        note=note or None,
    )
    db.session.add(movement)

    now = utcnow_naive()
    known = {e.epc: e for e in Equipment.query.filter(Equipment.epc.in_(epcs + missing)).all()}
    loans = open_loan_map([e.id for e in known.values()])

    db.session.flush()
    reason = f"出入紀錄 {movement.doc_no}"
    for epc in epcs:
        eq = known.get(epc)
        if eq is None:
            continue
        if direction == "out":
            set_equipment_status(eq, "checked_out", reason=reason, source=source, seen_at=now)
        elif eq.id in loans:
            # Back from a job, but still lent to a borrower: stays out of stock.
            eq.last_seen_at = now
        else:
            set_equipment_status(eq, "in_stock", reason=reason, source=source, seen_at=now)
    for epc in missing:
        eq = known.get(epc)
        if eq is not None:
            set_equipment_status(eq, "missing", reason=reason, source=source)

    unknown = [e for e in epcs + missing if e not in known]
    audit(
        "movement",
        movement,
        "create",
        f"{DIRECTION_LABELS[direction]} {len(epcs)} 件"
        + (f",缺件 {len(missing)} 件" if missing else "")
        + (f",Job「{job.name}」" if job else ""),
        source=source,
    )
    commit()
    return movement, unknown


def record_inventory(*, company_id=None, batch_label="", scanned_epcs=None, timestamp=None, source="handheld"):
    try:
        scanned, bad = normalize_epc_list(scanned_epcs)
    except ValueError:
        raise ServiceError("scannedEpcs must be an array of strings")
    if bad:
        raise ServiceError(f"EPC 格式不正確:{', '.join(bad[:5])}")
    company = _ensure_ref(Company, company_id, "公司")
    batch_label = _clean(batch_label)
    if len(batch_label) > _MAX["batch_label"]:
        raise ServiceError(f"批次名稱最多 {_MAX['batch_label']} 個字元。")
    timestamp = timestamp or utcnow_naive()

    known = {e.epc: e for e in Equipment.query.filter(Equipment.epc.in_(scanned)).all()}
    loans = open_loan_map([e.id for e in known.values()])
    unknown = [e for e in scanned if e not in known]

    session = InventorySession(
        company_id=company.id if company else None,
        batch_label=batch_label,
        scanned_epcs=scanned,
        unknown_epcs=unknown,
        timestamp=timestamp,
    )
    db.session.add(session)
    db.session.flush()
    reason = f"盤點 {session.doc_no}"
    for eq in known.values():
        eq.last_seen_at = timestamp
        if eq.status == "missing":
            # Found again: back in stock, or still out if it is lent to someone.
            set_equipment_status(eq, "checked_out" if eq.id in loans else "in_stock", reason=reason, source=source)
    audit(
        "inventory",
        session,
        "create",
        f"盤點 {len(scanned)} 件,未知標籤 {len(unknown)} 個"
        + (f",批次「{batch_label}」" if batch_label else ""),
        source=source,
    )
    commit()
    return session


# ------------------------------------------------------------------ loans


def refresh_loan_status(loan, now=None):
    if loan.status == "cancelled":
        return
    now = now or utcnow_naive()
    states = [i.state for i in loan.items]
    if any(s == "out" for s in states):
        loan.status = "partial" if any(s == "returned" for s in states) else "active"
        loan.returned_at = None
    else:
        loan.status = "returned"
        times = [i.returned_at for i in loan.items if i.returned_at]
        loan.returned_at = max(times) if times else now


def loanability(equipment, loans=None):
    """Return None when the item can be lent, otherwise a human reason."""
    open_item = (loans or {}).get(equipment.id) if loans is not None else equipment.open_loan_item
    if open_item is not None:
        return f"已借出({open_item.loan.doc_no})"
    if equipment.status == "checked_out":
        return "已出Job"
    if equipment.status == "missing":
        return "遺失"
    if equipment.condition == "damaged":
        return "損壞待修"
    return None


def create_loan(data, *, equipment_ids=None, epcs=None, source="web"):
    errors = []
    company_id = to_int(data.get("company_id"))
    company = db.session.get(Company, company_id) if company_id is not None else None
    if _clean(data.get("company_id")) and company is None:
        errors.append("找不到所選公司。")

    fields = {
        "borrower_name": _clean(data.get("borrower_name")),
        "contact": _clean(data.get("contact")),
        "purpose": _clean(data.get("purpose")),
        "handled_by": _clean(data.get("handled_by")),
        "note": _clean(data.get("note")),
    }
    _check_lengths(fields, errors)
    if not fields["borrower_name"] and company is None:
        errors.append("請揀選公司或者填寫借用人。")
    if company is not None and not fields["contact"]:
        fields["contact"] = " / ".join(p for p in (company.phone, company.email) if p)

    today = local_today()
    try:
        due = parse_date(_clean(data.get("due_date")))
    except ValueError:
        due = None
        errors.append("到期日格式不正確,請用 YYYY-MM-DD。")
    else:
        if due is None:
            errors.append("到期日為必填。")
        elif due < today:
            errors.append("到期日不可以早過今日。")

    try:
        loan_date = _parse_loan_date(data.get("loan_date"))
    except ValueError:
        loan_date = utcnow_naive()
        errors.append("借出日期格式不正確。")

    # Resolve the equipment to lend: ids (web picker) and/or EPCs (paste box / API).
    selected = {}
    for eq_id in equipment_ids or []:
        eq = db.session.get(Equipment, to_int(eq_id)) if to_int(eq_id) is not None else None
        if eq is None:
            errors.append(f"找不到器材 (id={eq_id})。")
        else:
            selected[eq.id] = eq
    if epcs:
        try:
            clean, bad = normalize_epc_list(epcs)
        except ValueError:
            clean, bad = [], []
            errors.append("epcs 必須係字串陣列。")
        if bad:
            errors.append(f"EPC 格式不正確:{', '.join(bad[:5])}")
        found = {e.epc: e for e in Equipment.query.filter(Equipment.epc.in_(clean)).all()} if clean else {}
        unknown = [e for e in clean if e not in found]
        if unknown:
            errors.append(f"未登記嘅 EPC:{', '.join(unknown[:5])}" + ("…" if len(unknown) > 5 else ""))
        for eq in found.values():
            selected[eq.id] = eq
    if not selected and not errors:
        errors.append("請至少揀選一件器材。")

    loans = open_loan_map(list(selected))
    for eq in selected.values():
        reason = loanability(eq, loans)
        if reason:
            errors.append(f"「{eq.name}」({eq.epc[-6:]}){reason},不可借出。")
    if errors:
        raise ServiceError(errors)

    loan = Loan(
        company_id=company.id if company else None,
        loan_date=loan_date,
        due_date=due,
        status="active",
        **fields,
    )
    for eq in selected.values():
        loan.items.append(LoanItem(equipment=eq, state="out"))
    db.session.add(loan)
    db.session.flush()

    now = utcnow_naive()
    for eq in selected.values():
        old = eq.status
        set_equipment_status(eq, "checked_out", source=source, seen_at=now, log=False)
        audit(
            "equipment",
            eq,
            "loan_out",
            f"借出予 {loan.borrower_display}({loan.doc_no}),到期 {due.isoformat()}",
            source=source,
            changes={"status": [old, "checked_out"]} if old != "checked_out" else None,
        )
    audit(
        "loan",
        loan,
        "create",
        f"建立借出單:{len(selected)} 件,到期 {due.isoformat()}",
        source=source,
    )
    commit()
    return loan


def _parse_loan_date(value):
    if value in (None, ""):
        return utcnow_naive()
    return parse_iso_datetime(value) or utcnow_naive()


def return_loan_items(loan, returns, *, note="", source="web"):
    """`returns`: iterable of {item_id, condition, note}. Marks items back in."""
    if loan.status == "cancelled":
        raise ServiceError("借出單已取消,不能辦理歸還。")
    returns = list(returns)
    if not returns:
        raise ServiceError("請至少揀選一件要歸還嘅器材。")

    by_id = {i.id: i for i in loan.items}
    errors, plan = [], []
    for entry in returns:
        item = by_id.get(to_int(entry.get("item_id")))
        condition = entry.get("condition") or "good"
        if item is None:
            errors.append("揀選咗不屬於此借出單嘅項目。")
        elif item.state != "out":
            errors.append(f"「{item.equipment.name}」已經歸還。")
        elif condition not in RETURN_CONDITIONS:
            errors.append(f"「{item.equipment.name}」嘅歸還狀況不正確。")
        else:
            plan.append((item, condition, _clean(entry.get("note"))[: _MAX["return_note"]]))
    if errors:
        raise ServiceError(errors)

    now = utcnow_naive()
    counts = {"good": 0, "damaged": 0, "lost": 0}
    for item, condition, item_note in plan:
        eq = item.equipment
        item.state = "returned"
        item.returned_at = now
        item.return_condition = condition
        item.return_note = item_note
        counts[condition] += 1
        old = eq.status
        if condition == "lost":
            set_equipment_status(eq, "missing", source=source, log=False)
        else:
            set_equipment_status(eq, "in_stock", source=source, seen_at=now, log=False)
            if condition == "damaged":
                set_equipment_condition(eq, "damaged", reason=item_note or f"借出單 {loan.doc_no}", source=source)
        audit(
            "equipment",
            eq,
            "loan_return",
            f"{loan.borrower_display} 歸還({loan.doc_no}),狀況:{CONDITION_LABELS[condition]}"
            + (f"。{item_note}" if item_note else ""),
            source=source,
            changes={"status": [old, eq.status]} if old != eq.status else None,
        )

    db.session.flush()
    refresh_loan_status(loan, now)
    parts = [f"歸還 {len(plan)} 件"]
    if counts["damaged"]:
        parts.append(f"損壞 {counts['damaged']}")
    if counts["lost"]:
        parts.append(f"遺失 {counts['lost']}")
    if loan.status == "returned":
        parts.append("借出單已完結")
    audit("loan", loan, "return", "、".join(parts) + (f"。{_clean(note)}" if _clean(note) else ""), source=source)
    commit()
    return loan


def return_all_good(loan, *, source="web"):
    return return_loan_items(
        loan,
        [{"item_id": i.id, "condition": "good"} for i in loan.outstanding_items],
        source=source,
    )


def extend_loan(loan, new_due, *, reason="", source="web"):
    if not loan.is_open:
        raise ServiceError("只有借出中嘅借出單可以延期。")
    try:
        new_due = parse_date(new_due)
    except ValueError:
        raise ServiceError("到期日格式不正確,請用 YYYY-MM-DD。")
    if new_due is None:
        raise ServiceError("請輸入新嘅到期日。")
    if new_due < local_today():
        raise ServiceError("新嘅到期日不可以早過今日。")
    if new_due == loan.due_date:
        raise ServiceError("新嘅到期日同現有到期日一樣。")
    old = loan.due_date
    loan.due_date = new_due
    reason = _clean(reason)
    audit(
        "loan",
        loan,
        "extend",
        f"到期日 {old.isoformat()} → {new_due.isoformat()}" + (f"({reason})" if reason else ""),
        source=source,
        changes={"due_date": [old.isoformat(), new_due.isoformat()]},
    )
    commit()
    return loan


def cancel_loan(loan, *, reason="", source="web"):
    if loan.status != "active" or any(i.state == "returned" for i in loan.items):
        raise ServiceError("只有未有任何歸還嘅借出單可以取消。")
    reason = _clean(reason)
    for item in loan.items:
        item.state = "cancelled"
        eq = item.equipment
        if eq.status == "checked_out":
            set_equipment_status(eq, "in_stock", reason=f"取消借出單 {loan.doc_no}", source=source)
    loan.status = "cancelled"
    audit("loan", loan, "cancel", "取消借出單" + (f":{reason}" if reason else ""), source=source)
    commit()
    return loan


def update_loan_details(loan, data, *, source="web"):
    """Edit header text fields of an open loan (borrower contact, purpose, note)."""
    errors = []
    fields = {
        "borrower_name": _clean(data.get("borrower_name")),
        "contact": _clean(data.get("contact")),
        "purpose": _clean(data.get("purpose")),
        "handled_by": _clean(data.get("handled_by")),
        "note": _clean(data.get("note")),
    }
    _check_lengths(fields, errors)
    if not fields["borrower_name"] and loan.company_id is None:
        errors.append("請填寫借用人。")
    if errors:
        raise ServiceError(errors)
    changes = _diff(loan, fields)
    if changes:
        labels = {**FIELD_LABELS, "borrower_name": "借用人", "contact": "聯絡方式", "purpose": "用途", "handled_by": "經手人"}
        audit(
            "loan",
            loan,
            "update",
            "更新:" + "、".join(labels.get(k, k) for k in changes),
            source=source,
            changes=changes,
        )
        commit()
    return loan, changes


def overdue_loans_query():
    return Loan.query.filter(Loan.status.in_(("active", "partial")), Loan.due_date < local_today())


def due_soon_loans(days=3):
    today = local_today()
    return (
        Loan.query.filter(
            Loan.status.in_(("active", "partial")),
            Loan.due_date >= today,
            Loan.due_date <= today + timedelta(days=days),
        )
        .order_by(Loan.due_date, Loan.id)
        .all()
    )

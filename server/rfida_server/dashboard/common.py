import csv
import io

from flask import Response, request

from ..utils import csv_safe, to_int

PER_PAGE = 20


def like_escape(text):
    """Escape LIKE wildcards so user input is matched literally (use escape='\\')."""
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def contains(column, text):
    return column.ilike(f"%{like_escape(text)}%", escape="\\")


def paginate(query, per_page=PER_PAGE):
    page = max(1, to_int(request.args.get("page")) or 1)
    return query.paginate(page=page, per_page=per_page, error_out=False)


def apply_sort(query, columns, default, default_dir="asc", tiebreak=None):
    """Whitelisted ORDER BY from ?sort=&dir=. Returns (query, sort_key, sort_dir)."""
    key = request.args.get("sort")
    direction = request.args.get("dir")
    if key not in columns:
        key, direction = default, default_dir
    elif direction not in ("asc", "desc"):
        direction = "asc"
    cols = columns[key]
    cols = cols if isinstance(cols, (list, tuple)) else (cols,)
    clauses = [c.asc() if direction == "asc" else c.desc() for c in cols]
    if tiebreak is not None:
        clauses.append(tiebreak.desc())
    return query.order_by(*clauses), key, direction


def csv_response(filename, header, rows):
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(header)
    for row in rows:
        writer.writerow([csv_safe(cell) for cell in row])
    # BOM so Excel opens Chinese text as UTF-8.
    body = "﻿" + buffer.getvalue()
    return Response(
        body,
        mimetype="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


def movements_containing(epc, limit=50):
    """Movements whose scanned or missing EPC list holds this exact EPC."""
    from sqlalchemy import String, cast, or_

    from ..models import Movement

    pattern = f'%"{like_escape(epc)}"%'
    return (
        Movement.query.filter(
            or_(
                cast(Movement.epcs, String).like(pattern, escape="\\"),
                cast(Movement.missing_epcs, String).like(pattern, escape="\\"),
            )
        )
        .order_by(Movement.created_at.desc(), Movement.id.desc())
        .limit(limit)
        .all()
    )


def audit_for(entity_type, entity_id, limit=100):
    from ..models import AuditLog

    return (
        AuditLog.query.filter_by(entity_type=entity_type, entity_id=entity_id)
        .order_by(AuditLog.created_at.desc(), AuditLog.id.desc())
        .limit(limit)
        .all()
    )


def local_day_range(date_from, date_to):
    """Local calendar dates (YYYY-MM-DD strings) -> naive-UTC [start, end) bounds."""
    from datetime import datetime, time, timedelta, timezone

    from ..utils import local_tz, parse_date

    def bound(text, add_days):
        try:
            day = parse_date(text)
        except ValueError:
            return None
        if day is None:
            return None
        local = datetime.combine(day + timedelta(days=add_days), time.min, tzinfo=local_tz())
        return local.astimezone(timezone.utc).replace(tzinfo=None)

    return bound(date_from, 0), bound(date_to, 1)

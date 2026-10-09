"""Small, dependency-free helpers shared by the API, services and dashboard."""

import re
from datetime import date, datetime, timedelta, timezone

from flask import current_app

DEFAULT_TIMEZONE = "Asia/Hong_Kong"
EPC_MAX_LENGTH = 128  # BLE protocol: up to 64 bytes = 128 hex chars
_EPC_ALLOWED = re.compile(r"^[A-Za-z0-9_\-:.]+$")


def utcnow():
    """Naive-UTC would be a footgun, so callers get an aware datetime."""
    return datetime.now(timezone.utc)


def utcnow_naive():
    """Column default: the database stores naive UTC."""
    return utcnow().replace(tzinfo=None)


def iso(dt):
    """Serialise a stored (naive UTC) datetime the way the iOS app decodes it."""
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_date(d):
    return d.isoformat() if d else None


# ---------------------------------------------------------------- time zones


def local_tz():
    name = current_app.config.get("APP_TIMEZONE", DEFAULT_TIMEZONE)
    try:
        from zoneinfo import ZoneInfo

        return ZoneInfo(name)
    except Exception:  # missing tzdata: fall back to Hong Kong's fixed offset
        return timezone(timedelta(hours=8))


def to_local(dt):
    """Stored naive-UTC datetime -> aware datetime in the office time zone."""
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(local_tz())


def local_today():
    return utcnow().astimezone(local_tz()).date()


# ------------------------------------------------------------------- parsing


def parse_iso_datetime(value):
    """ISO-8601 string -> naive UTC datetime. Raises ValueError when malformed."""
    if value is None or value == "":
        return None
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    dt = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).replace(tzinfo=None)


def parse_date(value):
    """'YYYY-MM-DD' (or a full ISO timestamp) -> date. Raises ValueError."""
    if value is None or value == "":
        return None
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    if not isinstance(value, str):
        raise ValueError("date must be a string")
    return date.fromisoformat(value.strip()[:10])


def to_int(value):
    """Lenient int parse for ids coming from JSON or forms. None when absent/invalid."""
    if value is None or value == "" or isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


# ----------------------------------------------------------------------- EPC


def normalize_epc(value):
    """Canonical EPC form: trimmed, upper-case. None when it is not a usable EPC."""
    if not isinstance(value, str):
        return None
    epc = value.strip().upper()
    if not epc or len(epc) > EPC_MAX_LENGTH or not _EPC_ALLOWED.match(epc):
        return None
    return epc


def normalize_epc_list(values):
    """Return (clean, invalid): de-duplicated canonical EPCs in input order."""
    if values is None:
        return [], []
    if not isinstance(values, (list, tuple)):
        raise ValueError("EPC list must be an array")
    clean, invalid, seen = [], [], set()
    for raw in values:
        epc = normalize_epc(raw)
        if epc is None:
            invalid.append(raw if isinstance(raw, str) else repr(raw))
        elif epc not in seen:
            seen.add(epc)
            clean.append(epc)
    return clean, invalid


def split_epc_text(text):
    """Free text (paste box / scanner dump) -> raw EPC tokens."""
    return [t for t in re.split(r"[\s,;]+", text or "") if t]


# ----------------------------------------------------------------------- CSV


def csv_safe(value):
    """Neutralise spreadsheet formula injection (=, +, -, @ at the start of a cell)."""
    if value is None:
        return ""
    text = str(value)
    if text and text[0] in ("=", "+", "-", "@", "\t", "\r"):
        return "'" + text
    return text

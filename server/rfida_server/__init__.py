import hmac
import os
import secrets
import sqlite3
from datetime import timezone

from flask import Flask, abort, jsonify, render_template, request, session, url_for
from sqlalchemy import event
from sqlalchemy.engine import Engine
from werkzeug.exceptions import HTTPException

from .extensions import db
from .utils import DEFAULT_TIMEZONE, local_tz, to_local, utcnow


@event.listens_for(Engine, "connect")
def _sqlite_pragmas(dbapi_connection, _record):
    # SQLite ships with foreign-key enforcement off.
    if isinstance(dbapi_connection, sqlite3.Connection):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()


def _secret_key(instance_path):
    """Stable random key per installation unless SECRET_KEY is provided."""
    if os.environ.get("SECRET_KEY"):
        return os.environ["SECRET_KEY"]
    path = os.path.join(instance_path, "secret_key")
    try:
        with open(path, encoding="utf-8") as fh:
            key = fh.read().strip()
            if key:
                return key
    except OSError:
        pass
    key = secrets.token_hex(32)
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(key)
        os.chmod(path, 0o600)
    except OSError:
        pass  # read-only instance dir: fall back to a per-process key
    return key


def create_app(test_config=None):
    app = Flask(__name__, instance_relative_config=True)
    os.makedirs(app.instance_path, exist_ok=True)

    app.config.from_mapping(
        SQLALCHEMY_DATABASE_URI=os.environ.get(
            "DATABASE_URL", f"sqlite:///{os.path.join(app.instance_path, 'rfida.sqlite')}"
        ),
        SQLALCHEMY_TRACK_MODIFICATIONS=False,
        APP_TIMEZONE=os.environ.get("APP_TIMEZONE", DEFAULT_TIMEZONE),
        CSRF_ENABLED=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_HTTPONLY=True,
        MAX_CONTENT_LENGTH=2 * 1024 * 1024,
    )
    if test_config:
        app.config.update(test_config)
    if not app.config.get("SECRET_KEY"):
        app.config["SECRET_KEY"] = _secret_key(app.instance_path)

    db.init_app(app)

    from . import models  # noqa: F401
    from .api import api_bp
    from .dashboard import dashboard_bp
    from .schema import upgrade_schema

    app.register_blueprint(api_bp)
    app.register_blueprint(dashboard_bp)

    with app.app_context():
        db.create_all()
        upgrade_schema()

    register_security(app)
    register_template_support(app)
    register_errors(app)
    register_cli(app)
    return app


# ------------------------------------------------------------------ security


def register_security(app):
    def csrf_token():
        token = session.get("_csrf")
        if not token:
            token = secrets.token_urlsafe(32)
            session["_csrf"] = token
        return token

    app.jinja_env.globals["csrf_token"] = csrf_token

    @app.before_request
    def csrf_protect():
        # The JSON API is for the handheld app (no cookies, no browser), so only
        # browser form posts need a token.
        if (
            request.method in ("POST", "PUT", "PATCH", "DELETE")
            and app.config.get("CSRF_ENABLED")
            and not request.path.startswith("/api/")
        ):
            sent = request.form.get("_csrf") or request.headers.get("X-CSRF-Token") or ""
            expected = session.get("_csrf", "")
            if not expected or not hmac.compare_digest(sent.encode(), expected.encode()):
                abort(400, description="表單已過期或無效,請重新整理頁面後再試。")

    @app.after_request
    def security_headers(response):
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "same-origin")
        response.headers.setdefault("X-Frame-Options", "SAMEORIGIN")
        if not request.path.startswith("/api/"):
            response.headers.setdefault(
                "Content-Security-Policy",
                "default-src 'self'; style-src 'self' 'unsafe-inline'; "
                "img-src 'self' data:; form-action 'self'; frame-ancestors 'self'",
            )
            if request.method == "GET" and response.mimetype == "text/html":
                response.headers.setdefault("Cache-Control", "no-store")
        return response


# ------------------------------------------------------------------ templates


def register_template_support(app):
    from . import services
    from .dashboard.reports import ACTIONS, ENTITY_TYPES, SOURCES

    @app.template_filter("ldt")
    def ldt(dt):
        """Stored UTC datetime -> office-local 'YYYY-MM-DD HH:MM'."""
        local = to_local(dt)
        return local.strftime("%Y-%m-%d %H:%M") if local else "—"

    @app.template_filter("ldate")
    def ldate(dt):
        local = to_local(dt)
        return local.strftime("%Y-%m-%d") if local else "—"

    @app.template_filter("dstr")
    def dstr(value):
        """A calendar date / date-only datetime, never shifted between zones."""
        return value.strftime("%Y-%m-%d") if value else "—"

    @app.template_filter("reltime")
    def reltime(dt):
        if dt is None:
            return "—"
        aware = dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt
        seconds = int((utcnow() - aware).total_seconds())
        if seconds < 60:
            return "剛剛"
        if seconds < 3600:
            return f"{seconds // 60} 分鐘前"
        if seconds < 86400:
            return f"{seconds // 3600} 小時前"
        if seconds < 86400 * 7:
            return f"{seconds // 86400} 日前"
        return ldate(dt)

    def url_args(**overrides):
        """Current URL with some query args replaced (None/'' removes one)."""
        args = request.args.to_dict(flat=True)
        args.update(overrides)
        args = {k: v for k, v in args.items() if v not in (None, "")}
        return url_for(request.endpoint, **(request.view_args or {}), **args)

    def entity_url(entry):
        from .dashboard.search import _DOC_TARGETS

        if entry.action == "delete" or entry.entity_id is None:
            return None
        target = _DOC_TARGETS.get(entry.entity_type)
        if not target:
            return None
        return url_for(target[1], **{target[2]: entry.entity_id})

    app.jinja_env.globals.update(
        url_args=url_args,
        entity_url=entity_url,
        STATUS_LABELS=services.STATUS_LABELS,
        LOAN_STATUS_LABELS=services.LOAN_STATUS_LABELS,
        CONDITION_LABELS=services.CONDITION_LABELS,
        DIRECTION_LABELS=services.DIRECTION_LABELS,
        FIELD_LABELS=services.FIELD_LABELS,
        ENTITY_TYPES=ENTITY_TYPES,
        AUDIT_ACTIONS=ACTIONS,
        AUDIT_SOURCES=SOURCES,
    )

    @app.context_processor
    def shell_counts():
        """Badges in the side navigation. Never let them break a page."""
        if request.endpoint in (None, "static") or (request.endpoint or "").startswith("api."):
            return {}
        try:
            from .models import Equipment

            return {
                "shell": {
                    "overdue": services.overdue_loans_query().count(),
                    "missing": Equipment.query.filter_by(status="missing").count(),
                },
                "app_tz": app.config["APP_TIMEZONE"],
            }
        except Exception:  # pragma: no cover - defensive
            db.session.rollback()
            return {"shell": {"overdue": 0, "missing": 0}}


# ------------------------------------------------------------------ errors


def register_errors(app):
    def wants_json():
        return request.path.startswith("/api/")

    @app.errorhandler(HTTPException)
    def http_error(err):
        if wants_json():
            return jsonify({"error": err.description or err.name}), err.code
        return (
            render_template("error.html", code=err.code, title=err.name, message=err.description),
            err.code,
        )

    @app.errorhandler(Exception)
    def server_error(err):
        app.logger.exception("Unhandled error on %s %s", request.method, request.path)
        db.session.rollback()
        if wants_json():
            return jsonify({"error": "Internal server error"}), 500
        return (
            render_template(
                "error.html", code=500, title="伺服器錯誤", message="發生未預期嘅錯誤,請稍後再試。"
            ),
            500,
        )


# ------------------------------------------------------------------ CLI


def register_cli(app):
    @app.cli.command("seed-demo")
    def seed_demo():
        """建立示範資料(器材/公司/Job/借出單),方便試用網頁 Dashboard。"""
        from .seed import seed_demo_data

        seed_demo_data()
        print("示範資料建立完成。")

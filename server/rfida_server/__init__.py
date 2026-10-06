import os

from flask import Flask

from .extensions import db


def create_app(test_config=None):
    app = Flask(__name__, instance_relative_config=True)
    os.makedirs(app.instance_path, exist_ok=True)

    app.config.from_mapping(
        SECRET_KEY=os.environ.get("SECRET_KEY", "dev-secret-key-change-me"),
        SQLALCHEMY_DATABASE_URI=os.environ.get(
            "DATABASE_URL", f"sqlite:///{os.path.join(app.instance_path, 'rfida.sqlite')}"
        ),
        SQLALCHEMY_TRACK_MODIFICATIONS=False,
    )
    if test_config:
        app.config.update(test_config)

    db.init_app(app)

    from . import models  # noqa: F401
    from .api import api_bp
    from .dashboard import dashboard_bp

    app.register_blueprint(api_bp)
    app.register_blueprint(dashboard_bp)

    with app.app_context():
        db.create_all()
        add_missing_columns()

    register_cli(app)

    return app


def add_missing_columns():
    """create_all() 不會修改舊表格,所以幫舊資料庫補上新欄位。"""
    from sqlalchemy import inspect, text

    inspector = inspect(db.engine)
    for table in db.metadata.sorted_tables:
        if not inspector.has_table(table.name):
            continue
        existing = {c["name"] for c in inspector.get_columns(table.name)}
        for column in table.columns:
            if column.name in existing:
                continue
            col_type = column.type.compile(dialect=db.engine.dialect)
            db.session.execute(
                text(f'ALTER TABLE "{table.name}" ADD COLUMN "{column.name}" {col_type}')
            )
    db.session.commit()


def register_cli(app):
    @app.cli.command("seed-demo")
    def seed_demo():
        """建立示範資料(器材/公司/Job),方便試用網頁 Dashboard。"""
        from .seed import seed_demo_data

        seed_demo_data()
        print("示範資料建立完成。")

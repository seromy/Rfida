import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rfida_server import create_app  # noqa: E402
from rfida_server.extensions import db  # noqa: E402


@pytest.fixture()
def app():
    app = create_app(
        {
            "TESTING": True,
            "SQLALCHEMY_DATABASE_URI": "sqlite://",
            "CSRF_ENABLED": False,
            "SECRET_KEY": "test",
        }
    )
    with app.app_context():
        yield app
        db.session.remove()
        db.drop_all()


@pytest.fixture()
def client(app):
    return app.test_client()


@pytest.fixture()
def seeded(app):
    from rfida_server.seed import seed_demo_data

    seed_demo_data()
    return app


def make_equipment(epc="AA01", name="Test Cam", **extra):
    from rfida_server import services

    return services.create_equipment({"epc": epc, "name": name, **extra})


def future(days=3):
    from datetime import timedelta

    from rfida_server.utils import local_today

    return (local_today() + timedelta(days=days)).isoformat()

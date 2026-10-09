"""Web dashboard: SAP Fiori-style list reports and object pages.

One blueprint, one module per business object. Endpoint names are stable
(`dashboard.<object>_<action>`) because templates and the shell navigation link
to them.
"""

from flask import Blueprint

dashboard_bp = Blueprint("dashboard", __name__)

from . import (  # noqa: E402,F401  (import for route registration)
    companies,
    equipment,
    home,
    inventory,
    jobs,
    loans,
    movements,
    reports,
    search,
)

"""Web dashboard: every page renders, forms validate, and known bugs stay fixed."""

import re

import pytest

from rfida_server import create_app, services
from rfida_server.extensions import db
from rfida_server.models import Company, Equipment, Job, Loan

from conftest import future, make_equipment

GET_PAGES = [
    "/", "/equipment", "/equipment?status=on_loan", "/equipment?status=damaged&sort=epc&dir=desc&q=sony",
    "/equipment/new", "/equipment/new?epc=abc123", "/equipment/1", "/equipment/1/edit", "/equipment/export.csv",
    "/company", "/company?q=%E9%99%B3", "/company/new", "/company/1", "/company/1/edit",
    "/jobs", "/jobs?status=open", "/jobs/new", "/jobs/1", "/jobs/1/edit",
    "/movements", "/movements?direction=in&date_from=2026-01-01&date_to=2030-01-01", "/movements/1", "/movements/export.csv",
    "/inventory-sessions", "/inventory-sessions?unknown=1", "/inventory-sessions/1",
    "/loans", "/loans?status=open", "/loans?status=overdue", "/loans?status=returned&sort=due&dir=asc",
    "/loans/new", "/loans/new?equipment=1&equipment=2", "/loans/1", "/loans/2", "/loans/3", "/loans/1/print", "/loans/export.csv",
    "/reports/stock", "/reports/stock.csv", "/reports/changes", "/reports/changes?entity=loan&action=create",
]


@pytest.mark.parametrize("path", GET_PAGES)
def test_pages_render(seeded, client, path):
    response = client.get(path)
    assert response.status_code == 200, path
    if path.endswith(".csv"):
        assert response.mimetype == "text/csv"
    else:
        html = response.get_data(as_text=True)
        assert "<h1" in html and "Traceback" not in html


def test_unknown_pages_give_html_404_with_shell(client):
    r = client.get("/equipment/999")
    assert r.status_code == 404
    assert "Rfida" in r.get_data(as_text=True)


def test_out_of_range_page_is_not_an_error(seeded, client):
    assert client.get("/equipment?page=999").status_code == 200
    assert client.get("/equipment?page=abc&sort=bogus&dir=sideways").status_code == 200


def test_launchpad_shows_overdue_loan(seeded, client):
    html = client.get("/").get_data(as_text=True)
    assert "逾期借出" in html and "LN-000001" in html


def test_pagination_and_sorting(app, client):
    for i in range(45):
        make_equipment(f"E{i:03d}", f"Item {i:02d}")
    html = client.get("/equipment?sort=name&dir=desc").get_data(as_text=True)
    assert "Item 44" in html and "Item 24" not in html  # 20 per page, newest name first
    page3 = client.get("/equipment?sort=name&dir=desc&page=3").get_data(as_text=True)
    assert "Item 04" in page3 and "Item 44" not in page3


def test_quote_in_name_cannot_break_out_of_the_confirm_attribute(app, client):
    """Regression: the old inline onsubmit="confirm('…{{ name }}…')" decoded &#39; back into a quote."""
    make_equipment("AA01", "Bob's <img src=x onerror=alert(1)> lens")
    html = client.get("/equipment/1").get_data(as_text=True)
    assert "onsubmit" not in html and "onclick" not in html
    assert "<img src=x" not in html
    assert "&lt;img src=x" in html
    # the message lives in a data attribute, HTML-escaped, never in script context
    assert re.search(r'data-confirm="[^"]*Bob&#39;s &lt;img', html)


def test_csrf_is_enforced_for_browser_forms_but_not_the_api():
    app = create_app({"TESTING": True, "SQLALCHEMY_DATABASE_URI": "sqlite://", "SECRET_KEY": "k"})
    client = app.test_client()
    assert client.post("/company/new", data={"name": "X"}).status_code == 400
    assert client.post("/api/equipment/register", json={"epc": "AB12", "name": "x"}).status_code == 201

    page = client.get("/company/new").get_data(as_text=True)
    token = re.search(r'name="_csrf" value="([^"]+)"', page).group(1)
    assert client.post("/company/new", data={"name": "X", "_csrf": "wrong"}).status_code == 400
    ok = client.post("/company/new", data={"name": "X", "_csrf": token}, follow_redirects=True)
    assert ok.status_code == 200 and "已新增公司" in ok.get_data(as_text=True)


def test_equipment_form_validation_keeps_input(app, client):
    r = client.post("/equipment/new", data={"epc": "", "name": "Keep me", "category": "鏡頭"})
    html = r.get_data(as_text=True)
    assert r.status_code == 400
    assert "EPC 為必填" in html and 'value="Keep me"' in html and 'value="鏡頭"' in html

    client.post("/equipment/new", data={"epc": "aa01", "name": "A"})
    dup = client.post("/equipment/new", data={"epc": "AA01", "name": "B"})
    assert dup.status_code == 409 and "已經登記" in dup.get_data(as_text=True)


def test_equipment_edit_and_change_log(app, client):
    make_equipment("AA01", "Old name")
    r = client.post("/equipment/1/edit", data={"epc": "aa01", "name": "New name", "location": "B 櫃"}, follow_redirects=True)
    html = r.get_data(as_text=True)
    assert "已儲存變更" in html and "New name" in html
    assert "更新:名稱、存放位置" in html  # change document on the object page
    assert Equipment.query.one().epc == "AA01"


def test_job_bad_date_is_reported_not_silently_ignored(app, client):
    r = client.post("/jobs/new", data={"name": "Shoot", "date": "2026-13-45"})
    assert r.status_code == 400 and "日期" in r.get_data(as_text=True)
    assert Job.query.count() == 0
    ok = client.post("/jobs/new", data={"name": "Shoot", "date": "2026-09-12"}, follow_redirects=True)
    assert "2026-09-12" in ok.get_data(as_text=True)


def test_job_delete_rules(seeded, client):
    with_movements = client.post("/jobs/1/delete", follow_redirects=True)
    assert "不可刪除" in with_movements.get_data(as_text=True) and db.session.get(Job, 1)
    empty = services.create_job({"name": "Empty", "date": "2026-10-01"})
    client.post(f"/jobs/{empty.id}/delete")
    assert db.session.get(Job, empty.id) is None


def test_company_delete_is_blocked_when_referenced(seeded, client):
    """Regression: deleting a company used to leave dangling company_id on movements."""
    r = client.post("/company/1/delete", follow_redirects=True)
    assert "不可刪除" in r.get_data(as_text=True)
    assert db.session.get(Company, 1) is not None


def test_equipment_delete_flow(app, client):
    make_equipment("AA01", "Gone")
    r = client.post("/equipment/1/delete", follow_redirects=True)
    assert "已刪除器材「Gone」" in r.get_data(as_text=True)  # regression: used to read a detached instance
    assert Equipment.query.count() == 0


def test_loan_web_flow_create_return_extend_cancel(app, client):
    a, b = make_equipment("AA01", "Cam A"), make_equipment("AA02", "Cam B")
    page = client.get(f"/loans/new?equipment={a.id}").get_data(as_text=True)
    assert 'value="1" data-select="equipment"' in page and "checked" in page

    r = client.post(
        "/loans/new",
        data={"borrower_name": "Bob", "due_date": future(2), "equipment_id": [a.id], "epc_paste": "aa02"},
        follow_redirects=True,
    )
    html = r.get_data(as_text=True)
    assert "LN-000001" in html and "借出中" in html and "Cam A" in html and "Cam B" in html

    loan = Loan.query.one()
    item_a = next(i for i in loan.items if i.equipment_id == a.id)
    r = client.post(
        f"/loans/{loan.id}/return",
        data={"return_item": [item_a.id], f"condition_{item_a.id}": "damaged", f"note_{item_a.id}": "dent"},
        follow_redirects=True,
    )
    assert "尚餘 1 件未還" in r.get_data(as_text=True)
    assert Loan.query.one().status == "partial"
    assert db.session.get(Equipment, a.id).condition == "damaged"

    r = client.post(f"/loans/{loan.id}/extend", data={"due_date": future(9), "reason": "ok"}, follow_redirects=True)
    assert future(9) in r.get_data(as_text=True)

    r = client.post(f"/loans/{loan.id}/cancel", follow_redirects=True)
    assert "只有未有任何歸還" in r.get_data(as_text=True)

    r = client.post(f"/loans/{loan.id}/return-all", follow_redirects=True)
    assert Loan.query.one().status == "returned"


def test_loan_form_errors_preserve_selection(app, client):
    a = make_equipment("AA01", "Cam A")
    r = client.post("/loans/new", data={"borrower_name": "Bob", "due_date": "2001-01-01", "equipment_id": [a.id]})
    html = r.get_data(as_text=True)
    assert r.status_code == 400 and "不可以早過今日" in html
    assert 'value="Bob"' in html and re.search(r'value="1"[^>]*checked', html)
    assert Loan.query.count() == 0


def test_loan_print_slip_has_no_app_shell(seeded, client):
    html = client.get("/loans/1/print").get_data(as_text=True)
    assert "器材借用單" in html and "LN-000001" in html and "sidenav" not in html


def test_csv_export_neutralises_formula_injection(app, client):
    make_equipment("AA01", "=HYPERLINK(\"http://evil\")")
    body = client.get("/equipment/export.csv").get_data(as_text=True)
    assert "'=HYPERLINK" in body and ",=HYPERLINK" not in body
    assert body.startswith("﻿")


def test_global_search_jumps_to_documents_and_epcs(seeded, client):
    assert client.get("/search?q=ln-1").headers["Location"].endswith("/loans/1")
    assert client.get("/search?q=MV-000002").headers["Location"].endswith("/movements/2")
    assert client.get("/search?q=e2801160600002042bb8a1c1").headers["Location"].endswith("/equipment/1")
    assert "/equipment?q=sony" in client.get("/search?q=sony").headers["Location"]
    assert client.get("/search?q=LN-999999").headers["Location"].endswith("/equipment?q=LN-999999")


def test_like_wildcards_are_literal(app, client):
    make_equipment("AA01", "100% cotton")
    make_equipment("AA02", "plain")
    html = client.get("/equipment?q=%25").get_data(as_text=True)
    assert "100% cotton" in html and "plain" not in html


def test_times_are_shown_in_office_local_time(app, client):
    from datetime import datetime

    eq = make_equipment("AA01")
    eq.last_seen_at = datetime(2026, 9, 11, 16, 30)  # stored UTC
    db.session.commit()
    assert "2026-09-12 00:30" in client.get("/equipment").get_data(as_text=True)  # Hong Kong = UTC+8


def test_security_headers_present(client):
    r = client.get("/")
    csp = r.headers["Content-Security-Policy"]
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    # no inline script anywhere: scripts fall back to default-src 'self'
    assert "script-src" not in csp and "default-src 'self'" in csp
    assert "unsafe-inline" not in csp.split("style-src")[0]
    assert "inline" not in " ".join(re.findall(r"<script[^>]*>", r.get_data(as_text=True)))

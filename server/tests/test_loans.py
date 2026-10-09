"""Device-loan service rules (shared by the web UI and the API)."""

from datetime import timedelta

import pytest

from rfida_server import services
from rfida_server.extensions import db
from rfida_server.models import AuditLog, Equipment, Loan
from rfida_server.services import ServiceError
from rfida_server.utils import local_today

from conftest import future, make_equipment


def new_loan(*equipment, **extra):
    data = {"borrower_name": "Bob", "due_date": future(), **extra}
    return services.create_loan(data, equipment_ids=[e.id for e in equipment])


def test_create_loan_marks_equipment_out_and_writes_change_documents(app):
    a, b = make_equipment("AA01"), make_equipment("AA02")
    loan = new_loan(a, b, purpose="wedding")

    assert loan.doc_no == "LN-000001"
    assert loan.status == "active" and loan.item_count == 2 and loan.outstanding_count == 2
    assert {e.status for e in Equipment.query.all()} == {"checked_out"}
    assert all(e.on_loan for e in Equipment.query.all())
    actions = {(a.entity_type, a.action) for a in AuditLog.query.all()}
    assert ("loan", "create") in actions and ("equipment", "loan_out") in actions


@pytest.mark.parametrize(
    "mutate, message",
    [
        (lambda d: d.update(due_date=(local_today() - timedelta(days=1)).isoformat()), "不可以早過今日"),
        (lambda d: d.update(due_date=""), "到期日為必填"),
        (lambda d: d.update(due_date="2026-13-45"), "格式不正確"),
        (lambda d: d.update(borrower_name=""), "公司或者填寫借用人"),
    ],
)
def test_create_loan_validation(app, mutate, message):
    eq = make_equipment("AA01")
    data = {"borrower_name": "Bob", "due_date": future()}
    mutate(data)
    with pytest.raises(ServiceError) as err:
        services.create_loan(data, equipment_ids=[eq.id])
    assert message in "; ".join(err.value.messages)
    assert Loan.query.count() == 0
    assert db.session.get(Equipment, eq.id).status == "in_stock"


def test_cannot_loan_unavailable_equipment(app):
    on_job, missing, damaged, loaned, free = (make_equipment(f"AA0{i}") for i in range(5))
    on_job.status, missing.status, damaged.condition = "checked_out", "missing", "damaged"
    db.session.commit()
    new_loan(loaned)

    with pytest.raises(ServiceError) as err:
        new_loan(on_job, missing, damaged, loaned, free)
    text = "; ".join(err.value.messages)
    for reason in ("已出Job", "遺失", "損壞待修", "已借出"):
        assert reason in text
    # all-or-nothing: the free item was not taken
    assert db.session.get(Equipment, free.id).status == "in_stock"

    with pytest.raises(ServiceError):
        services.create_loan({"borrower_name": "x", "due_date": future()}, equipment_ids=[])


def test_partial_then_full_return_with_conditions(app):
    a, b, c = (make_equipment(f"AA0{i}") for i in range(3))
    loan = new_loan(a, b, c)
    items = {i.equipment.epc: i.id for i in loan.items}

    services.return_loan_items(loan, [{"item_id": items["AA00"], "condition": "good"}])
    assert loan.status == "partial" and loan.outstanding_count == 2
    assert a.status == "in_stock" and not a.on_loan

    with pytest.raises(ServiceError, match="已經歸還"):
        services.return_loan_items(loan, [{"item_id": items["AA00"], "condition": "good"}])

    services.return_loan_items(
        loan,
        [
            {"item_id": items["AA01"], "condition": "damaged", "note": "cracked"},
            {"item_id": items["AA02"], "condition": "lost"},
        ],
    )
    assert loan.status == "returned" and loan.returned_at is not None
    assert (b.status, b.condition) == ("in_stock", "damaged")
    assert c.status == "missing"
    # a damaged item cannot be lent again until repaired
    with pytest.raises(ServiceError, match="損壞待修"):
        new_loan(b)
    services.set_equipment_condition(b, "good")
    services.commit()
    assert new_loan(b).status == "active"


def test_return_rejects_foreign_items_and_bad_conditions(app):
    a, b = make_equipment("AA01"), make_equipment("AA02")
    first, second = new_loan(a), new_loan(b)
    with pytest.raises(ServiceError):
        services.return_loan_items(first, [{"item_id": second.items[0].id, "condition": "good"}])
    with pytest.raises(ServiceError):
        services.return_loan_items(first, [{"item_id": first.items[0].id, "condition": "exploded"}])
    with pytest.raises(ServiceError):
        services.return_loan_items(first, [])
    assert first.status == "active"


def test_overdue_is_derived_from_the_due_date(app, monkeypatch):
    eq = make_equipment("AA01")
    loan = new_loan(eq)
    assert not loan.is_overdue and loan.days_until_due == 3

    loan.due_date = local_today() - timedelta(days=2)
    assert loan.is_overdue and loan.days_overdue == 2 and loan.display_status == "overdue"
    assert services.overdue_loans_query().count() == 1

    services.return_all_good(loan)
    assert not loan.is_overdue  # finished loans are never overdue
    assert services.overdue_loans_query().count() == 0


def test_extend_loan_rules(app):
    loan = new_loan(make_equipment("AA01"))
    services.extend_loan(loan, future(20), reason="client asked")
    assert loan.due_date.isoformat() == future(20)
    entry = AuditLog.query.filter_by(action="extend").one()
    assert "client asked" in entry.summary

    for bad in (future(20), "2001-01-01", "", "nonsense"):
        with pytest.raises(ServiceError):
            services.extend_loan(loan, bad)

    services.return_all_good(loan)
    with pytest.raises(ServiceError):
        services.extend_loan(loan, future(30))


def test_cancel_only_before_any_return(app):
    a, b = make_equipment("AA01"), make_equipment("AA02")
    loan = new_loan(a, b)
    services.return_loan_items(loan, [{"item_id": loan.items[0].id, "condition": "good"}])
    with pytest.raises(ServiceError):
        services.cancel_loan(loan)

    other = new_loan(make_equipment("AA03"))
    services.cancel_loan(other, reason="typo")
    assert other.status == "cancelled" and other.outstanding_count == 0
    assert Equipment.query.filter_by(epc="AA03").one().status == "in_stock"
    assert other.item_count == 0
    # and the item can be lent again
    assert new_loan(Equipment.query.filter_by(epc="AA03").one()).status == "active"


def test_equipment_guards_while_on_loan(app):
    eq = make_equipment("AA01")
    loan = new_loan(eq)
    with pytest.raises(ServiceError, match="借出中"):
        services.change_equipment_status(eq, "in_stock")
    with pytest.raises(ServiceError, match="借出紀錄"):
        services.delete_equipment(eq)
    services.return_all_good(loan)
    with pytest.raises(ServiceError, match="借出紀錄"):  # history keeps it undeletable
        services.delete_equipment(eq)


def test_company_in_use_cannot_be_deleted(app):
    company = services.create_company({"name": "Acme", "phone": "123"})
    eq = make_equipment("AA01")
    loan = services.create_loan(
        {"company_id": company.id, "due_date": future()}, equipment_ids=[eq.id]
    )
    assert loan.borrower_display == "Acme"
    assert loan.contact == "123"  # defaulted from the company record
    with pytest.raises(ServiceError, match="不可刪除"):
        services.delete_company(company)
    assert db.session.get(type(company), company.id) is not None

    empty = services.create_company({"name": "Unused"})
    services.delete_company(empty)


def test_create_by_epc_text_and_unknown_epc(app):
    make_equipment("AA01")
    loan = services.create_loan({"borrower_name": "Bob", "due_date": future()}, epcs=["aa01"])
    assert loan.item_count == 1
    with pytest.raises(ServiceError, match="未登記"):
        services.create_loan({"borrower_name": "Bob", "due_date": future()}, epcs=["NOPE1"])

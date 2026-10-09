"""Demo data so a fresh install has something to click through."""

from datetime import timedelta

from . import services
from .extensions import db
from .models import Company, Equipment
from .utils import local_today, utcnow_naive

# epc, name, category, serial, location
DEMO_EQUIPMENT = [
    ("E2801160600002042BB8A1C1", "Sony A7IV 機身", "機身", "SN-0001", "A 櫃"),
    ("E2801160600002042BB8A1C2", "Sony A7IV 機身", "機身", "SN-0002", "A 櫃"),
    ("E2801160600002042BB8A1C3", "Sony FE 24-70mm F2.8 GM", "鏡頭", "SN-1001", "B 櫃"),
    ("E2801160600002042BB8A1C4", "Sony FE 70-200mm F2.8 GM", "鏡頭", "SN-1002", "B 櫃"),
    ("E2801160600002042BB8A1C5", "Godox AD200 閃光燈", "燈光", "SN-2001", "C 櫃"),
    ("E2801160600002042BB8A1C6", "Manfrotto 三腳架", "支架", "SN-3001", "倉庫"),
    ("E2801160600002042BB8A1C7", "Sony FE 35mm F1.4 GM", "鏡頭", "SN-1003", "B 櫃"),
    ("E2801160600002042BB8A1C8", "Aputure 300d II 燈", "燈光", "SN-2002", "C 櫃"),
    ("E2801160600002042BB8A1C9", "Rode Wireless GO II 咪", "收音", "SN-4001", "D 櫃"),
    ("E2801160600002042BB8A1CA", "DJI RS 3 Pro 穩定器", "支架", "SN-3002", "倉庫"),
    ("E2801160600002042BB8A1CB", "Atomos Ninja V 監視器", "監視", "SN-5001", "D 櫃"),
    ("E2801160600002042BB8A1CC", "SanDisk 512GB CFexpress 卡", "儲存", "SN-6001", "D 櫃"),
]

DEMO_COMPANIES = [
    ("陳大文攝影工作室", "陳大文", "9123 4567", "chan@example.com"),
    ("李小明影像製作", "李小明", "9234 5678", "lee@example.com"),
    ("黃美玲活動策劃", "黃美玲", "9345 6789", "wong@example.com"),
]


def seed_demo_data():
    if Equipment.query.first() or Company.query.first():
        print("資料庫已有資料,略過建立示範資料。")
        return

    companies = [
        services.create_company(
            {"name": name, "contact_name": contact, "phone": phone, "email": email}
        )
        for name, contact, phone, email in DEMO_COMPANIES
    ]
    equipment = {
        row[0]: services.create_equipment(
            {"epc": row[0], "name": row[1], "category": row[2], "serial_number": row[3], "location": row[4]}
        )
        for row in DEMO_EQUIPMENT
    }

    today = local_today()
    job_open = services.create_job({"name": f"{(today + timedelta(days=1)).isoformat()} 婚禮攝影", "date": (today + timedelta(days=1)).isoformat()})
    job_closed = services.create_job({"name": f"{(today - timedelta(days=6)).isoformat()} 產品拍攝", "date": (today - timedelta(days=6)).isoformat()})
    services.set_job_status(job_closed, "closed")

    # Handheld-style movements (these also move equipment status).
    services.record_movement(
        direction="out",
        epcs=["E2801160600002042BB8A1C2", "E2801160600002042BB8A1C3"],
        job_id=job_open.id,
        company_id=companies[0].id,
        note="出Job帶走機身連鏡頭",
    )
    services.record_movement(
        direction="out",
        epcs=["E2801160600002042BB8A1C6"],
        job_id=job_closed.id,
        company_id=companies[1].id,
    )
    services.record_movement(
        direction="in",
        epcs=[],
        missing_epcs=["E2801160600002042BB8A1C6"],
        job_id=job_closed.id,
        company_id=companies[1].id,
        note="三腳架未見,標記為遺失",
    )
    services.record_inventory(
        company_id=companies[0].id,
        batch_label="A 櫃",
        scanned_epcs=["E2801160600002042BB8A1C1", "E2801160600002042BB8A1C5", "E2801160600002042BB8A1FF"],
    )

    # Loans: one overdue, one running, one fully returned with a damaged item.
    overdue = services.create_loan(
        {
            "company_id": companies[2].id,
            "borrower_name": "黃美玲",
            "purpose": "公司活動拍攝",
            "handled_by": "Peter",
            "due_date": (today + timedelta(days=1)).isoformat(),
        },
        equipment_ids=[equipment["E2801160600002042BB8A1C4"].id, equipment["E2801160600002042BB8A1C8"].id],
    )
    overdue.due_date = today - timedelta(days=3)
    overdue.loan_date = utcnow_naive() - timedelta(days=10)

    services.create_loan(
        {
            "company_id": companies[1].id,
            "borrower_name": "李小明",
            "purpose": "短片拍攝",
            "handled_by": "Peter",
            "due_date": (today + timedelta(days=5)).isoformat(),
        },
        equipment_ids=[equipment["E2801160600002042BB8A1C9"].id],
    )

    finished = services.create_loan(
        {
            "borrower_name": "張偉",
            "contact": "9456 7890",
            "purpose": "畢業作品",
            "handled_by": "Mary",
            "due_date": (today + timedelta(days=2)).isoformat(),
        },
        equipment_ids=[equipment["E2801160600002042BB8A1CA"].id, equipment["E2801160600002042BB8A1CB"].id],
    )
    services.return_loan_items(
        finished,
        [
            {"item_id": finished.items[0].id, "condition": "good"},
            {"item_id": finished.items[1].id, "condition": "damaged", "note": "螢幕有裂痕"},
        ],
    )
    finished.loan_date = utcnow_naive() - timedelta(days=8)
    db.session.commit()

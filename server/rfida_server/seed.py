from datetime import datetime, timedelta

from .extensions import db
from .models import Equipment, Job, Movement, Staff, utcnow

DEMO_EQUIPMENT = [
    ("E2801160600002042BB8A1C1", "Sony A7IV 機身", "機身", "SN-0001", "in_stock"),
    ("E2801160600002042BB8A1C2", "Sony A7IV 機身", "機身", "SN-0002", "checked_out"),
    ("E2801160600002042BB8A1C3", "Sony FE 24-70mm F2.8", "鏡頭", "SN-1001", "checked_out"),
    ("E2801160600002042BB8A1C4", "Sony FE 70-200mm F2.8", "鏡頭", "SN-1002", "in_stock"),
    ("E2801160600002042BB8A1C5", "Godox AD200 閃光燈", "燈光", "SN-2001", "in_stock"),
    ("E2801160600002042BB8A1C6", "Manfrotto 三腳架", "支架", "SN-3001", "missing"),
]

DEMO_STAFF = ["陳大文", "李小明", "黃美玲"]


def seed_demo_data():
    if Equipment.query.first() or Staff.query.first():
        print("資料庫已有資料,略過建立示範資料。")
        return

    staff_objs = [Staff(name=name) for name in DEMO_STAFF]
    db.session.add_all(staff_objs)

    for epc, name, category, serial, status in DEMO_EQUIPMENT:
        db.session.add(
            Equipment(
                epc=epc,
                name=name,
                category=category,
                serial_number=serial,
                status=status,
                last_seen_at=utcnow() - timedelta(hours=3),
            )
        )

    job_open = Job(name="2026-09-12 婚禮攝影", date=datetime.utcnow() + timedelta(days=1), status="open")
    job_closed = Job(name="2026-09-05 產品拍攝", date=datetime.utcnow() - timedelta(days=6), status="closed")
    db.session.add_all([job_open, job_closed])
    db.session.flush()

    db.session.add(
        Movement(
            job_id=job_open.id,
            staff_id=staff_objs[0].id,
            direction="out",
            epcs=[
                "E2801160600002042BB8A1C2",
                "E2801160600002042BB8A1C3",
            ],
            note="出Job帶走機身連鏡頭",
        )
    )
    db.session.add(
        Movement(
            job_id=job_closed.id,
            staff_id=staff_objs[1].id,
            direction="out",
            epcs=["E2801160600002042BB8A1C6"],
        )
    )
    db.session.add(
        Movement(
            job_id=job_closed.id,
            staff_id=staff_objs[1].id,
            direction="in",
            epcs=[],
            missing_epcs=["E2801160600002042BB8A1C6"],
            note="三腳架未見,標記為遺失",
        )
    )

    db.session.commit()

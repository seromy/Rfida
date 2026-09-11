from datetime import datetime, timezone

from .extensions import db

VALID_EQUIPMENT_STATUS = ("in_stock", "checked_out", "missing")
VALID_JOB_STATUS = ("open", "closed")
VALID_DIRECTIONS = ("out", "in")


def utcnow():
    return datetime.now(timezone.utc)


def iso(dt):
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Equipment(db.Model):
    __tablename__ = "equipment"

    id = db.Column(db.Integer, primary_key=True)
    epc = db.Column(db.String(64), unique=True, nullable=False, index=True)
    name = db.Column(db.String(200), nullable=False)
    category = db.Column(db.String(100), nullable=False, default="")
    serial_number = db.Column(db.String(100), nullable=False, default="")
    status = db.Column(db.String(20), nullable=False, default="in_stock")
    last_seen_at = db.Column(db.DateTime, nullable=True)

    def to_dict(self):
        return {
            "id": self.id,
            "epc": self.epc,
            "name": self.name,
            "category": self.category,
            "serialNumber": self.serial_number,
            "status": self.status,
            "lastSeenAt": iso(self.last_seen_at),
        }


class Staff(db.Model):
    __tablename__ = "staff"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)

    def to_dict(self):
        return {"id": self.id, "name": self.name}


class Job(db.Model):
    __tablename__ = "jobs"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    date = db.Column(db.DateTime, nullable=False, default=utcnow)
    status = db.Column(db.String(20), nullable=False, default="open")

    movements = db.relationship(
        "Movement", backref="job", order_by="Movement.created_at.desc()"
    )

    def to_dict(self):
        return {
            "id": self.id,
            "name": self.name,
            "date": iso(self.date),
            "status": self.status,
        }

    def latest_out_movement(self):
        for movement in self.movements:
            if movement.direction == "out":
                return movement
        return None


class Movement(db.Model):
    __tablename__ = "movements"

    id = db.Column(db.Integer, primary_key=True)
    job_id = db.Column(db.Integer, db.ForeignKey("jobs.id"), nullable=True)
    staff_id = db.Column(db.Integer, db.ForeignKey("staff.id"), nullable=True)
    direction = db.Column(db.String(10), nullable=False)
    epcs = db.Column(db.JSON, nullable=False, default=list)
    missing_epcs = db.Column(db.JSON, nullable=True)
    note = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=utcnow)

    staff = db.relationship("Staff")

    def to_dict(self):
        return {
            "id": self.id,
            "jobId": self.job_id,
            "staffId": self.staff_id,
            "direction": self.direction,
            "epcs": self.epcs or [],
            "missingEpcs": self.missing_epcs,
            "note": self.note,
            "createdAt": iso(self.created_at),
        }


class InventorySession(db.Model):
    __tablename__ = "inventory_sessions"

    id = db.Column(db.Integer, primary_key=True)
    staff_id = db.Column(db.Integer, db.ForeignKey("staff.id"), nullable=True)
    batch_label = db.Column(db.String(100), nullable=False, default="")
    scanned_epcs = db.Column(db.JSON, nullable=False, default=list)
    unknown_epcs = db.Column(db.JSON, nullable=False, default=list)
    timestamp = db.Column(db.DateTime, nullable=False, default=utcnow)
    created_at = db.Column(db.DateTime, nullable=False, default=utcnow)

    staff = db.relationship("Staff")

    def to_dict(self):
        return {
            "id": self.id,
            "staffId": self.staff_id,
            "batchLabel": self.batch_label,
            "scannedEpcs": self.scanned_epcs or [],
            "unknownEpcs": self.unknown_epcs or [],
            "timestamp": iso(self.timestamp),
            "createdAt": iso(self.created_at),
        }

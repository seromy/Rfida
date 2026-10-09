import re

from .extensions import db
from .utils import iso, iso_date, local_today, utcnow_naive

# NOTE: the iOS app decodes equipment `status` as a strict enum of exactly these
# three values. "On loan" is therefore *derived* from open LoanItem rows and must
# never become a fourth status value.
VALID_EQUIPMENT_STATUS = ("in_stock", "checked_out", "missing")
VALID_CONDITIONS = ("good", "damaged")
VALID_JOB_STATUS = ("open", "closed")
VALID_DIRECTIONS = ("out", "in")
LOAN_STATUSES = ("active", "partial", "returned", "cancelled")
RETURN_CONDITIONS = ("good", "damaged", "lost")

# Document-number prefixes (SAP-style business object keys).
DOC_PREFIX = {
    "equipment": "EQ",
    "company": "CO",
    "job": "JB",
    "movement": "MV",
    "inventory": "IV",
    "loan": "LN",
}
_PREFIX_TO_TYPE = {v: k for k, v in DOC_PREFIX.items()}
_DOC_NO_RE = re.compile(r"^([A-Za-z]{2})[-\s]?0*(\d{1,9})$")


def doc_no(entity_type, entity_id):
    if entity_id is None:
        return "—"
    return f"{DOC_PREFIX[entity_type]}-{int(entity_id):06d}"


def parse_doc_no(text):
    """'ln-12' / 'LN-000012' -> ('loan', 12); None when not a document number."""
    match = _DOC_NO_RE.match((text or "").strip())
    if not match:
        return None
    entity_type = _PREFIX_TO_TYPE.get(match.group(1).upper())
    if not entity_type:
        return None
    return entity_type, int(match.group(2))


class Equipment(db.Model):
    __tablename__ = "equipment"

    id = db.Column(db.Integer, primary_key=True)
    epc = db.Column(db.String(128), unique=True, nullable=False, index=True)
    name = db.Column(db.String(200), nullable=False)
    category = db.Column(db.String(100), nullable=False, default="")
    serial_number = db.Column(db.String(100), nullable=False, default="")
    status = db.Column(db.String(20), nullable=False, default="in_stock", index=True)
    last_seen_at = db.Column(db.DateTime, nullable=True)
    # Web-only master data (not part of the handheld API contract).
    location = db.Column(db.String(100), nullable=False, default="")
    note = db.Column(db.Text, nullable=False, default="")
    condition = db.Column(db.String(20), nullable=False, default="good")
    created_at = db.Column(db.DateTime, nullable=True, default=utcnow_naive)
    updated_at = db.Column(
        db.DateTime, nullable=True, default=utcnow_naive, onupdate=utcnow_naive
    )

    loan_items = db.relationship("LoanItem", back_populates="equipment")

    @property
    def doc_no(self):
        return doc_no("equipment", self.id)

    @property
    def open_loan_item(self):
        return next((li for li in self.loan_items if li.state == "out"), None)

    @property
    def on_loan(self):
        return self.open_loan_item is not None

    @property
    def is_damaged(self):
        return self.condition == "damaged"

    def to_dict(self):
        # Contract with the iOS app: keep these keys and value sets stable.
        return {
            "id": self.id,
            "epc": self.epc,
            "name": self.name,
            "category": self.category,
            "serialNumber": self.serial_number,
            "status": self.status,
            "lastSeenAt": iso(self.last_seen_at),
        }


class Company(db.Model):
    __tablename__ = "company"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    contact_name = db.Column(db.String(100), nullable=False, default="")
    phone = db.Column(db.String(50), nullable=False, default="")
    email = db.Column(db.String(120), nullable=False, default="")
    note = db.Column(db.Text, nullable=False, default="")
    created_at = db.Column(db.DateTime, nullable=True, default=utcnow_naive)

    loans = db.relationship("Loan", back_populates="company")

    @property
    def doc_no(self):
        return doc_no("company", self.id)

    def to_dict(self):
        return {"id": self.id, "name": self.name}


class Job(db.Model):
    __tablename__ = "jobs"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    # A calendar date stored as midnight; never shifted between time zones.
    date = db.Column(db.DateTime, nullable=False, default=utcnow_naive)
    status = db.Column(db.String(20), nullable=False, default="open", index=True)
    created_at = db.Column(db.DateTime, nullable=True, default=utcnow_naive)

    movements = db.relationship(
        "Movement",
        backref="job",
        order_by="Movement.created_at.desc(), Movement.id.desc()",
    )

    @property
    def doc_no(self):
        return doc_no("job", self.id)

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
    job_id = db.Column(db.Integer, db.ForeignKey("jobs.id"), nullable=True, index=True)
    company_id = db.Column(db.Integer, db.ForeignKey("company.id"), nullable=True)
    direction = db.Column(db.String(10), nullable=False)
    epcs = db.Column(db.JSON, nullable=False, default=list)
    missing_epcs = db.Column(db.JSON, nullable=True)
    note = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=utcnow_naive, index=True)

    company = db.relationship("Company")

    @property
    def doc_no(self):
        return doc_no("movement", self.id)

    def to_dict(self):
        return {
            "id": self.id,
            "jobId": self.job_id,
            "companyId": self.company_id,
            "direction": self.direction,
            "epcs": self.epcs or [],
            "missingEpcs": self.missing_epcs,
            "note": self.note,
            "createdAt": iso(self.created_at),
        }


class InventorySession(db.Model):
    __tablename__ = "inventory_sessions"

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("company.id"), nullable=True)
    batch_label = db.Column(db.String(100), nullable=False, default="")
    scanned_epcs = db.Column(db.JSON, nullable=False, default=list)
    unknown_epcs = db.Column(db.JSON, nullable=False, default=list)
    timestamp = db.Column(db.DateTime, nullable=False, default=utcnow_naive)
    created_at = db.Column(db.DateTime, nullable=False, default=utcnow_naive)

    company = db.relationship("Company")

    @property
    def doc_no(self):
        return doc_no("inventory", self.id)

    def to_dict(self):
        return {
            "id": self.id,
            "companyId": self.company_id,
            "batchLabel": self.batch_label,
            "scannedEpcs": self.scanned_epcs or [],
            "unknownEpcs": self.unknown_epcs or [],
            "timestamp": iso(self.timestamp),
            "createdAt": iso(self.created_at),
        }


class Loan(db.Model):
    """Device-loan document: one borrower, one due date, one or more items."""

    __tablename__ = "loans"

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("company.id"), nullable=True, index=True)
    borrower_name = db.Column(db.String(200), nullable=False, default="")
    contact = db.Column(db.String(200), nullable=False, default="")
    purpose = db.Column(db.String(200), nullable=False, default="")
    handled_by = db.Column(db.String(100), nullable=False, default="")
    loan_date = db.Column(db.DateTime, nullable=False, default=utcnow_naive)
    due_date = db.Column(db.Date, nullable=False)
    # active -> partial -> returned, or cancelled. Overdue is derived, never stored.
    status = db.Column(db.String(20), nullable=False, default="active", index=True)
    returned_at = db.Column(db.DateTime, nullable=True)
    note = db.Column(db.Text, nullable=False, default="")
    created_at = db.Column(db.DateTime, nullable=False, default=utcnow_naive)
    updated_at = db.Column(
        db.DateTime, nullable=False, default=utcnow_naive, onupdate=utcnow_naive
    )

    company = db.relationship("Company", back_populates="loans")
    items = db.relationship(
        "LoanItem",
        back_populates="loan",
        cascade="all, delete-orphan",
        order_by="LoanItem.id",
    )

    @property
    def doc_no(self):
        return doc_no("loan", self.id)

    @property
    def borrower_display(self):
        parts = [p for p in (self.company.name if self.company else "", self.borrower_name) if p]
        return " · ".join(parts) or "—"

    @property
    def outstanding_items(self):
        return [i for i in self.items if i.state == "out"]

    @property
    def outstanding_count(self):
        return len(self.outstanding_items)

    @property
    def item_count(self):
        return len([i for i in self.items if i.state != "cancelled"])

    @property
    def is_open(self):
        return self.status in ("active", "partial")

    @property
    def days_overdue(self):
        if not self.is_open:
            return 0
        return max(0, (local_today() - self.due_date).days)

    @property
    def is_overdue(self):
        return self.days_overdue > 0

    @property
    def days_until_due(self):
        return (self.due_date - local_today()).days

    @property
    def display_status(self):
        return "overdue" if self.is_overdue else self.status

    def to_dict(self, with_items=True):
        data = {
            "id": self.id,
            "docNo": self.doc_no,
            "companyId": self.company_id,
            "borrowerName": self.borrower_name,
            "contact": self.contact,
            "purpose": self.purpose,
            "handledBy": self.handled_by,
            "loanDate": iso(self.loan_date),
            "dueDate": iso_date(self.due_date),
            "status": self.status,
            "isOverdue": self.is_overdue,
            "returnedAt": iso(self.returned_at),
            "note": self.note,
        }
        if with_items:
            data["items"] = [item.to_dict() for item in self.items]
        return data


class LoanItem(db.Model):
    __tablename__ = "loan_items"

    id = db.Column(db.Integer, primary_key=True)
    loan_id = db.Column(db.Integer, db.ForeignKey("loans.id"), nullable=False, index=True)
    equipment_id = db.Column(
        db.Integer, db.ForeignKey("equipment.id"), nullable=False, index=True
    )
    # out -> returned | cancelled
    state = db.Column(db.String(20), nullable=False, default="out", index=True)
    returned_at = db.Column(db.DateTime, nullable=True)
    return_condition = db.Column(db.String(20), nullable=True)
    return_note = db.Column(db.String(300), nullable=False, default="")

    loan = db.relationship("Loan", back_populates="items")
    equipment = db.relationship("Equipment", back_populates="loan_items")

    def to_dict(self):
        return {
            "id": self.id,
            "equipmentId": self.equipment_id,
            "epc": self.equipment.epc,
            "name": self.equipment.name,
            "state": self.state,
            "returnedAt": iso(self.returned_at),
            "returnCondition": self.return_condition,
            "returnNote": self.return_note,
        }


class AuditLog(db.Model):
    """SAP-style change documents: who/what/when for every business object."""

    __tablename__ = "audit_log"

    id = db.Column(db.Integer, primary_key=True)
    entity_type = db.Column(db.String(30), nullable=False, index=True)
    entity_id = db.Column(db.Integer, nullable=True, index=True)
    entity_label = db.Column(db.String(200), nullable=False, default="")
    action = db.Column(db.String(30), nullable=False)
    summary = db.Column(db.Text, nullable=False, default="")
    changes = db.Column(db.JSON, nullable=True)
    source = db.Column(db.String(20), nullable=False, default="web")
    created_at = db.Column(db.DateTime, nullable=False, default=utcnow_naive, index=True)

    @property
    def doc_no(self):
        return doc_no(self.entity_type, self.entity_id) if self.entity_type in DOC_PREFIX else "—"

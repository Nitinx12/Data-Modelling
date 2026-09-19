"""utils/validation.py — Pydantic ingest-time validation for Mongo → staging.

Each Mongo collection gets a thin model that checks required fields/types.
Validated in pg_staging.py before the upsert; violations are logged (not failed)
to staging.quarantine_log so source drift (new field, changed type) is visible
before it silently reaches staging/core.

Ties to DECISIONS.md O1 (deletion propagation) and campaing_sku caveat — source
reliability, not just transform logic.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError


class StrictBase(BaseModel):
    model_config = ConfigDict(extra="allow", strict=False)


# ── Per-collection models (thin — only required keys, extra="allow") ──


class CustMaster(StrictBase):
    CustomerID: str = Field(min_length=1)
    CustomerName: str | None = None
    update_at: str | None = None


class CustomerContach(StrictBase):  # typo preserved
    CustomerID: str
    IsPrimary: bool | None = None


class UserDetails(StrictBase):
    UserID: str | None = None
    CustomerID: str | None = None


class Addres(StrictBase):  # typo preserved
    AddressID: str | None = None
    CityName: str | None = None


class City(StrictBase):
    CityName: str
    RegionName: str | None = None


class Product(StrictBase):
    ProductCode: str
    ProductName: str | None = None
    UnitPrice: float | int | str | None = None


class Order(StrictBase):
    OrderID: str
    CustomerName: str | None = None
    OrderDate: str | None = None


class OrderLineItem(StrictBase):
    OrderID: str
    LineID: str
    ProductName: str | None = None


class CampaingLog(StrictBase):
    CampaignName: str
    Date: str | None = None


class CampaingSku(StrictBase):
    CampaignName: str
    PromotedSKUs: str | None = None
    PromotedSKU: str | None = None  # seed uses both spellings


class Inventory(StrictBase):
    ProductName: str


class Shipment(StrictBase):
    OrderID: str
    ShipDate: str | None = None


class Invoice(StrictBase):
    OrderID: str | None = None
    InvoiceID: str | None = None


class Payment(StrictBase):
    InvoiceID: str | None = None
    PayDate: str | None = None


# Fallback — any doc must at least have _id
class AnyDoc(StrictBase):
    _id: Any


COLLECTION_MODELS: dict[str, type[StrictBase]] = {
    "cust_master": CustMaster,
    "customer_contach": CustomerContach,
    "user_details": UserDetails,
    "addres": Addres,
    "cities": City,
    "products": Product,
    "orders_2025": Order,
    "orders_2026": Order,
    "order_line_items": OrderLineItem,
    "campaing_logs": CampaingLog,
    "campaing_sku": CampaingSku,
    "inventory": Inventory,
    "shipments": Shipment,
    "invoices": Invoice,
    "payments": Payment,
}


def validate_docs(collection: str, docs: list[dict]) -> tuple[list[dict], list[dict]]:
    """Validate docs for a collection. Returns (valid_docs, violations).

    violations: list of {doc_id, error, doc_json} for logging to quarantine_log.
    Extra fields are allowed; only required keys/types are checked.
    """
    model = COLLECTION_MODELS.get(collection, AnyDoc)
    valid: list[dict] = []
    violations: list[dict] = []

    for doc in docs:
        try:
            # _id may be ObjectId — coerce to string for validation but keep original
            # Pydantic will accept Any for _id
            model.model_validate(doc)
            valid.append(doc)
        except ValidationError as exc:
            # Collect first error per doc (concise)
            first = (
                exc.errors()[0]
                if exc.errors()
                else {"type": "unknown", "msg": str(exc)}
            )
            loc = ".".join(str(x) for x in first.get("loc", []))
            msg = first.get("msg", str(exc))
            violations.append(
                {
                    "doc_id": str(doc.get("_id", "")),
                    "error": f"{loc}: {msg}" if loc else msg,
                    "doc_json": str(doc)[:2000],  # truncate for table
                }
            )
            # Still allow the doc through? No — quarantine it, don't load it.
            # If you prefer log-but-load, append to valid as well.
            continue
        except Exception as exc:  # noqa: BLE001
            violations.append(
                {
                    "doc_id": str(doc.get("_id", "")),
                    "error": str(exc)[:500],
                    "doc_json": str(doc)[:2000],
                }
            )

    return valid, violations


QUARANTINE_DDL = """
CREATE SCHEMA IF NOT EXISTS staging;
CREATE TABLE IF NOT EXISTS staging.quarantine_log (
    quarantine_id BIGSERIAL PRIMARY KEY,
    collection    VARCHAR(100) NOT NULL,
    doc_id        TEXT,
    error         TEXT NOT NULL,
    doc_json      TEXT,
    quarantined_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_quarantine_log_collection ON staging.quarantine_log (collection);
CREATE INDEX IF NOT EXISTS ix_quarantine_log_quarantined ON staging.quarantine_log (quarantined_at DESC);
"""

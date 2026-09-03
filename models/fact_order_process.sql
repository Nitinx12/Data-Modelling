-- =====================================================================
-- ACCUMULATING SNAPSHOT FACT LOAD SCRIPT
-- Target : core.fact_order_process (grain: one row per order)
-- Source : staging.orders_2025, staging.orders_2026 (appended),
--          staging.shipments, staging.invoices, staging.payments
-- Dim    : core.dim_customers
-- Pattern: Accumulating snapshot — unlike the SCD1 dim/fact scripts so
--          far, this row is NOT append-only. The same order row is
--          revisited and overwritten in place as it moves through the
--          pipeline (ordered -> shipped -> delivered -> invoiced -> paid).
--          OrderID / InvoiceID are degenerate dimensions (no dim table
--          of their own, just identifiers carried on the fact).
-- Assumes: OrderID is unique across the union of orders_2025/orders_2026
--          (no overlapping OrderIDs between the two yearly tables).
-- Order  : Run after core.dim_customers is loaded — this script resolves
--          customer_id via a join to it.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- =====================================================================
-- 1. DDL — core.fact_order_process
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.fact_order_process (
    order_process_key        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id                 VARCHAR(100) NOT NULL,
    customer_id              VARCHAR(50) REFERENCES core.dim_customers(customer_id),
    ship_mode                VARCHAR(100),
    invoice_id               VARCHAR(100),
    order_date               DATE,
    ship_date                DATE,
    delivery_date            DATE,
    invoice_date             DATE,
    pay_date                 DATE,
    amount                   NUMERIC(18,2),
    days_order_to_ship       INT,
    days_ship_to_delivery    INT,
    days_order_to_invoice    INT,
    days_invoice_to_pay      INT,
    dw_created_at            TIMESTAMP  NOT NULL DEFAULT now(),
    dw_updated_at            TIMESTAMP  NOT NULL DEFAULT now(),
    CONSTRAINT uq_fact_order_process_order_id UNIQUE (order_id)
);

COMMENT ON TABLE core.fact_order_process IS 'Accumulating snapshot fact — tracks an order through its fulfillment pipeline (order -> ship -> deliver -> invoice -> pay). Grain: one row per order, updated in place as milestones occur.';

CREATE INDEX IF NOT EXISTS ix_fact_order_process_customer ON core.fact_order_process (customer_id);
CREATE INDEX IF NOT EXISTS ix_fact_order_process_invoice  ON core.fact_order_process (invoice_id);
CREATE INDEX IF NOT EXISTS ix_fact_order_process_order_dt ON core.fact_order_process (order_date);

-- Quarantine table: orders whose OrderDate is impossible (in the future
-- as of load time). Root cause lives upstream in whatever seeds
-- staging.orders_2025/2026 — this table just stops that bad data from
-- silently entering the fact table, and keeps a visible trail of it.
CREATE TABLE IF NOT EXISTS core.fact_order_process_rejects (
    order_id       VARCHAR(100) NOT NULL,
    order_date     DATE,
    reject_reason  VARCHAR(200) NOT NULL,
    detected_at    TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT uq_fact_order_process_rejects_order_id UNIQUE (order_id)
);

-- Quarantine table: payments whose PayDate is impossible (a completed
-- payment can't be dated in the future). Same rationale as the orders
-- quarantine above — the bad PayDate is dropped from the fact rather
-- than loaded, and kept here for visibility instead of vanishing.
CREATE TABLE IF NOT EXISTS core.fact_order_process_payment_rejects (
    invoice_id     VARCHAR(100) NOT NULL,
    pay_date       DATE,
    reject_reason  VARCHAR(200) NOT NULL,
    detected_at    TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT uq_fact_order_process_payment_rejects_invoice_id UNIQUE (invoice_id)
);

-- Quarantine table: shipment/invoice milestone dates (ShipDate,
-- DeliveryDate, InvoiceDate) that are impossible (in the future).
-- One generic table, keyed by which field tripped it, since any of
-- the three can be bad independently on an otherwise valid order.
CREATE TABLE IF NOT EXISTS core.fact_order_process_milestone_rejects (
    order_id       VARCHAR(100) NOT NULL,
    field_name     VARCHAR(50) NOT NULL,
    bad_date       DATE,
    reject_reason  VARCHAR(200) NOT NULL,
    detected_at    TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT uq_fact_order_process_milestone_rejects UNIQUE (order_id, field_name)
);


-- =====================================================================
-- 2. STAGE + FLAG — split orders into valid vs. future-dated
-- =====================================================================
DROP TABLE IF EXISTS tmp_orders_flagged;
CREATE TEMP TABLE tmp_orders_flagged AS
SELECT
    "OrderID",
    "CustomerName",
    "OrderDate",
    (NULLIF("OrderDate", '')::DATE > CURRENT_DATE) AS is_future_dated
FROM (
    SELECT "OrderID", "CustomerName", "OrderDate" FROM staging.orders_2025
    UNION ALL
    SELECT "OrderID", "CustomerName", "OrderDate" FROM staging.orders_2026
) AS u;

INSERT INTO core.fact_order_process_rejects (order_id, order_date, reject_reason)
SELECT
    "OrderID",
    NULLIF("OrderDate", '')::DATE,
    'order_date is in the future as of load time'
FROM tmp_orders_flagged
WHERE is_future_dated
ON CONFLICT (order_id) DO NOTHING;

-- Self-heal: this quarantine logic didn't always exist, so remove any
-- rows that were loaded into the fact table by an earlier run of this
-- script before they were flagged as future-dated.
DELETE FROM core.fact_order_process AS f
USING tmp_orders_flagged AS t
WHERE t."OrderID" = f.order_id
  AND t.is_future_dated;


-- =====================================================================
-- 2b. STAGE + CLEAN — dedup payments, null out impossible PayDates
-- =====================================================================
DROP TABLE IF EXISTS tmp_payments_final;
CREATE TEMP TABLE tmp_payments_final AS
SELECT
    p.*,
    CASE WHEN p.pay_date_parsed > CURRENT_DATE THEN NULL ELSE p.pay_date_parsed END AS pay_date_clean
FROM (
    SELECT
        *,
        NULLIF("PayDate", '')::DATE AS pay_date_parsed,
        ROW_NUMBER() OVER (
            PARTITION BY "InvoiceID" ORDER BY NULLIF("PayDate", '')::DATE DESC NULLS LAST
        ) AS rnk
    FROM staging.payments
) AS p
WHERE p.rnk = 1;

INSERT INTO core.fact_order_process_payment_rejects (invoice_id, pay_date, reject_reason)
SELECT
    "InvoiceID",
    pay_date_parsed,
    'PayDate is in the future as of load time (a completed payment cannot be dated ahead)'
FROM tmp_payments_final
WHERE pay_date_parsed > CURRENT_DATE
ON CONFLICT (invoice_id) DO NOTHING;

-- No self-heal DELETE needed here, unlike orders: the row itself stays
-- valid (order/invoice can be real even if the payment record is bad),
-- so the UPSERT below simply overwrites any previously-loaded bad
-- pay_date with NULL once pay_date_clean resolves to NULL for it.


-- =====================================================================
-- 2c. STAGE + CLEAN — dedup shipments, null out impossible ship/delivery dates
-- =====================================================================
DROP TABLE IF EXISTS tmp_shipments_final;
CREATE TEMP TABLE tmp_shipments_final AS
SELECT
    s.*,
    CASE WHEN s.ship_date_parsed     > CURRENT_DATE THEN NULL ELSE s.ship_date_parsed     END AS ship_date_clean,
    CASE WHEN s.delivery_date_parsed > CURRENT_DATE THEN NULL ELSE s.delivery_date_parsed END AS delivery_date_clean
FROM (
    SELECT
        *,
        NULLIF("ShipDate", '')::DATE     AS ship_date_parsed,
        NULLIF("DeliveryDate", '')::DATE AS delivery_date_parsed,
        ROW_NUMBER() OVER (
            PARTITION BY "OrderID" ORDER BY NULLIF("ShipDate", '')::DATE DESC NULLS LAST
        ) AS rnk
    FROM staging.shipments
) AS s
WHERE s.rnk = 1;

INSERT INTO core.fact_order_process_milestone_rejects (order_id, field_name, bad_date, reject_reason)
SELECT "OrderID", 'ship_date', ship_date_parsed, 'ShipDate is in the future as of load time'
FROM tmp_shipments_final
WHERE ship_date_parsed > CURRENT_DATE

UNION ALL

SELECT "OrderID", 'delivery_date', delivery_date_parsed, 'DeliveryDate is in the future as of load time'
FROM tmp_shipments_final
WHERE delivery_date_parsed > CURRENT_DATE
ON CONFLICT (order_id, field_name) DO NOTHING;


-- =====================================================================
-- 2d. STAGE + CLEAN — dedup invoices, null out impossible invoice dates
-- =====================================================================
DROP TABLE IF EXISTS tmp_invoices_final;
CREATE TEMP TABLE tmp_invoices_final AS
SELECT
    i.*,
    CASE WHEN i.invoice_date_parsed > CURRENT_DATE THEN NULL ELSE i.invoice_date_parsed END AS invoice_date_clean
FROM (
    SELECT
        *,
        NULLIF("InvoiceDate", '')::DATE AS invoice_date_parsed,
        ROW_NUMBER() OVER (
            PARTITION BY "OrderID" ORDER BY NULLIF("InvoiceDate", '')::DATE DESC NULLS LAST
        ) AS rnk
    FROM staging.invoices
) AS i
WHERE i.rnk = 1;

INSERT INTO core.fact_order_process_milestone_rejects (order_id, field_name, bad_date, reject_reason)
SELECT "OrderID", 'invoice_date', invoice_date_parsed, 'InvoiceDate is in the future as of load time'
FROM tmp_invoices_final
WHERE invoice_date_parsed > CURRENT_DATE
ON CONFLICT (order_id, field_name) DO NOTHING;

-- No self-heal DELETE needed for shipments/invoices either, same
-- reasoning as payments — the order row stays, only the offending
-- column gets overwritten to NULL by the UPSERT below.


-- =====================================================================
-- 3. UPSERT — core.fact_order_process (valid orders only)
-- =====================================================================
WITH orders_unioned AS (
    SELECT "OrderID", "CustomerName", "OrderDate"
    FROM tmp_orders_flagged
    WHERE NOT is_future_dated
)
INSERT INTO core.fact_order_process (
    order_id,
    customer_id,
    ship_mode,
    invoice_id,
    order_date,
    ship_date,
    delivery_date,
    invoice_date,
    pay_date,
    amount,
    days_order_to_ship,
    days_ship_to_delivery,
    days_order_to_invoice,
    days_invoice_to_pay
)
SELECT
    A."OrderID",
    C.customer_id,
    S."ShipMode",
    I."InvoiceID",
    NULLIF(A."OrderDate", '')::DATE,
    S.ship_date_clean,
    S.delivery_date_clean,
    I.invoice_date_clean,
    P.pay_date_clean,
    I."Amount",
    (S.ship_date_clean - NULLIF(A."OrderDate", '')::DATE),
    (S.delivery_date_clean - S.ship_date_clean),
    (I.invoice_date_clean - NULLIF(A."OrderDate", '')::DATE),
    (P.pay_date_clean - I.invoice_date_clean)
FROM orders_unioned AS A
LEFT JOIN core.dim_customers AS C
    ON C.customer_name = A."CustomerName"
LEFT JOIN tmp_shipments_final AS S
    ON S."OrderID" = A."OrderID"
LEFT JOIN tmp_invoices_final AS I
    ON I."OrderID" = A."OrderID"
LEFT JOIN tmp_payments_final AS P
    ON I."InvoiceID" = P."InvoiceID"
ON CONFLICT (order_id) DO UPDATE SET
    customer_id             = EXCLUDED.customer_id,
    ship_mode               = EXCLUDED.ship_mode,
    invoice_id              = EXCLUDED.invoice_id,
    ship_date               = EXCLUDED.ship_date,
    delivery_date           = EXCLUDED.delivery_date,
    invoice_date            = EXCLUDED.invoice_date,
    pay_date                = EXCLUDED.pay_date,
    amount                  = EXCLUDED.amount,
    days_order_to_ship      = EXCLUDED.days_order_to_ship,
    days_ship_to_delivery   = EXCLUDED.days_ship_to_delivery,
    days_order_to_invoice   = EXCLUDED.days_order_to_invoice,
    days_invoice_to_pay     = EXCLUDED.days_invoice_to_pay,
    dw_updated_at           = now()
WHERE core.fact_order_process.ship_date     IS DISTINCT FROM EXCLUDED.ship_date
   OR core.fact_order_process.delivery_date IS DISTINCT FROM EXCLUDED.delivery_date
   OR core.fact_order_process.invoice_date  IS DISTINCT FROM EXCLUDED.invoice_date
   OR core.fact_order_process.pay_date      IS DISTINCT FROM EXCLUDED.pay_date
   OR core.fact_order_process.amount        IS DISTINCT FROM EXCLUDED.amount;


DROP TABLE IF EXISTS tmp_orders_flagged;
DROP TABLE IF EXISTS tmp_payments_final;
DROP TABLE IF EXISTS tmp_shipments_final;
DROP TABLE IF EXISTS tmp_invoices_final;


-- =====================================================================
-- 4. Verification
-- =====================================================================
-- SELECT COUNT(*) FROM core.fact_order_process;
-- SELECT * FROM core.fact_order_process ORDER BY order_date LIMIT 20;
-- SELECT COUNT(*) FROM core.fact_order_process WHERE customer_id IS NULL;   -- unmatched customers
-- SELECT COUNT(*) FROM core.fact_order_process WHERE ship_date IS NULL;     -- not yet shipped
-- SELECT COUNT(*) FROM core.fact_order_process WHERE pay_date  IS NULL;     -- not yet paid
-- SELECT * FROM core.fact_order_process_rejects ORDER BY order_date DESC;   -- quarantined future-dated orders
-- SELECT * FROM core.fact_order_process_payment_rejects ORDER BY pay_date DESC;    -- quarantined future-dated payments
-- SELECT * FROM core.fact_order_process_milestone_rejects ORDER BY detected_at DESC; -- quarantined future ship/delivery/invoice dates
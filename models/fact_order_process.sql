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
DROP TABLE IF EXISTS core.fact_order_process CASCADE;

CREATE TABLE IF NOT EXISTS core.fact_order_process (
    order_process_key        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id                 VARCHAR(100) NOT NULL,
    customer_key            BIGINT REFERENCES core.dim_customers(customer_key),
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

CREATE INDEX IF NOT EXISTS ix_fact_order_process_customer ON core.fact_order_process (customer_key);
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

-- Self-heal for payments: if a previously-loaded pay_date later turns out
-- to be future-dated garbage (now quarantined above), clear it from the
-- fact explicitly. The UPSERT below COALESCE-guards milestone columns so a
-- NULL from the source can no longer overwrite a real milestone — which
-- means the old "overwrite with NULL" cleanup path had to become explicit.
UPDATE core.fact_order_process AS f
SET    pay_date          = NULL,
       days_invoice_to_pay = NULL,
       dw_updated_at     = now()
FROM   core.fact_order_process_payment_rejects AS r
WHERE  f.invoice_id = r.invoice_id
  AND  f.pay_date   = r.pay_date;


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

-- Self-heal for shipments/invoices, same explicit form as payments above:
-- previously-loaded future-dated milestone dates are cleared directly,
-- because the COALESCE-guarded UPSERT below no longer overwrites them
-- with NULL on its own.
UPDATE core.fact_order_process AS f
SET    ship_date           = NULL,
       days_order_to_ship  = NULL,
       dw_updated_at       = now()
FROM   core.fact_order_process_milestone_rejects AS r
WHERE  r.field_name = 'ship_date'
  AND  f.order_id   = r.order_id
  AND  f.ship_date  = r.bad_date;

UPDATE core.fact_order_process AS f
SET    delivery_date         = NULL,
       days_ship_to_delivery = NULL,
       dw_updated_at         = now()
FROM   core.fact_order_process_milestone_rejects AS r
WHERE  r.field_name  = 'delivery_date'
  AND  f.order_id    = r.order_id
  AND  f.delivery_date = r.bad_date;

UPDATE core.fact_order_process AS f
SET    invoice_date          = NULL,
       days_order_to_invoice = NULL,
       days_invoice_to_pay   = NULL,
       dw_updated_at         = now()
FROM   core.fact_order_process_milestone_rejects AS r
WHERE  r.field_name  = 'invoice_date'
  AND  f.order_id    = r.order_id
  AND  f.invoice_date = r.bad_date;


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
    customer_key,
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
    C.customer_key,
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
-- COALESCE guard: this is an accumulating snapshot, so a milestone that
-- has NOT happened yet arrives as NULL from the source. An unconditional
-- SET would overwrite a previously-loaded real milestone (order shipped,
-- then a re-run without that shipment row nulls ship_date again) and
-- silently destroy the lags with it. EXCLUDED.x wins when the source has
-- a value; the existing value survives otherwise. Only amount stays a
-- plain overwrite — it's a measure, not a milestone, and a corrected
-- amount should replace the old one.
-- The lag columns are recomputed from the COALESCE-guarded dates, not
-- the raw EXCLUDED ones, so they can never disagree with the dates
-- actually stored.
-- The WHERE guard covers customer_key/ship_mode/invoice_id too — they
-- were previously updated but not guarded, so a change to them alone
-- (milestones and amount unchanged) was silently skipped.
ON CONFLICT (order_id) DO UPDATE SET
    customer_key             = COALESCE(EXCLUDED.customer_key, core.fact_order_process.customer_key),
    ship_mode                = COALESCE(EXCLUDED.ship_mode, core.fact_order_process.ship_mode),
    invoice_id               = COALESCE(EXCLUDED.invoice_id, core.fact_order_process.invoice_id),
    ship_date                = COALESCE(EXCLUDED.ship_date, core.fact_order_process.ship_date),
    delivery_date            = COALESCE(EXCLUDED.delivery_date, core.fact_order_process.delivery_date),
    invoice_date             = COALESCE(EXCLUDED.invoice_date, core.fact_order_process.invoice_date),
    pay_date                 = COALESCE(EXCLUDED.pay_date, core.fact_order_process.pay_date),
    amount                   = EXCLUDED.amount,
    days_order_to_ship       = (COALESCE(EXCLUDED.ship_date,     core.fact_order_process.ship_date)
                              - core.fact_order_process.order_date),
    days_ship_to_delivery    = (COALESCE(EXCLUDED.delivery_date, core.fact_order_process.delivery_date)
                              - COALESCE(EXCLUDED.ship_date,     core.fact_order_process.ship_date)),
    days_order_to_invoice    = (COALESCE(EXCLUDED.invoice_date,  core.fact_order_process.invoice_date)
                              - core.fact_order_process.order_date),
    days_invoice_to_pay      = (COALESCE(EXCLUDED.pay_date,      core.fact_order_process.pay_date)
                              - COALESCE(EXCLUDED.invoice_date,  core.fact_order_process.invoice_date)),
    dw_updated_at            = now()
WHERE core.fact_order_process.customer_key IS DISTINCT FROM EXCLUDED.customer_key
   OR core.fact_order_process.ship_mode    IS DISTINCT FROM EXCLUDED.ship_mode
   OR core.fact_order_process.invoice_id   IS DISTINCT FROM EXCLUDED.invoice_id
   OR core.fact_order_process.ship_date     IS DISTINCT FROM EXCLUDED.ship_date
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
-- SELECT COUNT(*) FROM core.fact_order_process WHERE customer_key IS NULL;   -- unmatched customers
-- SELECT COUNT(*) FROM core.fact_order_process WHERE ship_date IS NULL;     -- not yet shipped
-- SELECT COUNT(*) FROM core.fact_order_process WHERE pay_date  IS NULL;     -- not yet paid
-- SELECT * FROM core.fact_order_process_rejects ORDER BY order_date DESC;   -- quarantined future-dated orders
-- SELECT * FROM core.fact_order_process_payment_rejects ORDER BY pay_date DESC;    -- quarantined future-dated payments
-- SELECT * FROM core.fact_order_process_milestone_rejects ORDER BY detected_at DESC; -- quarantined future ship/delivery/invoice dates
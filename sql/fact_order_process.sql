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


-- =====================================================================
-- 2. UPSERT — core.fact_order_process
-- =====================================================================
WITH orders_unioned AS (
    SELECT "OrderID", "CustomerName", "OrderDate"
    FROM staging.orders_2025

    UNION ALL

    SELECT "OrderID", "CustomerName", "OrderDate"
    FROM staging.orders_2026
),
shipments_dedup AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY "OrderID" ORDER BY NULLIF("ShipDate", '')::DATE DESC
        ) AS rnk
    FROM staging.shipments
),
shipments_final AS (
    SELECT * FROM shipments_dedup WHERE rnk = 1
),
invoices_dedup AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY "OrderID" ORDER BY NULLIF("InvoiceDate", '')::DATE DESC
        ) AS rnk
    FROM staging.invoices
),
invoices_final AS (
    SELECT * FROM invoices_dedup WHERE rnk = 1
),
payments_dedup AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY "InvoiceID" ORDER BY NULLIF("PayDate", '')::DATE DESC
        ) AS rnk
    FROM staging.payments
),
payments_final AS (
    SELECT * FROM payments_dedup WHERE rnk = 1
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
    NULLIF(S."ShipDate", '')::DATE,
    NULLIF(S."DeliveryDate", '')::DATE,
    NULLIF(I."InvoiceDate", '')::DATE,
    NULLIF(P."PayDate", '')::DATE,
    I."Amount",
    (NULLIF(S."ShipDate", '')::DATE - NULLIF(A."OrderDate", '')::DATE),
    (NULLIF(S."DeliveryDate", '')::DATE - NULLIF(S."ShipDate", '')::DATE),
    (NULLIF(I."InvoiceDate", '')::DATE - NULLIF(A."OrderDate", '')::DATE),
    (NULLIF(P."PayDate", '')::DATE - NULLIF(I."InvoiceDate", '')::DATE)
FROM orders_unioned AS A
LEFT JOIN core.dim_customers AS C
    ON C.customer_name = A."CustomerName"
LEFT JOIN shipments_final AS S
    ON S."OrderID" = A."OrderID"
LEFT JOIN invoices_final AS I
    ON I."OrderID" = A."OrderID"
LEFT JOIN payments_final AS P
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


-- =====================================================================
-- 3. Verification
-- =====================================================================
-- SELECT COUNT(*) FROM core.fact_order_process;
-- SELECT * FROM core.fact_order_process ORDER BY order_date LIMIT 20;
-- SELECT COUNT(*) FROM core.fact_order_process WHERE customer_id IS NULL;   -- unmatched customers
-- SELECT COUNT(*) FROM core.fact_order_process WHERE ship_date IS NULL;     -- not yet shipped
-- SELECT COUNT(*) FROM core.fact_order_process WHERE pay_date  IS NULL;     -- not yet paid
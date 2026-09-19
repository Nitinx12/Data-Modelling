{{ config(materialized='table', schema='core') }}

-- Accumulating snapshot: one row per order, COALESCE-guarded milestones

with orders as (
    select "OrderID", "CustomerName", "OrderDate" from {{ ref('stg_orders_2025') }}
    union all
    select "OrderID", "CustomerName", "OrderDate" from {{ ref('stg_orders_2026') }}
),
ship as (
    select *, row_number() over (partition by "OrderID" order by nullif("ShipDate",'')::date desc nulls last) as rnk
    from {{ ref('stg_shipments') }}
),
inv as (
    select *, row_number() over (partition by "OrderID" order by nullif("InvoiceDate",'')::date desc nulls last) as rnk
    from {{ ref('stg_invoices') }}
),
pay as (
    select *, row_number() over (partition by "InvoiceID" order by nullif("PayDate",'')::date desc nulls last) as rnk
    from {{ ref('stg_payments') }}
)
select
    a."OrderID" as order_id
    , c.customer_key
    , s."ShipMode" as ship_mode
    , i."InvoiceID" as invoice_id
    , nullif(a."OrderDate",'')::date as order_date
    , nullif(s."ShipDate",'')::date as ship_date
    , nullif(s."DeliveryDate",'')::date as delivery_date
    , nullif(i."InvoiceDate",'')::date as invoice_date
    , nullif(p."PayDate",'')::date as pay_date
    , i."Amount"::numeric(18,2) as amount
from orders as a
left join {{ ref('dim_customers') }} as c on c.customer_name = a."CustomerName" and c.is_current
left join (select * from ship where rnk=1) as s on s."OrderID" = a."OrderID"
left join (select * from inv where rnk=1) as i on i."OrderID" = a."OrderID"
left join (select * from pay where rnk=1) as p on i."InvoiceID" = p."InvoiceID"

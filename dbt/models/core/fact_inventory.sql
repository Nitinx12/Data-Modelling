{{ config(materialized='table', schema='core') }}

-- Periodic snapshot: one row per product per month

with dedup as (
    select *, row_number() over (partition by "ProductName" order by "update_at" desc nulls last) as rnk
    from {{ ref('stg_inventory') }}
),
unpivoted as (
    select
        t."ProductName"
        , u.period
        , u.quantity
        , t."update_at"
    from (select * from dedup where rnk = 1) as t
    cross join lateral (values
        ('2025-01', t."2025-01"), ('2025-02', t."2025-02"), ('2025-03', t."2025-03"),
        ('2025-04', t."2025-04"), ('2025-05', t."2025-05"), ('2025-06', t."2025-06"),
        ('2025-07', t."2025-07"), ('2025-08', t."2025-08"), ('2025-09', t."2025-09"),
        ('2025-10', t."2025-10"), ('2025-11', t."2025-11"), ('2025-12', t."2025-12")
    ) as u(period, quantity)
)
select
    p.product_key
    , i."ProductName" as product_name
    , to_date(i.period || '-01', 'YYYY-MM-DD') as period_month
    , i.quantity
    , nullif(i."update_at", '')::timestamp as source_updated_at
from unpivoted as i
left join {{ ref('dim_products') }} as p
    on p.product_name = i."ProductName"

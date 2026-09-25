{{ config(materialized='table', schema='core') }}

-- Junk dimension dim_orders_flag

with orders as (
    select "OrderChannel", "Status", "Priority" from {{ ref('stg_orders_2025') }}
    union all
    select "OrderChannel", "Status", "Priority" from {{ ref('stg_orders_2026') }}
),
distinct_flags as (
    select distinct "OrderChannel", "Status", "Priority" from orders
)
select
    f."OrderChannel" as channel_code
    , c.channel_name as channel_name
    , f."Status" as status
    , f."Priority" as priority
from distinct_flags as f
left join {{ ref('stg_channels') }} as c
    on c.channel_id = f."OrderChannel"

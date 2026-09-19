{{ config(materialized='table', schema='core') }}

-- Transaction fact: one row per order line, SCD2 as-of join to dim_customers

with orders as (
    select
        *
        , row_number() over (partition by "OrderID" order by "update_at" desc nulls last) as rnk
        , (nullif("OrderDate", '')::date > current_date) as is_future_dated
    from (
        select "_id", "OrderID", "CustomerName", "ShipToCity", "BillToCity", "OrderDate", "OrderChannel", "Status", "Priority", "update_at" from {{ ref('stg_orders_2025') }}
        union all
        select "_id", "OrderID", "CustomerName", "ShipToCity", "BillToCity", "OrderDate", "OrderChannel", "Status", "Priority", "update_at" from {{ ref('stg_orders_2026') }}
    ) as u
),
orders_final as (select * from orders where rnk = 1 and not is_future_dated),
lines as (
    select *, row_number() over (partition by "LineID" order by "update_at" desc nulls last) as rnk
    from {{ ref('stg_order_line_items') }}
),
lines_final as (select * from lines where rnk = 1)
select distinct on (o."OrderID", l."LineID")
    o."OrderID" as order_id
    , l."LineID" as line_id
    , nullif(o."OrderDate", '')::date as order_date
    , l."Quantity" as quantity
    , l."UnitPrice" as unit_price
    , l."UnitCost" as unit_cost
    , l."DiscountPct" as discount_pct
    , l."LineTotal" as line_total
    , c.customer_key
    , coalesce(p.product_key, unk.product_key) as product_key
    , f.flag_key
    , sg.geo_key as ship_geo_key
    , bg.geo_key as bill_geo_key
    , coalesce(nullif(l."update_at",'')::timestamp, nullif(o."update_at",'')::timestamp) as source_updated_at
from orders_final as o
left join lines_final as l on o."OrderID" = l."OrderID"
-- SCD2 as-of: pick version valid at order_date
left join lateral (
    select d.customer_key
    from {{ ref('dim_customers') }} as d
    where d.customer_name = o."CustomerName"
    order by
        case when d.valid_from::date <= nullif(o."OrderDate",'')::date
                  and (d.valid_to is null or d.valid_to::date > nullif(o."OrderDate",'')::date) then 0
             when d.is_current then 1 else 2 end
        , d.valid_from desc
    limit 1
) as c on true
left join (
    select product_name, min(product_key) as product_key
    from {{ ref('dim_products') }} group by product_name
) as p on p.product_name = l."ProductName"
cross join (select product_key from {{ ref('dim_products') }} where product_code = 'UNKNOWN') as unk
left join {{ ref('dim_orders_flag') }} as f
    on o."OrderChannel" = f.channel_code and o."Status" = f.status and o."Priority" = f.priority
left join {{ ref('dim_geo') }} as sg on sg.city_name = o."ShipToCity"
left join {{ ref('dim_geo') }} as bg on bg.city_name = o."BillToCity"
where l."LineID" is not null
order by o."OrderID", l."LineID", coalesce(nullif(l."update_at",'')::timestamp, nullif(o."update_at",'')::timestamp) desc

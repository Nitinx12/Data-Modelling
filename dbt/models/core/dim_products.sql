{{ config(materialized='table', schema='core') }}

-- SCD1 dim_products — dbt mirror of models/dim_products.sql

with base as (
    select
        p."ProductCode"
        , p."ProductName"
        , p."Brand"
        , initcap(s."category") as category
        , p."SubcategoryName"
        , p."PrimarySupplier"
        , p."UnitPrice"
        , p."update_at"
    from {{ ref('stg_products') }} as p
    left join {{ ref('stg_subcategory') }} as s
        on p."SubcategoryName" = initcap(s."subcategory")
    where p."ProductCode" not ilike 'ZZZ%'
      and p."ProductName" not ilike 'DO NOT USE%'
)
select
    "ProductCode" as product_code
    , "ProductName" as product_name
    , "Brand" as brand
    , category
    , "SubcategoryName" as subcategory_name
    , "PrimarySupplier" as primary_supplier
    , nullif("UnitPrice", 0)::numeric(14,2) as unit_price
    , nullif("update_at", '')::timestamp as source_updated_at
from base

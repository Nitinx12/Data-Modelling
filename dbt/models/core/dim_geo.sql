{{ config(materialized='table', schema='core') }}

-- SCD1 dim_geo — role-playing dimension

with ranked as (
    select
        "CityName"
        , "RegionName"
        , "update_at"
        , row_number() over (partition by "CityName" order by "update_at" desc nulls last) as rnk
    from {{ ref('stg_cities') }}
)
select
    "CityName" as city_name
    , "RegionName" as region_name
    , nullif("update_at", '')::timestamp as source_updated_at
from ranked
where rnk = 1

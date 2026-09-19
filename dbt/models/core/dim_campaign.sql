{{ config(materialized='table', schema='core') }}

-- SCD1 dim_campaign

with ranked as (
    select
        "CampaignName"
        , "Channel"
        , "StartDate"
        , "EndDate"
        , "Budget"
        , "update_at"
        , row_number() over (partition by "CampaignName" order by "update_at" desc nulls last) as rnk
    from {{ ref('stg_campaing_logs') }}
)
select
    "CampaignName" as campaign_name
    , "Channel" as channel
    , nullif("StartDate", '')::date as start_date
    , nullif("EndDate", '')::date as end_date
    , "Budget"::numeric(18,2) as budget
    , nullif("update_at", '')::timestamp as source_updated_at
from ranked
where rnk = 1

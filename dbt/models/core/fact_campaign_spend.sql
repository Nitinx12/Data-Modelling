{{ config(materialized='table', schema='core') }}

-- Transaction fact: one row per campaign per day

with dedup as (
    select
        *
        , row_number() over (partition by "CampaignName", "Date" order by "update_at" desc nulls last) as rnk
    from {{ ref('stg_campaing_logs') }}
)
select
    d.campaign_key
    , s."CampaignName" as campaign_name
    , nullif(s."Date", '')::date as spend_date
    , s."Impressions" as impressions
    , s."Clicks" as clicks
    , s."Spend"::numeric(18,2) as spend
    , nullif(s."update_at", '')::timestamp as source_updated_at
from dedup as s
left join {{ ref('dim_campaign') }} as d
    on d.campaign_name = s."CampaignName"
where s.rnk = 1

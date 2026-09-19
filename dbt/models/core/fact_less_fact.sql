{{ config(materialized='table', schema='core') }}

-- Factless fact: one row per campaign-promoted-SKU pair (no measures)

select distinct
    dc.campaign_key
    , p.product_key
    , cs."CampaignName" as campaign_name
    , cs."PromotedSKUs" as promoted_sku
from {{ ref('stg_campaing_sku') }} as cs
join {{ ref('dim_campaign') }} as dc
    on cs."CampaignName" = dc.campaign_name
join {{ ref('dim_products') }} as p
    on cs."PromotedSKUs" = p.product_code

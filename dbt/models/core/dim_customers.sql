{{ config(materialized='table', schema='core') }}

-- SCD2 dim_customers — dbt mirror of models/dim_customers.sql
-- Hand-built PL/pgSQL in models/ is the source of truth; this uses ref() for lineage.
-- For dbt, we materialize the current state (is_current) — production SCD2 would be a snapshot.

with merge_quries as (
    select
        cu."CustomerID"
        , cu."CustomerName"
        , cu."Segment"
        , cu."AccountManager"
        , cu."PaymentTerms"
        , cc."Email"
        , ud."Phone"
        , ud."CreditLimit"
        , a."Street"
        , c."CityName"
        , c."RegionName"
        , a."update_at"
    from {{ ref('stg_cust_master') }} as cu
    left join {{ ref('stg_customer_contach') }} as cc
        on cu."CustomerID" = cc."CustomerID" and cc."IsPrimary" = true
    left join {{ ref('stg_user_details') }} as ud
        on ud."UserID" = cu."CustomerID"
    left join {{ ref('stg_addres') }} as a
        on a."AddressID" = cu."AddressID"
    left join {{ ref('stg_cities') }} as c
        on c."CityName" = a."CityName"
),
ranked as (
    select
        *
        , row_number() over (partition by "CustomerID" order by "update_at" desc nulls last) as rnk
    from merge_quries
)
select
    "CustomerID" as customer_id
    , "CustomerName" as customer_name
    , "Segment" as segment
    , "AccountManager" as account_manager
    , "PaymentTerms" as payment_terms
    , "Email" as email
    , "Phone" as phone
    , nullif("CreditLimit", 0)::numeric(14,2) as credit_limit
    , "Street" as street
    , "CityName" as city_name
    , "RegionName" as region_name
    , nullif("update_at", '')::timestamp as source_updated_at
    , now() as valid_from
    , null::timestamp as valid_to
    , true as is_current
from ranked
where rnk = 1

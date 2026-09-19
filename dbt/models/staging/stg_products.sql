select * from {{ source('staging', 'products') }}

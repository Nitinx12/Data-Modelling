select * from {{ source('staging', 'inventory') }}

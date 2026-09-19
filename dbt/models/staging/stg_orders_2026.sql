select * from {{ source('staging', 'orders_2026') }}

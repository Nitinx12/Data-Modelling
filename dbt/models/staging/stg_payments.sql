select * from {{ source('staging', 'payments') }}

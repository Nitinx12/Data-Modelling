select * from {{ source('staging', 'shipments') }}

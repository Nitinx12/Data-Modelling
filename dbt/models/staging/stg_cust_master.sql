select * from {{ source('staging', 'cust_master') }}

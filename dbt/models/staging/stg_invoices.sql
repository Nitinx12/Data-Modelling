select * from {{ source('staging', 'invoices') }}

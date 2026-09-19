select * from {{ source('staging', 'channels') }}

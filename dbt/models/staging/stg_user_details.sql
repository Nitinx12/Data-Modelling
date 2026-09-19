select * from {{ source('staging', 'user_details') }}

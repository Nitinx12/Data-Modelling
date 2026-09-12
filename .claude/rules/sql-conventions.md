---
paths:
  - "models/**/*.sql"
  - "sql/**/*.sql"
  - "tests/sql/**/*.sql"
---

# SQL conventions

- Most facts join `dim_customers` / `dim_products` by name, not by business ID.
  This is documented, not accidental — don't switch a join to use `customer_id`
  or `product_code` without flagging it first.
- `dim_products` nulls out an invalid `unit_price` (blank, zero, negative) but
  keeps the row; `dim_customers` keeps rows with a NULL `update_at` from the
  address table. Neither drops rows anymore — the earlier drop-style filters
  were removed deliberately. Don't reintroduce silent row exclusion.
- Full table by table grain, source, and caveat reference: `docs/data_catlog.md`.
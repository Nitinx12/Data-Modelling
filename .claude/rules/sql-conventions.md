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
- `dim_products` load filters out any row with NULL or zero `unit_price`.
  `dim_customers` load drops rows with NULL `update_at`. Both are intentional
  and silent by design — don't "fix" by relaxing the WHERE clause.
- Full table by table grain, source, and caveat reference: `docs/data_catlog.md`.
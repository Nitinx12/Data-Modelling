-- =====================================================================
-- AD HOC: Month-over-month inventory movement
-- Source : core.fact_inventory + core.dim_products
-- Use    : Spot fast depleting stock or unexpected build-ups.
--          Flip the WHERE to mom_change < 0 to focus on shrinking stock.
-- =====================================================================
SELECT
    p.product_name,
    p.category,
    fi.period_month,
    fi.quantity,
    LAG(fi.quantity) OVER (
        PARTITION BY fi.product_key ORDER BY fi.period_month
    )                                                    AS prior_month_quantity,
    fi.quantity - LAG(fi.quantity) OVER (
        PARTITION BY fi.product_key ORDER BY fi.period_month
    )                                                    AS mom_change
FROM core.fact_inventory fi
JOIN core.dim_products p
    ON fi.product_key = p.product_key
ORDER BY p.product_name, fi.period_month;

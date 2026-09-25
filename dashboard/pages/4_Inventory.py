import sys
from pathlib import Path

import streamlit as st

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.charts import box_chart, heatmap_chart, line_chart, wide
from lib.db import run_query

st.set_page_config(page_title="Inventory", page_icon="📦", layout="wide")
st.title("📦 Inventory — periodic snapshot (one row per product per month)")
st.caption(
    "`core.fact_inventory` grain is product × month (2025-01 … 2025-12 unpivoted via CROSS JOIN LATERAL). dim_products → fact_inventory."
)

with st.spinner("Loading inventory…"):
    try:
        # Filter by category if desired
        categories = run_query(
            "SELECT DISTINCT category FROM core.dim_products WHERE category IS NOT NULL ORDER BY 1"
        )
        with st.sidebar:
            cat = st.selectbox(
                "Category",
                ["All"] + categories["category"].tolist()
                if not categories.empty
                else ["All"],
            )

        # Trend per product
        if cat != "All":
            trend = run_query(
                """
                SELECT period_month, p.product_name, f.quantity
                FROM core.fact_inventory f
                LEFT JOIN core.dim_products p ON p.product_key = f.product_key
                WHERE p.category = :cat
                ORDER BY period_month
                """,
                params={"cat": cat},
            )
        else:
            trend = run_query(
                """
                SELECT period_month, p.product_name, f.quantity
                FROM core.fact_inventory f
                LEFT JOIN core.dim_products p ON p.product_key = f.product_key
                ORDER BY period_month
                """
            )

        if not trend.empty:
            st.plotly_chart(
                line_chart(
                    trend,
                    x="period_month",
                    y="quantity",
                    color="product_name",
                    title=f"Monthly stock trend — {cat}",
                ),
                use_container_width=True,
            )

            # Latest month table
            latest = run_query(
                """
                SELECT period_month, p.product_name, p.category, f.quantity
                FROM core.fact_inventory f
                LEFT JOIN core.dim_products p ON p.product_key = f.product_key
                WHERE period_month = (SELECT MAX(period_month) FROM core.fact_inventory)
                ORDER BY quantity DESC
                """
            )
            st.subheader("Latest month stock")
            st.dataframe(latest, use_container_width=True, hide_index=True)

            st.info(
                "Coverage is 2025-01 … 2025-12 only — staging has no 2026 inventory columns yet (data_catlog.md §3.2). Extend the LATERAL (VALUES ...) list when 2026 data lands."
            )
        else:
            st.warning(
                "No inventory data yet — run the pipeline to populate fact_inventory."
            )

        # -------------------------------------------------------- distributions
        st.subheader("Stock shape — distribution and month-by-month heat")

        box_col, heat_col = st.columns(2)
        with box_col:
            spread = run_query(
                """
                SELECT p.category, f.quantity
                FROM core.fact_inventory f
                JOIN core.dim_products p
                    ON p.product_key = f.product_key
                WHERE f.quantity IS NOT NULL
                """
            )
            if not spread.empty:
                st.plotly_chart(
                    box_chart(
                        spread,
                        x="category",
                        y="quantity",
                        title="Monthly stock units by category",
                    ),
                    use_container_width=True,
                )

        with heat_col:
            if cat != "All":
                matrix = run_query(
                    """
                    SELECT
                        p.product_name
                        , TO_CHAR(f.period_month, 'YYYY-MM') AS month
                        , SUM(f.quantity) AS quantity
                    FROM core.fact_inventory f
                    JOIN core.dim_products p
                        ON p.product_key = f.product_key
                    WHERE p.category = :cat
                    GROUP BY p.product_name, TO_CHAR(f.period_month, 'YYYY-MM')
                    """,
                    params={"cat": cat},
                )
            else:
                matrix = run_query(
                    """
                    SELECT
                        p.product_name
                        , TO_CHAR(f.period_month, 'YYYY-MM') AS month
                        , SUM(f.quantity) AS quantity
                    FROM core.fact_inventory f
                    JOIN core.dim_products p
                        ON p.product_key = f.product_key
                    GROUP BY p.product_name, TO_CHAR(f.period_month, 'YYYY-MM')
                    """
                )
            if not matrix.empty:
                wide_matrix = wide(
                    matrix, index="product_name", columns="month", values="quantity"
                )
                totals = wide_matrix.sum(axis=1).sort_values(ascending=False)
                top20 = totals.head(20).index.tolist()
                st.plotly_chart(
                    heatmap_chart(
                        wide_matrix.loc[top20],
                        title=f"Stock units — top {len(top20)} products × month",
                        y_title="product",
                    ),
                    use_container_width=True,
                )

        # Unmatched products
        try:
            unmatched = run_query(
                "SELECT COUNT(*) AS n FROM core.fact_inventory WHERE product_key IS NULL"
            )
            if int(unmatched.iloc[0].n) > 0:
                st.warning(
                    f"Unmatched products: {int(unmatched.iloc[0].n)} (product_name not in dim_products)."
                )
        except Exception:
            pass

    except Exception as e:
        st.error(f"Query failed: {e}")
        st.exception(e)
        st.stop()

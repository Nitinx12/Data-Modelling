import streamlit as st
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
                WHERE p.category = %(cat)s
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
            # Line chart with product as color
            import plotly.express as px

            fig = px.line(
                trend,
                x="period_month",
                y="quantity",
                color="product_name",
                markers=True,
                title=f"Monthly stock trend — {cat}",
            )
            fig.update_layout(margin=dict(t=30, b=10), font={"color": "#0F172A"})
            st.plotly_chart(fig, use_container_width=True)

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

            # Coverage note from catalog
            st.info(
                "Coverage is 2025-01 … 2025-12 only — staging has no 2026 inventory columns yet (data_catlog.md §3.2). Extend the LATERAL (VALUES ...) list when 2026 data lands."
            )
        else:
            st.warning(
                "No inventory data yet — run the pipeline to populate fact_inventory."
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
        st.stop()

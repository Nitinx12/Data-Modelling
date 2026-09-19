import streamlit as st
from lib.db import last_refresh, run_query

st.set_page_config(page_title="Warehouse Analytics", page_icon="📦", layout="wide")
st.title("📦 Warehouse Analytics")
st.caption(
    "Live view over the `core` dimensional warehouse — SCD2 `dim_customers` + SCD1 dims, fact constellation."
)

# Last refresh + repo link footer
refresh = last_refresh()
if refresh:
    st.caption(
        f"Last warehouse update: {refresh}  •  [GitHub →](https://github.com/) • Core schema: dim_customer (SCD2), dim_products, fact_orders, fact_order_process, etc."
    )

with st.spinner("Loading KPIs…"):
    try:
        kpis = run_query(
            """
            SELECT
                (SELECT COUNT(*) FROM core.fact_orders) AS total_order_lines,
                (SELECT COUNT(DISTINCT order_id) FROM core.fact_order_process) AS total_orders,
                (SELECT COUNT(*) FROM core.fact_order_process WHERE pay_date IS NOT NULL) AS paid_orders,
                (SELECT COALESCE(SUM(spend), 0) FROM core.fact_campaign_spend) AS total_spend,
                (SELECT COALESCE(SUM(quantity), 0) FROM core.fact_inventory) AS total_inventory_units,
                (SELECT COUNT(*) FROM core.dim_customers WHERE is_current) AS current_customers,
                (SELECT COUNT(*) FROM core.dim_customers) AS customer_versions
            """
        ).iloc[0]

        col1, col2, col3, col4 = st.columns(4)
        col1.metric("Order Lines", f"{int(kpis.total_order_lines):,}")
        col2.metric("Total Orders", f"{int(kpis.total_orders):,}")
        conv = (kpis.paid_orders / kpis.total_orders * 100) if kpis.total_orders else 0
        col3.metric("Order → Paid Rate", f"{conv:.1f}%")
        col4.metric("Total Campaign Spend", f"${float(kpis.total_spend):,.0f}")

        col5, col6, col7, col8 = st.columns(4)
        col5.metric(
            "Inventory Units (all months)", f"{int(kpis.total_inventory_units):,}"
        )
        col6.metric("Customers (current)", f"{int(kpis.current_customers):,}")
        col7.metric("Customer Versions (SCD2)", f"{int(kpis.customer_versions):,}")
        col8.metric(
            "Avg Lines / Order",
            f"{(kpis.total_order_lines / kpis.total_orders):.1f}"
            if kpis.total_orders
            else "—",
        )

        st.divider()
        # Revenue vs spend sanity
        extra = run_query(
            """
            SELECT
                COALESCE(SUM(line_total),0) AS revenue,
                COALESCE(AVG(line_total),0) AS avg_line
            FROM core.fact_orders
            """
        ).iloc[0]
        a, b = st.columns(2)
        a.metric("Fact Orders Revenue (Σ line_total)", f"${float(extra.revenue):,.0f}")
        b.metric("Avg Line Total", f"${float(extra.avg_line):,.2f}")

    except Exception as e:
        st.error(f"Data temporarily unavailable — check DB connection / secrets: {e}")
        st.info(
            "Set dashboard/.streamlit/secrets.toml [postgres] or POSTGRES_HOST env. See dashboard/.streamlit/secrets.toml.example."
        )
        st.stop()

st.info(
    "Use the sidebar to explore **Order Fulfillment** (accumulating snapshot), **Sales** (fact_orders + role-playing dim_geo), **Marketing** (spend + factless), **Inventory** (periodic snapshot), and **Pipeline Health**."
)

st.divider()
st.markdown(
    """
**Grain & pattern quick ref**
- `fact_orders` — one row per order line (transaction fact), as-of join to SCD2 `dim_customers`
- `fact_order_process` — one row per order, accumulating snapshot (order → ship → deliver → invoice → pay, COALESCE-guarded)
- `fact_campaign_spend` — one row per campaign per day (transaction fact)
- `fact_less_fact` — factless fact, one row per campaign–promoted-SKU pair (no measures)
- `fact_inventory` — one row per product per month (periodic snapshot, unpivoted from 2025 columns)
- `dim_geo` — role-playing dimension (ship_to / bill_to in `fact_orders`)
"""
)

# Small table: top customers by order count (SCD2-aware — show current name)
try:
    top = run_query(
        """
        SELECT c.customer_name, COUNT(*) AS orders
        FROM core.fact_order_process p
        LEFT JOIN core.dim_customers c ON c.customer_key = p.customer_key
        WHERE c.is_current
        GROUP BY c.customer_name
        ORDER BY orders DESC
        LIMIT 5
        """
    )
    if not top.empty:
        st.subheader("Top customers (by orders)")
        st.dataframe(top, use_container_width=True, hide_index=True)
except Exception:
    pass

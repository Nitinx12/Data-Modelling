import sys
from pathlib import Path

import streamlit as st

# `dashboard/` has to be importable no matter how the app is launched (local
# CLI, Streamlit Community Cloud, AppTest): this repo tracks no `__init__.py`,
# so `lib` is a namespace package that only resolves from this directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))

st.set_page_config(page_title="Warehouse Analytics", page_icon="📦", layout="wide")

# Surface import failures explicitly — Streamlit Cloud redacts the traceback
# otherwise, which makes a missing dependency indistinguishable from a bug.
try:
    from lib.charts import (
        bar_chart,
        box_chart,
        funnel_chart,
        heatmap_chart,
        line_chart,
        treemap_chart,
        wide,
    )
    from lib.db import db_source, last_refresh, run_query
except Exception as exc:
    st.error(
        "Dashboard could not import `lib/` — check `dashboard/requirements.txt` "
        f"({type(exc).__name__}: {exc})"
    )
    st.exception(exc)
    st.stop()

st.title("📦 Warehouse Analytics")
st.caption(
    "Live view over the `core` dimensional warehouse — SCD2 `dim_customers` + SCD1 dims, fact constellation."
)
src_col, refresh_col = st.columns([4, 1])
with src_col:
    st.caption(f"Source: `{db_source()}`  •  schema: `core`  •  read-only queries")
with refresh_col:
    if st.button("↻ Refresh", use_container_width=True):
        st.cache_data.clear()
        st.rerun()

# Last refresh footer
refresh = last_refresh()
if refresh:
    st.caption(f"Last warehouse update: {refresh}")

st.divider()

# ---------------------------------------------------------------- KPI cards
with st.spinner("Loading KPIs…"):
    try:
        kpis = run_query(
            """
            SELECT
                (SELECT COUNT(*) FROM core.fact_orders) AS total_order_lines,
                (SELECT COUNT(DISTINCT order_id) FROM core.fact_order_process) AS total_orders,
                (SELECT COUNT(*) FROM core.fact_order_process WHERE pay_date IS NOT NULL) AS paid_orders,
                (SELECT COALESCE(SUM(spend), 0) FROM core.fact_campaign_spend) AS total_spend,
                (SELECT COALESCE(SUM(quantity), 0) FROM core.fact_inventory
                 WHERE period_month = (SELECT MAX(period_month) FROM core.fact_inventory)
                ) AS on_hand_units,
                (SELECT TO_CHAR(MAX(period_month), 'YYYY-MM') FROM core.fact_inventory) AS on_hand_month,
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
            f"Inventory Units ({kpis.on_hand_month or 'n/a'} on-hand)",
            f"{int(kpis.on_hand_units):,}",
        )
        col6.metric("Customers (current)", f"{int(kpis.current_customers):,}")
        col7.metric("Customer Versions (SCD2)", f"{int(kpis.customer_versions):,}")
        col8.metric(
            "Avg Lines / Order",
            f"{(kpis.total_order_lines / kpis.total_orders):.1f}"
            if kpis.total_orders
            else "—",
        )

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
        st.exception(e)
        st.stop()

st.divider()

# ---------------------------------------------------------------- charts
st.subheader("Performance overview")

trend = run_query(
    """
    SELECT order_date, SUM(line_total) AS revenue, COUNT(*) AS lines
    FROM core.fact_orders
    WHERE order_date IS NOT NULL
    GROUP BY order_date
    ORDER BY order_date
    """
)
funnel_row = run_query(
    """
    SELECT
        COUNT(*) FILTER (WHERE order_date IS NOT NULL) AS ordered,
        COUNT(*) FILTER (WHERE ship_date IS NOT NULL) AS shipped,
        COUNT(*) FILTER (WHERE delivery_date IS NOT NULL) AS delivered,
        COUNT(*) FILTER (WHERE invoice_date IS NOT NULL) AS invoiced,
        COUNT(*) FILTER (WHERE pay_date IS NOT NULL) AS paid
    FROM core.fact_order_process
    """
).iloc[0]

left, right = st.columns(2)
with left:
    if not trend.empty:
        st.plotly_chart(
            line_chart(
                trend,
                x="order_date",
                y="revenue",
                title="Daily revenue (Σ line_total)",
                range_slider=True,
            ),
            use_container_width=True,
        )
with right:
    st.plotly_chart(
        funnel_chart(
            {
                "Ordered": int(funnel_row.ordered),
                "Shipped": int(funnel_row.shipped),
                "Delivered": int(funnel_row.delivered),
                "Invoiced": int(funnel_row.invoiced),
                "Paid": int(funnel_row.paid),
            },
            title="Order → Paid funnel",
        ),
        use_container_width=True,
    )

mix_col, dist_col = st.columns(2)
with mix_col:
    revenue_mix = run_query(
        """
        SELECT
            p.category
            , COALESCE(p.subcategory_name, 'Uncategorised') AS subcategory_name
            , SUM(f.line_total) AS revenue
        FROM core.fact_orders f
        JOIN core.dim_products p
            ON p.product_key = f.product_key
        GROUP BY p.category, p.subcategory_name
        HAVING SUM(f.line_total) > 0
        ORDER BY revenue DESC
        """
    )
    if not revenue_mix.empty:
        st.plotly_chart(
            treemap_chart(
                revenue_mix,
                path=["category", "subcategory_name"],
                values="revenue",
                title="Revenue share — category ▸ subcategory",
            ),
            use_container_width=True,
        )

with dist_col:
    spread = run_query(
        """
        SELECT p.category, f.line_total
        FROM core.fact_orders f
        JOIN core.dim_products p
            ON p.product_key = f.product_key
        WHERE f.line_total IS NOT NULL
        """
    )
    if not spread.empty:
        st.plotly_chart(
            box_chart(
                spread,
                x="category",
                y="line_total",
                title="Order-line value distribution by category",
            ),
            use_container_width=True,
        )

spend_col, heat_col = st.columns(2)
with spend_col:
    spend = run_query(
        """
        SELECT campaign_name, SUM(spend) AS spend
        FROM core.fact_campaign_spend
        GROUP BY campaign_name
        ORDER BY spend DESC
        """
    )
    if not spend.empty:
        st.plotly_chart(
            bar_chart(
                spend,
                x="campaign_name",
                y="spend",
                title="Campaign spend ($)",
                horizontal=True,
            ),
            use_container_width=True,
        )

with heat_col:
    channel_matrix = run_query(
        """
        SELECT
            TO_CHAR(f.order_date, 'YYYY-MM') AS month
            , COALESCE(d.channel_name, d.channel_code::TEXT) AS channel
            , SUM(f.line_total) AS revenue
        FROM core.fact_orders f
        LEFT JOIN core.dim_orders_flag d
            ON d.flag_key = f.flag_key
        WHERE f.order_date IS NOT NULL
        GROUP BY TO_CHAR(f.order_date, 'YYYY-MM')
                , COALESCE(d.channel_name, d.channel_code::TEXT)
        """
    )
    if not channel_matrix.empty:
        st.plotly_chart(
            heatmap_chart(
                wide(
                    channel_matrix, index="channel", columns="month", values="revenue"
                ),
                title="Revenue — channel × month ($)",
            ),
            use_container_width=True,
        )

st.divider()

# ---------------------------------------------------------------- tables
try:
    top = run_query(
        """
        SELECT c.customer_name, COUNT(*) AS orders
        FROM core.fact_order_process p
        JOIN core.dim_customers c
            ON c.customer_key = p.customer_key
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

st.caption(
    """
**Grain & pattern quick ref**
- `fact_orders` — one row per order line (transaction fact), as-of join to SCD2 `dim_customers`
- `fact_order_process` — one row per order, accumulating snapshot (order → ship → deliver → invoice → pay)
- `fact_campaign_spend` — one row per campaign per day (transaction fact)
- `fact_less_fact` — factless fact, one row per campaign–promoted-SKU pair (no measures)
- `fact_inventory` — one row per product per month (periodic snapshot)
- `dim_geo` — role-playing dimension (ship_to / bill_to in `fact_orders`)
"""
)

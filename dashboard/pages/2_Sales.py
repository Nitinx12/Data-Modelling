import sys
from pathlib import Path

import streamlit as st

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.charts import (
    bar_chart,
    box_chart,
    heatmap_chart,
    line_chart,
    scatter_chart,
    treemap_chart,
    wide,
)
from lib.db import run_query

st.set_page_config(page_title="Sales", page_icon="💰", layout="wide")
st.title("💰 Sales — fact_orders (one row per order line)")
st.caption(
    "Transaction fact at order-line grain. Dims resolved at load time: SCD2 `dim_customers` (as-of order_date), `dim_products` (MIN per name for Kitchen M006 collisions), `dim_orders_flag` (junk), `dim_geo` ×2 (role-playing ship_to / bill_to)."
)

with st.spinner("Loading sales…"):
    try:
        # Revenue trend
        trend = run_query(
            """
            SELECT order_date, SUM(line_total) AS revenue, COUNT(*) AS lines
            FROM core.fact_orders
            WHERE order_date IS NOT NULL
            GROUP BY order_date
            ORDER BY order_date
            """
        )
        if not trend.empty:
            st.subheader("Revenue trend")
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
        else:
            st.warning(
                "No order_date data yet — run the pipeline to populate fact_orders."
            )

        col1, col2 = st.columns(2)
        with col1:
            st.subheader("Top products by revenue")
            top_products = run_query(
                """
                SELECT p.product_name, SUM(f.line_total) AS revenue, SUM(f.quantity) AS units
                FROM core.fact_orders f
                LEFT JOIN core.dim_products p ON p.product_key = f.product_key
                GROUP BY p.product_name
                ORDER BY revenue DESC
                LIMIT 10
                """
            )
            if not top_products.empty:
                st.plotly_chart(
                    bar_chart(
                        top_products,
                        x="product_name",
                        y="revenue",
                        title="Revenue by product",
                        horizontal=True,
                    ),
                    use_container_width=True,
                )
                st.dataframe(top_products, use_container_width=True, hide_index=True)
        with col2:
            st.subheader("Top ship-to cities (role-playing dim_geo)")
            top_geo = run_query(
                """
                SELECT g.city_name, SUM(f.line_total) AS revenue, COUNT(*) AS lines
                FROM core.fact_orders f
                LEFT JOIN core.dim_geo g ON g.geo_key = f.ship_geo_key
                GROUP BY g.city_name
                ORDER BY revenue DESC
                LIMIT 10
                """
            )
            if not top_geo.empty:
                st.plotly_chart(
                    bar_chart(
                        top_geo,
                        x="city_name",
                        y="revenue",
                        title="Revenue by ship-to city",
                        horizontal=True,
                    ),
                    use_container_width=True,
                )
                st.dataframe(top_geo, use_container_width=True, hide_index=True)

        # ---------------------------------------------------------------- mix
        st.subheader("Revenue mix — hierarchy, spread and price/quantity relation")
        mix_col, box_col = st.columns(2)

        with mix_col:
            treemap = run_query(
                """
                SELECT
                    p.category
                    , COALESCE(p.subcategory_name, 'Uncategorised') AS subcategory_name
                    , p.product_name
                    , SUM(f.line_total) AS revenue
                FROM core.fact_orders f
                JOIN core.dim_products p
                    ON p.product_key = f.product_key
                GROUP BY p.category, p.subcategory_name, p.product_name
                HAVING SUM(f.line_total) > 0
                ORDER BY revenue DESC
                """
            )
            if not treemap.empty:
                st.plotly_chart(
                    treemap_chart(
                        treemap,
                        path=["category", "subcategory_name", "product_name"],
                        values="revenue",
                        title="Revenue — category ▸ subcategory ▸ product",
                    ),
                    use_container_width=True,
                )

        with box_col:
            spread = run_query(
                """
                SELECT
                    COALESCE(d.channel_name, d.channel_code::TEXT) AS channel
                    , f.line_total
                FROM core.fact_orders f
                LEFT JOIN core.dim_orders_flag d
                    ON d.flag_key = f.flag_key
                WHERE f.line_total IS NOT NULL
                """
            )
            if not spread.empty:
                st.plotly_chart(
                    box_chart(
                        spread,
                        x="channel",
                        y="line_total",
                        title="Line value distribution by channel",
                    ),
                    use_container_width=True,
                )

        price_col, heat_col = st.columns(2)
        with price_col:
            pricing = run_query(
                """
                SELECT
                    f.unit_price
                    , f.line_total
                    , f.quantity
                    , p.product_name
                    , p.category
                FROM core.fact_orders f
                JOIN core.dim_products p
                    ON p.product_key = f.product_key
                WHERE f.unit_price IS NOT NULL
                """
            )
            if not pricing.empty:
                st.plotly_chart(
                    scatter_chart(
                        pricing,
                        x="unit_price",
                        y="line_total",
                        size="quantity",
                        color="category",
                        title="Unit price vs line value (bubble = units)",
                        hover_data=["product_name"],
                    ),
                    use_container_width=True,
                )

        with heat_col:
            weekday = run_query(
                """
                SELECT
                    TO_CHAR(order_date, 'YYYY-MM') AS month
                    , TO_CHAR(order_date, 'Dy') AS weekday
                    , SUM(line_total) AS revenue
                FROM core.fact_orders
                WHERE order_date IS NOT NULL
                GROUP BY TO_CHAR(order_date, 'YYYY-MM'), TO_CHAR(order_date, 'Dy')
                """
            )
            if not weekday.empty:
                mat = wide(weekday, index="weekday", columns="month", values="revenue")
                order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                mat = mat.reindex([d for d in order if d in mat.index])
                st.plotly_chart(
                    heatmap_chart(
                        mat, title="Revenue — weekday × month ($)", y_title="weekday"
                    ),
                    use_container_width=True,
                )

        # Bill-to vs ship-to divergence — where dim_geo earns its keep
        st.subheader("Ship-to vs Bill-to divergence")
        divergence = run_query(
            """
            SELECT
                SUM(CASE WHEN f.ship_geo_key = f.bill_geo_key THEN 1 ELSE 0 END) AS same_city,
                SUM(CASE WHEN f.ship_geo_key IS DISTINCT FROM f.bill_geo_key THEN 1 ELSE 0 END) AS diff_city,
                COUNT(*) AS total
            FROM core.fact_orders f
            """
        ).iloc[0]
        c1, c2, c3 = st.columns(3)
        c1.metric("Same ship/bill city", f"{int(divergence.same_city):,}")
        c2.metric("Different city", f"{int(divergence.diff_city):,}")
        c3.metric(
            "Different %",
            f"{divergence.diff_city / divergence.total * 100:.1f}%"
            if divergence.total
            else "—",
        )

        # Junk dimension breakdown
        st.subheader("Orders by channel / status / priority (junk dim)")
        flag = run_query(
            """
            SELECT COALESCE(channel_name, channel_code::TEXT) AS channel, status, priority, COUNT(*) AS lines
            FROM core.fact_orders f
            LEFT JOIN core.dim_orders_flag d ON d.flag_key = f.flag_key
            GROUP BY channel, status, priority
            ORDER BY lines DESC
            LIMIT 20
            """
        )
        if not flag.empty:
            st.dataframe(flag, use_container_width=True, hide_index=True)

    except Exception as e:
        st.error(f"Query failed: {e}")
        st.exception(e)
        st.stop()

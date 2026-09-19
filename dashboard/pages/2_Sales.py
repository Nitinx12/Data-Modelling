import streamlit as st
from lib.charts import bar_chart, line_chart
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
                    ),
                    use_container_width=True,
                )
                st.dataframe(top_geo, use_container_width=True, hide_index=True)

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
        st.stop()

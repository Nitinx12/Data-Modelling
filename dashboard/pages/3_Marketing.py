import streamlit as st
from lib.charts import bar_chart, line_chart
from lib.db import run_query

st.set_page_config(page_title="Marketing", page_icon="📣", layout="wide")
st.title("📣 Marketing — spend + promoted SKUs")
st.caption(
    "`fact_campaign_spend` (one row per campaign per day) and `fact_less_fact` (factless fact: one row per campaign–promoted-SKU pair) share conformed dims `dim_campaign`/`dim_products` but are never joined directly — analysis goes through the shared dims."
)

with st.spinner("Loading marketing…"):
    try:
        # Spend over time
        spend_trend = run_query(
            """
            SELECT spend_date, SUM(spend) AS spend, SUM(impressions) AS impressions, SUM(clicks) AS clicks
            FROM core.fact_campaign_spend
            GROUP BY spend_date
            ORDER BY spend_date
            """
        )
        if not spend_trend.empty:
            st.subheader("Spend over time")
            st.plotly_chart(
                line_chart(spend_trend, x="spend_date", y="spend", title="Daily spend"),
                use_container_width=True,
            )
            c1, c2 = st.columns(2)
            c1.plotly_chart(
                line_chart(
                    spend_trend, x="spend_date", y="impressions", title="Impressions"
                ),
                use_container_width=True,
            )
            c2.plotly_chart(
                line_chart(spend_trend, x="spend_date", y="clicks", title="Clicks"),
                use_container_width=True,
            )

        col1, col2 = st.columns(2)
        with col1:
            st.subheader("Spend by campaign")
            by_campaign = run_query(
                """
                SELECT campaign_name, SUM(spend) AS spend, SUM(impressions) AS impressions
                FROM core.fact_campaign_spend
                GROUP BY campaign_name
                ORDER BY spend DESC
                """
            )
            if not by_campaign.empty:
                st.plotly_chart(
                    bar_chart(
                        by_campaign,
                        x="campaign_name",
                        y="spend",
                        title="Total spend by campaign",
                    ),
                    use_container_width=True,
                )
                st.dataframe(by_campaign, use_container_width=True, hide_index=True)
        with col2:
            st.subheader("Promoted SKU coverage (factless fact)")
            coverage = run_query(
                """
                SELECT campaign_name, COUNT(*) AS promoted_skus
                FROM core.fact_less_fact
                GROUP BY campaign_name
                ORDER BY promoted_skus DESC
                """
            )
            if not coverage.empty:
                st.plotly_chart(
                    bar_chart(
                        coverage,
                        x="campaign_name",
                        y="promoted_skus",
                        title="Promoted SKUs per campaign",
                    ),
                    use_container_width=True,
                )
                st.dataframe(coverage, use_container_width=True, hide_index=True)

        # Spend per promoted SKU — one CTE per fact so the join cannot fan out
        st.subheader("Spend per promoted SKU (via shared dims)")
        spend_per_sku = run_query(
            """
            WITH spend_by_campaign AS (
                SELECT
                    campaign_name
                    , SUM(spend) AS total_spend
                FROM core.fact_campaign_spend
                GROUP BY campaign_name
            )
            , promoted_by_campaign AS (
                SELECT
                    dc.campaign_name
                    , COUNT(DISTINCT l.product_key) AS promoted_skus
                FROM core.dim_campaign dc
                LEFT JOIN core.fact_less_fact l
                    ON l.campaign_key = dc.campaign_key
                GROUP BY dc.campaign_name
            )
            SELECT
                s.campaign_name
                , COALESCE(p.promoted_skus, 0) AS promoted_skus
                , s.total_spend
                , CASE
                    WHEN COALESCE(p.promoted_skus, 0) > 0
                    THEN s.total_spend / p.promoted_skus
                END AS spend_per_sku
            FROM spend_by_campaign s
            LEFT JOIN promoted_by_campaign p
                ON p.campaign_name = s.campaign_name
            ORDER BY s.total_spend DESC
            """
        )
        if not spend_per_sku.empty:
            st.dataframe(spend_per_sku, use_container_width=True, hide_index=True)

    except Exception as e:
        st.error(f"Query failed: {e}")
        st.stop()

import streamlit as st
from lib.db import run_query

st.set_page_config(page_title="Pipeline Health", page_icon="💚", layout="wide")
st.title("💚 Pipeline Health — quality gates & warehouse freshness")
st.caption(
    "Live demo of the double-gated quality: catalog-driven SQL loops + Great Expectations (`gx/`), both with `--strict` (red fails the pipeline)."
)

with st.spinner("Loading health…"):
    # Pipeline run log — observability (core.pipeline_run_log) — roadmap Tier 3 item 8
    try:
        log_recent = run_query(
            """
            SELECT run_id, stage, model_name, status, duration_ms, row_count, started_at
            FROM core.pipeline_run_log
            ORDER BY started_at DESC
            LIMIT 20
            """
        )
        if not log_recent.empty:
            st.subheader("Pipeline run log — recent executions")
            # Show as table + simple duration chart
            st.dataframe(log_recent, use_container_width=True, hide_index=True)
            # Pass/fail streak: last 10 runs
            try:
                import plotly.express as px

                # Aggregate per run_id: any FAIL in run -> run FAIL
                runs = log_recent.copy()
                runs["started_at"] = __import__("pandas").to_datetime(
                    runs["started_at"]
                )
                fig = px.scatter(
                    runs,
                    x="started_at",
                    y="duration_ms",
                    color="status",
                    symbol="stage",
                    hover_data=["model_name", "row_count"],
                    title="Recent run durations (ms) — color by status",
                    color_discrete_map={
                        "PASS": "#10B981",
                        "FAIL": "#EF4444",
                        "SKIP": "#F59E0B",
                    },
                )
                st.plotly_chart(fig, use_container_width=True)
            except Exception:
                pass
        else:
            st.caption(
                "No pipeline_run_log entries yet — run `make pipeline` to populate observability."
            )
    except Exception:
        st.caption(
            "pipeline_run_log not yet created — run the pipeline once (sql/11_pipeline_run_log.sql creates it)."
        )

    # Table counts
    try:
        counts = run_query(
            """
            SELECT
                (SELECT COUNT(*) FROM core.dim_customers WHERE is_current) AS dim_customers_current,
                (SELECT COUNT(*) FROM core.dim_customers) AS dim_customers_versions,
                (SELECT COUNT(*) FROM core.dim_products) AS dim_products,
                (SELECT COUNT(*) FROM core.dim_geo) AS dim_geo,
                (SELECT COUNT(*) FROM core.fact_orders) AS fact_orders,
                (SELECT COUNT(*) FROM core.fact_order_process) AS fact_order_process,
                (SELECT COUNT(*) FROM core.fact_campaign_spend) AS fact_campaign_spend,
                (SELECT COUNT(*) FROM core.fact_inventory) AS fact_inventory,
                (SELECT COUNT(*) FROM core.fact_less_fact) AS fact_less_fact
            """
        ).iloc[0]
        c1, c2, c3, c4 = st.columns(4)
        c1.metric("dim_customers (current)", f"{int(counts.dim_customers_current):,}")
        c2.metric("dim_customers (versions)", f"{int(counts.dim_customers_versions):,}")
        c3.metric("fact_orders", f"{int(counts.fact_orders):,}")
        c4.metric("fact_order_process", f"{int(counts.fact_order_process):,}")

        c5, c6, c7 = st.columns(3)
        c5.metric("fact_campaign_spend", f"{int(counts.fact_campaign_spend):,}")
        c6.metric("fact_inventory", f"{int(counts.fact_inventory):,}")
        c7.metric("fact_less_fact", f"{int(counts.fact_less_fact):,}")

        # SCD2 history visibility
        scd2 = run_query(
            """
            SELECT customer_id, customer_name, COUNT(*) AS versions, MAX(is_current)::INT AS has_current
            FROM core.dim_customers
            GROUP BY customer_id, customer_name
            HAVING COUNT(*) > 1
            ORDER BY versions DESC
            LIMIT 10
            """
        )
        if not scd2.empty:
            st.subheader("SCD2 — customers with history")
            st.dataframe(scd2, use_container_width=True, hide_index=True)
        else:
            st.caption(
                "No SCD2 history yet — edit a customer's address in Mongo, re-run pipeline, and watch a new version appear here."
            )

        # Unmatched keys (orphan checks — mirrors GX orphan_fk suites)
        st.subheader("Orphan keys (should be 0)")
        orphans = run_query(
            """
            SELECT
                (SELECT COUNT(*) FROM core.fact_orders WHERE customer_key IS NULL) AS fact_orders_customer_null,
                (SELECT COUNT(*) FROM core.fact_orders WHERE product_key IS NULL) AS fact_orders_product_null,
                (SELECT COUNT(*) FROM core.fact_order_process WHERE customer_key IS NULL) AS fact_order_process_customer_null,
                (SELECT COUNT(*) FROM core.fact_campaign_spend WHERE campaign_key IS NULL) AS fact_campaign_spend_campaign_null
            """
        ).iloc[0]
        o1, o2, o3, o4 = st.columns(4)
        o1.metric(
            "fact_orders.customer_key NULL", int(orphans.fact_orders_customer_null)
        )
        o2.metric("fact_orders.product_key NULL", int(orphans.fact_orders_product_null))
        o3.metric(
            "fact_order_process.customer_key NULL",
            int(orphans.fact_order_process_customer_null),
        )
        o4.metric(
            "fact_campaign_spend.campaign_key NULL",
            int(orphans.fact_campaign_spend_campaign_null),
        )

        # Quarantine tables (future-dated data)
        st.subheader("Quarantine — future-dated data (self-healed)")
        q = run_query(
            """
            SELECT 'fact_orders_rejects' AS tbl, COUNT(*) AS n FROM core.fact_orders_rejects
            UNION ALL SELECT 'fact_order_process_rejects', COUNT(*) FROM core.fact_order_process_rejects
            UNION ALL SELECT 'fact_order_process_payment_rejects', COUNT(*) FROM core.fact_order_process_payment_rejects
            UNION ALL SELECT 'fact_order_process_milestone_rejects', COUNT(*) FROM core.fact_order_process_milestone_rejects
            ORDER BY tbl
            """
        )
        st.dataframe(q, use_container_width=True, hide_index=True)

    except Exception as e:
        st.error(f"Health query failed: {e}")
        st.stop()

st.divider()
st.markdown(
    """
**Refresh strategy** — for the deployed dashboard, host a read-only copy of `core` on Neon/Supabase (see dashboard/.streamlit/secrets.toml.example) and keep it fresh via:
- Manual `pg_dump -n core | psql $NEON_URL` after each pipeline run, or
- Scheduled GitHub Actions cron that runs the pipeline and pushes `core` nightly.

Public app uses `dashboard_reader` (GRANT SELECT only) — never write creds.
"""
)

import streamlit as st
from lib.charts import funnel_chart
from lib.db import run_query

st.set_page_config(page_title="Order Fulfillment", page_icon="🚚", layout="wide")
st.title("🚚 Order Fulfillment Funnel")
st.caption(
    "Accumulating snapshot `core.fact_order_process` — one row per order, mutated in place as milestones arrive (COALESCE-guarded, so NULL cannot erase a loaded milestone)."
)

with st.spinner("Loading funnel…"):
    try:
        funnel = run_query(
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
        counts = {
            "Ordered": int(funnel.ordered),
            "Shipped": int(funnel.shipped),
            "Delivered": int(funnel.delivered),
            "Invoiced": int(funnel.invoiced),
            "Paid": int(funnel.paid),
        }
        fig = funnel_chart(counts, title="Order → Paid funnel")
        st.plotly_chart(fig, use_container_width=True)

        # Drop-off table
        stages = list(counts.keys())
        vals = list(counts.values())
        drop = [None] + [
            f"{(vals[i - 1] - vals[i]) / vals[i - 1] * 100:.1f}%"
            if vals[i - 1]
            else "—"
            for i in range(1, len(vals))
        ]
        import pandas as pd

        st.dataframe(
            pd.DataFrame({"Stage": stages, "Count": vals, "Drop from prior": drop}),
            use_container_width=True,
            hide_index=True,
        )

        st.divider()
        # Avg days per stage + ship_mode breakdown
        lags = run_query(
            """
            SELECT
                ROUND(AVG(days_order_to_ship),1) AS avg_order_to_ship,
                ROUND(AVG(days_ship_to_delivery),1) AS avg_ship_to_delivery,
                ROUND(AVG(days_order_to_invoice),1) AS avg_order_to_invoice,
                ROUND(AVG(days_invoice_to_pay),1) AS avg_invoice_to_pay
            FROM core.fact_order_process
            """
        ).iloc[0]
        c1, c2, c3, c4 = st.columns(4)
        c1.metric("Avg Order → Ship (days)", f"{lags.avg_order_to_ship or 0:.1f}")
        c2.metric("Avg Ship → Delivery", f"{lags.avg_ship_to_delivery or 0:.1f}")
        c3.metric("Avg Order → Invoice", f"{lags.avg_order_to_invoice or 0:.1f}")
        c4.metric("Avg Invoice → Pay", f"{lags.avg_invoice_to_pay or 0:.1f}")

        # Quarantined orders (future-dated) — visibility into quality gate 3.5
        try:
            rejects = run_query(
                "SELECT COUNT(*) AS n FROM core.fact_order_process_rejects"
            )
            if int(rejects.iloc[0].n) > 0:
                st.warning(
                    f"Quarantined future-dated orders: {int(rejects.iloc[0].n)} (see core.fact_order_process_rejects)."
                )
        except Exception:
            pass

        st.caption(
            "Milestones beyond Ordered being NULL means the order hasn't reached that stage yet, not missing data."
        )
    except Exception as e:
        st.error(f"Query failed: {e}")
        st.stop()

with st.sidebar:
    st.header("Filters")
    st.caption("Applies to detail table below (funnel is unfiltered).")
    region_filter = st.selectbox(
        "Region (dim_customers)",
        ["All"]
        + run_query(
            "SELECT DISTINCT region_name FROM core.dim_customers WHERE is_current AND region_name IS NOT NULL ORDER BY 1"
        )["region_name"].tolist()
        if "region_name"
        else ["All"],
    )

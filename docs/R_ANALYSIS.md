# R Analysis Documentation

## Overview

This document describes the R-based analysis layer built on top of the existing PostgreSQL warehouse core schema. The analysis reads directly from the warehouse without modifying any pipeline tables.

## Folder Structure

```
notebooks/          Quarto notebooks (.qmd), one per analysis
r_analysis/
  scripts/          Headless R scripts, one per analysis plus shared helpers
  figures/          PNGs written by the scripts
  output/           CSV/RDS result tables written by the scripts
  report/           TeX report source and compiled PDF
docs/R_ANALYSIS.md  This document
```

## Notebooks

### 00 EDA Overview
Quarto notebook at `notebooks/00_eda_overview.qmd` plus a headless twin at
`r_analysis/scripts/00_eda_overview.R`. Both profile every dim and fact in
`core` and both stay read only. Coverage includes row counts and column
inventory, skim profiles over samples, key uniqueness per constraint, top
values for low cardinality text columns, SCD2 open against closed history
with version lifespan charts for `dim_customers`, grain checks per natural
key, NULL census with missing maps, measure summaries with interquartile
outlier flags, date spans with an inventory month continuity check,
pairwise measure correlations, and lightweight mirrors of the five quality
loops. A verdict block at the end reports the total failed rows. With zero
failures the warehouse is ready for notebooks 01 through 07.
Render on demand with `make eda`. Rendered HTML and EDA result files stay
out of git by design, so rerun after every grain, key, or load logic change.

### 01 Customer Tenure
Source: dim_customers (SCD2)
- Histogram of days between valid_from and valid_to
- Bar of version count per customer
- Finding: which customers churn attributes often, typical version lifespan
- Live finding (Sep 2026 run): all 61 customers sit on one version each and every version spans under a day, which matches a single bulk load with no attribute churn yet

### 02 Revenue Seasonality
Source: fact_orders
- Monthly revenue line with STL decomposition
- Trend/seasonal/residual panels
- Finding: seasonal pattern identification and product drivers
- Live finding (Sep 2026 run): 19 months of revenue from Feb 2025 to Sep 2026 with zero order lines in Aug 2025, so the split reports trend only until two full yearly cycles exist. Team M047 leads products near 27k revenue

### 03 Fulfillment Funnel
Source: fact_order_process
- Funnel Ordered to Paid, survival curve of time to pay
- Finding: where orders stall, normal delay versus outlier
- Live finding (Sep 2026 run): 75 ordered rows narrow to 51 paid for a 68 percent paid rate with the steepest drop between invoiced and paid. Median time to pay is 19 days with zero orders past the outlier boundary

### 04 Campaign Lift
Source: fact_campaign_spend + fact_less_fact joined to dim_campaign/dim_products
- Scatter of spend versus revenue lift with lm trend line
- Finding: spend correlation with lift, campaign outliers
- Live finding (Sep 2026 run): spend tracks window revenue at 0.504 correlation across 3 campaigns with revenue. Black Friday, New Year Clearance, and Summer Sale show no window revenue since their windows hold almost no order lines

### 05 Inventory Health
Source: fact_inventory
- Small multiples, one panel per category, stock across 2025 months
- Finding: categories trending toward stockout or overstock, rough ABC split
- Live finding (Sep 2026 run): all 6 categories read stable with 12 of 12 expected months present. ABC counts are 18 in A, 4 in B, and 2 in C

### 06 Pipeline Health
Source: core.pipeline_run_log
- Run duration trend with IQR-based outlier flags
- Stacked bar of stage durations
- Finding: pipeline slowing over time, growing cost stage
- Live finding (Sep 2026 run): 2 runs crossed the 22 second threshold on Sep 25. Quality loop rows carry no duration values and stay out of the stage split

### 07 Geo Split
Source: dim_geo (ship to versus bill to, role playing)
- Bar or map of order volume by state
- Finding: ship to and bill to geography divergence
- Live finding (Sep 2026 run): 77 percent of order lines ship and bill in different regions with Middle East receiving more than it bills and Europe billing more than it receives

## Headless Scripts

Each notebook has a corresponding headless script in `r_analysis/scripts/` for command-line execution or CI.
Shared helpers are `db_connect.R` (same `.env` as the Python pipeline), `plot_theme.R` (one ggplot2 look everywhere), and `logger.R`.
`run_r_script.R` is the single entry point: `Rscript r_analysis/run_r_script.R 00_eda_overview` profiles the warehouse, `Rscript r_analysis/run_r_script.R all` runs every numbered analysis in order against one shared connection.
Each script writes result tables to `r_analysis/output/` and chart PNGs to `r_analysis/figures/`, nothing else.
The TeX report follows Option A: `r_analysis/report/main.tex` includes the PNGs directly, so the PDF builds even without R running at compile time.
All of these outputs regenerate on demand and stay out of git.

## Build Targets

| Target | Description |
|--------|-------------|
| `make eda` | Renders notebooks/00_eda_overview.qmd via Quarto |
| `make notebooks` | Renders every notebook in notebooks/ via Quarto |
| `make r-analysis` | Runs every headless script via run_r_script.R (CSV + PNG) |
| `make r-report` | Compiles r_analysis/report/main.tex to PDF with tinytex |
| `make r-analysis-all` | Full R layer: eda + r-analysis + r-report in order |
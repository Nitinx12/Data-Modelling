#' Revenue seasonality analysis
#'
#' Monthly revenue from `core.fact_orders` with an STL split into trend,
#' seasonal, and residual parts, plus the top products behind the totals.
#' STL needs at least two full yearly cycles to settle, so short histories
#' get a trend only note. Read only.
#'
#' @param con Open DBI connection (optional, opened via `connect_db()` when NULL)
#' @param output_dir Directory for CSV result tables
#' @param figures_dir Directory for PNG charts
#' @return Invisible TRUE
#' @export
run_revenue_seasonality <- function(con = NULL, output_dir = "r_analysis/output",
                                    figures_dir = "r_analysis/figures") {
  if (!exists("log_info", mode = "function")) {
    source(file.path(find_project_root(), "r_analysis", "scripts", "logger.R"))
  }
  suppressPackageStartupMessages({
    library(ggplot2)
    library(tidyr)
  })

  owned_con <- is.null(con)
  if (owned_con) {
    con <- connect_db()
  }
  on.exit(if (owned_con) disconnect_db(con), add = TRUE)

  for (dir in c(output_dir, figures_dir)) {
    if (!dir.exists(dir)) {
      dir.create(dir, recursive = TRUE)
    }
  }

  log_info("Aggregating monthly revenue...")
  monthly <- qdf(con, paste0(
    "SELECT "
    , " DATE_TRUNC('month', f.order_date)::DATE AS month"
    , " , SUM(f.line_total) AS revenue"
    , " , COUNT(*) AS order_lines"
    , " FROM core.fact_orders AS f"
    , " WHERE f.order_date IS NOT NULL"
    , " GROUP BY DATE_TRUNC('month', f.order_date)::DATE"
    , " ORDER BY DATE_TRUNC('month', f.order_date)::DATE"
  ))
  if (nrow(monthly) == 0L) {
    log_warn("No dated order lines found, skipping seasonality.")
    return(invisible(TRUE))
  }
  monthly$month <- as.Date(monthly$month)
  utils::write.csv(monthly,
    file.path(output_dir, "revenue_seasonality_monthly.csv"),
    row.names = FALSE
  )

  log_info("Splitting trend from seasonality...")
  first_year <- as.integer(format(min(monthly$month), "%Y"))
  first_month <- as.integer(format(min(monthly$month), "%m"))
  ts_data <- stats::ts(
    monthly$revenue,
    frequency = 12L, start = c(first_year, first_month)
  )
  if (length(ts_data) >= 24L) {
    decomp <- stats::stl(ts_data, s.window = "periodic")
    decomp_df <- data.frame(
      month = monthly$month,
      observed = as.numeric(ts_data),
      trend = as.numeric(decomp$time.series[, "trend"]),
      seasonal = as.numeric(decomp$time.series[, "seasonal"]),
      residual = as.numeric(decomp$time.series[, "remainder"])
    )
  } else {
    log_warn("Fewer than 24 months, reporting trend without seasonal split.")
    decomp_df <- data.frame(
      month = monthly$month,
      observed = as.numeric(ts_data),
      trend = as.numeric(stats::filter(ts_data, rep(1L / 3L, 3L), sides = 2L)),
      seasonal = NA_real_,
      residual = NA_real_
    )
  }
  plot_data <- tidyr::pivot_longer(
    decomp_df,
    cols = c(observed, trend, seasonal, residual),
    names_to = "component", values_to = "value"
  )
  p <- ggplot2::ggplot(
    plot_data, ggplot2::aes(x = month, y = value)
  ) +
    ggplot2::geom_line(color = "#2980B9") +
    ggplot2::facet_wrap(~component, scales = "free_y", ncol = 1L) +
    ggplot2::labs(
      title = "Monthly revenue with trend and seasonal split",
      x = "Month", y = "Revenue"
    ) +
    ggplot2::theme_minimal()
  ggplot2::ggsave(
    file.path(figures_dir, "revenue_seasonality_stl.png"),
    plot = p, width = 9L, height = 8L, dpi = 150L
  )

  log_info("Ranking products behind the totals...")
  top_products <- qdf(con, paste0(
    "SELECT "
    , " COALESCE(d.product_name, f.product_key::VARCHAR) AS product_name"
    , " , COALESCE(d.category, 'UNKNOWN') AS category"
    , " , SUM(f.line_total) AS revenue"
    , " , SUM(f.quantity) AS units"
    , " FROM core.fact_orders AS f"
    , " LEFT JOIN core.dim_products AS d"
    , " ON d.product_key = f.product_key"
    , " GROUP BY COALESCE(d.product_name, f.product_key::VARCHAR)"
    , " , COALESCE(d.category, 'UNKNOWN')"
    , " ORDER BY SUM(f.line_total) DESC NULLS LAST"
    , " LIMIT 10"
  ))
  print(top_products)
  utils::write.csv(top_products,
    file.path(output_dir, "revenue_top_products.csv"),
    row.names = FALSE
  )

  log_info("Revenue seasonality analysis completed.")
  invisible(TRUE)
}

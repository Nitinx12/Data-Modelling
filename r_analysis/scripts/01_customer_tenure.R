#' Customer tenure analysis
#'
#' Version counts per customer and version lifespan distribution from the
#' SCD2 `core.dim_customers`. Shows which customers churn attributes often
#' and what a typical version lifespan looks like. Read only.
#'
#' @param con Open DBI connection (optional, opened via `connect_db()` when NULL)
#' @param output_dir Directory for CSV result tables
#' @param figures_dir Directory for PNG charts
#' @return Invisible TRUE
#' @export
run_customer_tenure <- function(con = NULL, output_dir = "r_analysis/output",
                                figures_dir = "r_analysis/figures") {
  if (!exists("log_info", mode = "function")) {
    source(file.path(find_project_root(), "r_analysis", "scripts", "logger.R"))
  }
  suppressPackageStartupMessages({
    library(ggplot2)
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

  log_info("Counting versions per customer...")
  version_counts <- qdf(con, paste0(
    "SELECT "
    , " d.customer_id"
    , " , COUNT(*) AS version_count"
    , " , MIN(d.valid_from) AS first_valid_from"
    , " , MAX(COALESCE(d.valid_to, now())) AS last_valid_end"
    , " FROM core.dim_customers AS d"
    , " GROUP BY d.customer_id"
    , " ORDER BY COUNT(*) DESC"
  ))
  log_info(paste("Customers profiled:", nrow(version_counts)))
  log_info(paste(
    "Single version share:",
    round(mean(version_counts$version_count == 1L), 3L)
  ))
  utils::write.csv(version_counts,
    file.path(output_dir, "customer_tenure_summary.csv"),
    row.names = FALSE
  )

  p_versions <- ggplot2::ggplot(
    version_counts, ggplot2::aes(x = version_count)
  ) +
    ggplot2::geom_histogram(
      binwidth = 1L, fill = "#3498DB", color = "#2C3E50"
    ) +
    ggplot2::labs(
      title = "Customer version count distribution",
      x = "Versions per customer", y = "Customer count"
    ) +
    ggplot2::theme_minimal()
  ggplot2::ggsave(
    file.path(figures_dir, "customer_tenure_hist.png"),
    plot = p_versions, width = 8L, height = 5L, dpi = 150L
  )

  log_info("Measuring version lifespans...")
  lifespans <- qdf(con, paste0(
    "SELECT "
    , " EXTRACT(EPOCH FROM (COALESCE(d.valid_to, now()) - d.valid_from)) / 86400.0"
    , " AS lifespan_days"
    , " FROM core.dim_customers AS d"
  ))
  utils::write.csv(
    data.frame(
      min_days = min(lifespans$lifespan_days, na.rm = TRUE),
      median_days = stats::median(lifespans$lifespan_days, na.rm = TRUE),
      mean_days = mean(lifespans$lifespan_days, na.rm = TRUE),
      max_days = max(lifespans$lifespan_days, na.rm = TRUE)
    ),
    file.path(output_dir, "customer_lifespan_summary.csv"),
    row.names = FALSE
  )

  p_spans <- ggplot2::ggplot(
    lifespans, ggplot2::aes(x = lifespan_days)
  ) +
    ggplot2::geom_histogram(
      bins = 40L, fill = "#2ECC71", color = "#2C3E50"
    ) +
    ggplot2::labs(
      title = "Days between version start and version end",
      x = "Lifespan in days", y = "Version count"
    ) +
    ggplot2::theme_minimal()
  ggplot2::ggsave(
    file.path(figures_dir, "customer_lifespan_hist.png"),
    plot = p_spans, width = 8L, height = 5L, dpi = 150L
  )

  log_info("Customer tenure analysis completed.")
  invisible(TRUE)
}

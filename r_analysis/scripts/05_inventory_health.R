#' Inventory health and ABC analysis
#'
#' Monthly stock per category from `core.fact_inventory` joined to
#' `core.dim_products`, a rough ABC split of products by total quantity
#' share, and flags for categories trending toward stockout or overstock.
#' Covers the months of 2025 present in the warehouse. Read only.
#'
#' @param con Open DBI connection (optional, opened via `connect_db()` when NULL)
#' @param output_dir Directory for CSV result tables
#' @param figures_dir Directory for PNG charts
#' @return Invisible TRUE
#' @export
run_inventory_health <- function(con = NULL, output_dir = "r_analysis/output",
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

  log_info("Aggregating monthly stock per category...")
  monthly <- qdf(con, paste0(
    "SELECT "
    , " f.period_month"
    , " , COALESCE(d.category, 'UNKNOWN') AS category"
    , " , SUM(f.quantity) AS total_quantity"
    , " , COUNT(DISTINCT f.product_name) AS product_count"
    , " FROM core.fact_inventory AS f"
    , " LEFT JOIN core.dim_products AS d"
    , " ON d.product_key = f.product_key"
    , " GROUP BY f.period_month, COALESCE(d.category, 'UNKNOWN')"
    , " ORDER BY COALESCE(d.category, 'UNKNOWN'), f.period_month"
  ))
  monthly$period_month <- as.Date(monthly$period_month)
  print(utils::head(monthly, 12L))
  utils::write.csv(monthly,
    file.path(output_dir, "inventory_monthly_category.csv"),
    row.names = FALSE
  )

  p <- ggplot2::ggplot(
    monthly,
    ggplot2::aes(x = period_month, y = total_quantity)
  ) +
    ggplot2::geom_line(color = "#2980B9", linewidth = 0.8) +
    ggplot2::geom_point(color = "#2980B9", size = 1.5) +
    ggplot2::facet_wrap(~category, scales = "free_y") +
    ggplot2::scale_x_date(date_labels = "%Y-%m") +
    ggplot2::labs(
      title = "Stock per category across months of 2025",
      x = "Month", y = "Total quantity"
    ) +
    ggplot2::theme_minimal() +
    ggplot2::theme(axis.text.x = ggplot2::element_text(angle = 45L, hjust = 1L))
  ggplot2::ggsave(file.path(figures_dir, "inventory_health.png"),
    plot = p, width = 11L, height = 7L, dpi = 150L
  )

  log_info("Computing rough ABC split...")
  abc <- qdf(con, paste0(
    "WITH product_totals AS ("
    , " SELECT "
    , " f.product_name"
    , " , SUM(f.quantity) AS total_quantity"
    , " FROM core.fact_inventory AS f"
    , " GROUP BY f.product_name"
    , ")"
    , " SELECT "
    , " t.product_name"
    , " , t.total_quantity"
    , " , SUM(t.total_quantity) OVER () AS grand_total"
    , " , SUM(t.total_quantity) OVER ("
    , " ORDER BY t.total_quantity DESC"
    , " ROWS UNBOUNDED PRECEDING"
    , " ) / SUM(t.total_quantity) OVER () AS running_share"
    , " FROM product_totals AS t"
    , " ORDER BY t.total_quantity DESC"
  ))
  abc$abc_class <- ifelse(
    abc$running_share <= 0.8, "A",
    ifelse(abc$running_share <= 0.95, "B", "C")
  )
  utils::write.csv(abc, file.path(output_dir, "inventory_abc.csv"),
    row.names = FALSE
  )
  log_info(paste(
    "ABC counts:",
    paste(
      vapply(
        c("A", "B", "C"),
        function(cl) paste0(cl, "=", sum(abc$abc_class == cl)),
        character(1L)
      ),
      collapse = " "
    )
  ))

  log_info("Flagging categories trending toward stockout or overstock...")
  flags <- do.call(rbind, lapply(split(monthly, monthly$category), function(df) {
    df <- df[order(df$period_month), , drop = FALSE]
    n <- nrow(df)
    first_half <- mean(df$total_quantity[seq_len(max(1L, n %/% 2L))])
    second_half <- mean(df$total_quantity[(max(1L, n %/% 2L) + 1L):n])
    change <- if (first_half > 0L) (second_half - first_half) / first_half else NA_real_
    data.frame(
      category = df$category[[1L]],
      min_monthly_quantity = min(df$total_quantity),
      first_half_avg = first_half,
      second_half_avg = second_half,
      relative_change = change,
      flag = if (!is.na(change) && change <= -0.3) {
        "toward stockout"
      } else if (!is.na(change) && change >= 0.5) {
        "toward overstock"
      } else {
        "stable"
      },
      stringsAsFactors = FALSE
    )
  }))
  rownames(flags) <- NULL
  print(flags)
  utils::write.csv(flags, file.path(output_dir, "inventory_flags.csv"),
    row.names = FALSE
  )

  log_info("Inventory health analysis completed.")
  invisible(TRUE)
}

#' Ship to against bill to geography analysis
#'
#' Order volume by region from `core.fact_orders` joined twice to the role
#' playing `core.dim_geo`, once per business role, plus the share of orders
#' where ship to and bill to regions diverge. Read only.
#'
#' @param con Open DBI connection (optional, opened via `connect_db()` when NULL)
#' @param output_dir Directory for CSV result tables
#' @param figures_dir Directory for PNG charts
#' @return Invisible TRUE
#' @export
run_geo_split <- function(con = NULL, output_dir = "r_analysis/output",
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

  log_info("Comparing ship to against bill to regions...")
  by_role <- qdf(con, paste0(
    "SELECT "
    , " COALESCE(s.region_name, 'UNKNOWN') AS region_name"
    , " , 'ship_to' AS role"
    , " , COUNT(*) AS order_lines"
    , " , SUM(f.line_total) AS revenue"
    , " FROM core.fact_orders AS f"
    , " LEFT JOIN core.dim_geo AS s"
    , " ON s.geo_key = f.ship_geo_key"
    , " GROUP BY COALESCE(s.region_name, 'UNKNOWN')"
    , " UNION ALL "
    , "SELECT "
    , " COALESCE(b.region_name, 'UNKNOWN')"
    , " , 'bill_to'"
    , " , COUNT(*)"
    , " , SUM(f.line_total)"
    , " FROM core.fact_orders AS f"
    , " LEFT JOIN core.dim_geo AS b"
    , " ON b.geo_key = f.bill_geo_key"
    , " GROUP BY COALESCE(b.region_name, 'UNKNOWN')"
    , " ORDER BY region_name, role"
  ))
  print(by_role)
  utils::write.csv(by_role, file.path(output_dir, "geo_ship_bill.csv"),
    row.names = FALSE
  )

  divergence <- qdf(con, paste0(
    "SELECT "
    , " COUNT(*) AS order_lines"
    , " , COUNT(*) FILTER ("
    , " WHERE s.region_name IS DISTINCT FROM b.region_name"
    , " ) AS divergent_lines"
    , " FROM core.fact_orders AS f"
    , " LEFT JOIN core.dim_geo AS s"
    , " ON s.geo_key = f.ship_geo_key"
    , " LEFT JOIN core.dim_geo AS b"
    , " ON b.geo_key = f.bill_geo_key"
  ))
  divergence$divergent_share <- (
    divergence$divergent_lines / divergence$order_lines
  )
  print(divergence)
  utils::write.csv(divergence, file.path(output_dir, "geo_divergence.csv"),
    row.names = FALSE
  )
  log_info(paste(
    "Share of lines where ship to differs from bill to:",
    scales::percent(divergence$divergent_share[[1L]])
  ))

  wide <- tidyr::pivot_wider(
    by_role,
    names_from = role, values_from = c(order_lines, revenue)
  )
  for (col in c("order_lines_ship_to", "order_lines_bill_to")) {
    wide[[col]][is.na(wide[[col]])] <- 0L
  }
  p <- ggplot2::ggplot(
    tidyr::pivot_longer(
      wide,
      cols = c(order_lines_ship_to, order_lines_bill_to),
      names_to = "role", values_to = "order_lines"
    ),
    ggplot2::aes(x = stats::reorder(region_name, order_lines), y = order_lines, fill = role)
  ) +
    ggplot2::geom_col(position = "dodge") +
    ggplot2::coord_flip() +
    ggplot2::labs(
      title = "Order lines by region, ship to against bill to",
      x = "Region", y = "Order lines", fill = "Role"
    ) +
    ggplot2::theme_minimal()
  ggplot2::ggsave(file.path(figures_dir, "geo_split.png"),
    plot = p, width = 9L, height = 6L, dpi = 150L
  )

  log_info("Geography split analysis completed.")
  invisible(TRUE)
}

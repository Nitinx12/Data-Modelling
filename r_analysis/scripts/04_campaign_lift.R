#' Campaign spend versus revenue lift analysis
#'
#' Joins spend to revenue through the shared dimensions only, never fact to
#' fact: `fact_campaign_spend` gives spend per campaign, `fact_less_fact`
#' gives promoted products per campaign, and `fact_orders` gives revenue for
#' those products inside the campaign window. The window overlap is a rough
#' attribution, stated as an assumption. Read only.
#'
#' @param con Open DBI connection (optional, opened via `connect_db()` when NULL)
#' @param output_dir Directory for CSV result tables
#' @param figures_dir Directory for PNG charts
#' @return Invisible TRUE
#' @export
run_campaign_lift <- function(con = NULL, output_dir = "r_analysis/output",
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

  log_info("Attributing revenue to campaigns through shared dimensions...")
  lift <- qdf(con, paste0(
    "WITH spend_per_campaign AS ("
    , " SELECT "
    , " s.campaign_name"
    , " , SUM(s.spend) AS total_spend"
    , " , SUM(s.impressions) AS total_impressions"
    , " , SUM(s.clicks) AS total_clicks"
    , " FROM core.fact_campaign_spend AS s"
    , " GROUP BY s.campaign_name"
    , ")"
    , " , skus_per_campaign AS ("
    , " SELECT "
    , " l.campaign_name"
    , " , COUNT(DISTINCT l.product_key) AS promoted_skus"
    , " FROM core.fact_less_fact AS l"
    , " WHERE l.product_key IS NOT NULL"
    , " GROUP BY l.campaign_name"
    , ")"
    , " , revenue_per_campaign AS ("
    , " SELECT "
    , " c.campaign_name"
    , " , SUM(f.line_total) AS window_revenue"
    , " FROM core.dim_campaign AS c"
    , " JOIN core.fact_less_fact AS l"
    , " ON l.campaign_key = c.campaign_key"
    , " JOIN core.dim_products AS p"
    , " ON p.product_key = l.product_key"
    , " JOIN core.fact_orders AS f"
    , " ON f.product_key = p.product_key"
    , " WHERE f.order_date BETWEEN c.start_date AND c.end_date"
    , " GROUP BY c.campaign_name"
    , ")"
    , " SELECT "
    , " c.campaign_name"
    , " , c.channel"
    , " , COALESCE(s.total_spend, 0) AS total_spend"
    , " , COALESCE(s.total_impressions, 0) AS total_impressions"
    , " , COALESCE(s.total_clicks, 0) AS total_clicks"
    , " , COALESCE(k.promoted_skus, 0) AS promoted_skus"
    , " , r.window_revenue"
    , " FROM core.dim_campaign AS c"
    , " LEFT JOIN spend_per_campaign AS s"
    , " ON s.campaign_name = c.campaign_name"
    , " LEFT JOIN skus_per_campaign AS k"
    , " ON k.campaign_name = c.campaign_name"
    , " LEFT JOIN revenue_per_campaign AS r"
    , " ON r.campaign_name = c.campaign_name"
    , " ORDER BY c.campaign_name"
  ))
  print(lift)
  utils::write.csv(lift, file.path(output_dir, "campaign_lift.csv"),
    row.names = FALSE
  )

  modelled <- lift[
    !is.na(lift$window_revenue) & lift$total_spend > 0L,
    , drop = FALSE
  ]
  if (nrow(modelled) < 3L) {
    log_warn("Fewer than three campaigns with spend and revenue, skipping model.")
    return(invisible(TRUE))
  }

  fit <- stats::lm(window_revenue ~ total_spend, data = modelled)
  modelled$fitted <- stats::fitted(fit)
  modelled$resid_std <- as.numeric(stats::rstandard(fit))
  modelled$outlier <- abs(modelled$resid_std) > 2.0
  rho <- stats::cor(modelled$total_spend, modelled$window_revenue)
  log_info(paste("Spend to revenue correlation:", round(rho, 3L)))
  log_info(paste(
    "Outlier campaigns:",
    paste(modelled$campaign_name[modelled$outlier], collapse = ", ")
  ))

  p <- ggplot2::ggplot(
    modelled,
    ggplot2::aes(x = total_spend, y = window_revenue)
  ) +
    ggplot2::geom_point(
      ggplot2::aes(color = outlier, size = promoted_skus)
    ) +
    ggplot2::geom_smooth(method = "lm", se = TRUE, color = "#2C3E50") +
    ggplot2::geom_text(
      data = modelled[modelled$outlier, , drop = FALSE],
      ggplot2::aes(label = campaign_name),
      vjust = -0.8, size = 3.0
    ) +
    ggplot2::scale_x_continuous(labels = scales::label_number()) +
    ggplot2::scale_y_continuous(labels = scales::label_number()) +
    ggplot2::labs(
      title = "Campaign spend against window revenue with linear fit",
      subtitle = paste("Correlation:", round(rho, 3L)),
      x = "Total spend", y = "Promoted SKU revenue in campaign window",
      color = "Outlier", size = "Promoted SKUs"
    ) +
    ggplot2::theme_minimal()
  ggplot2::ggsave(file.path(figures_dir, "campaign_lift.png"),
    plot = p, width = 9L, height = 6L, dpi = 150L
  )

  log_info("Campaign lift analysis completed.")
  invisible(TRUE)
}

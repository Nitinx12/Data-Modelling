#' Fulfillment funnel and time to pay analysis
#'
#' Profiles the accumulating snapshot `core.fact_order_process`: stage to
#' stage conversion from ordered to paid, plus a survival curve over time to
#' pay where unpaid orders are censored at the current date. Read only.
#'
#' @param con Open DBI connection (optional, opened via `connect_db()` when NULL)
#' @param output_dir Directory for CSV result tables
#' @param figures_dir Directory for PNG charts
#' @return Invisible TRUE
#' @export
run_fulfillment_funnel <- function(con = NULL, output_dir = "r_analysis/output",
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

  log_info("Building fulfillment funnel...")
  funnel <- qdf(con, paste0(
    "SELECT "
    , " COUNT(*) AS ordered"
    , " , COUNT(*) FILTER (WHERE f.ship_date IS NOT NULL) AS shipped"
    , " , COUNT(*) FILTER (WHERE f.delivery_date IS NOT NULL) AS delivered"
    , " , COUNT(*) FILTER (WHERE f.invoice_date IS NOT NULL) AS invoiced"
    , " , COUNT(*) FILTER (WHERE f.pay_date IS NOT NULL) AS paid"
    , " FROM core.fact_order_process AS f"
  ))
  stages <- data.frame(
    stage = c("ordered", "shipped", "delivered", "invoiced", "paid"),
    orders = as.numeric(unlist(funnel[1L, ], use.names = FALSE)),
    stringsAsFactors = FALSE
  )
  stages$share_of_ordered <- stages$orders / stages$orders[[1L]]
  stages$step_conversion <- c(
    1.0, stages$orders[-1L] / stages$orders[-nrow(stages)]
  )
  print(stages)
  utils::write.csv(stages, file.path(output_dir, "funnel_counts.csv"),
    row.names = FALSE
  )

  p_funnel <- ggplot2::ggplot(
    stages,
    ggplot2::aes(
      x = factor(stage, levels = stage), y = orders
    )
  ) +
    ggplot2::geom_col(fill = "#3498DB") +
    ggplot2::geom_text(
      ggplot2::aes(
        label = paste0(orders, " (", scales::percent(share_of_ordered), ")")
      ),
      vjust = -0.4, size = 3.5
    ) +
    ggplot2::labs(
      title = "Fulfillment funnel, ordered to paid",
      x = "Milestone", y = "Order count"
    ) +
    ggplot2::theme_minimal()
  ggplot2::ggsave(file.path(figures_dir, "fulfillment_funnel.png"),
    plot = p_funnel, width = 8L, height = 5L, dpi = 150L
  )

  log_info("Modelling time to pay with censoring...")
  pay_sample <- qdf(con, paste0(
    "SELECT "
    , " f.invoice_date"
    , " , f.pay_date"
    , " , f.days_invoice_to_pay"
    , " FROM core.fact_order_process AS f"
    , " WHERE f.invoice_date IS NOT NULL"
    , " ORDER BY random()"
    , " LIMIT 5000"
  ))
  pay_sample$paid <- !is.na(pay_sample$pay_date)
  pay_sample$time_days <- ifelse(
    pay_sample$paid,
    suppressWarnings(as.numeric(pay_sample$days_invoice_to_pay)),
    as.numeric(Sys.Date() - as.Date(pay_sample$invoice_date))
  )
  pay_sample <- pay_sample[!is.na(pay_sample$time_days) & pay_sample$time_days >= 0L, ]

  paid_times <- pay_sample$time_days[pay_sample$paid]
  qs <- stats::quantile(paid_times, probs = c(0.25, 0.5, 0.75))
  iqr <- qs[[3L]] - qs[[1L]]
  upper <- qs[[3L]] + 1.5 * iqr
  summary_tbl <- data.frame(
    orders_invoiced = nrow(pay_sample),
    orders_paid = sum(pay_sample$paid),
    median_days_to_pay = unname(qs[[2L]]),
    p75_days_to_pay = unname(qs[[3L]]),
    outlier_threshold_days = unname(upper),
    outlier_orders = sum(paid_times > upper),
    stringsAsFactors = FALSE
  )
  print(summary_tbl)
  utils::write.csv(summary_tbl,
    file.path(output_dir, "time_to_pay_summary.csv"),
    row.names = FALSE
  )

  if (requireNamespace("survival", quietly = TRUE)) {
    fit <- survival::survfit(
      survival::Surv(time_days, paid) ~ 1L, data = pay_sample
    )
    surv_df <- data.frame(
      time = fit$time, surv = fit$surv,
      upper = fit$upper, lower = fit$lower
    )
  } else {
    log_warn("Package survival not available, using empirical curve.")
    ord <- sort(pay_sample$time_days)
    surv_df <- data.frame(
      time = sort(unique(ord)),
      surv = 1.0 - ecdf(ord)(sort(unique(ord))),
      upper = NA_real_, lower = NA_real_
    )
  }
  p_surv <- ggplot2::ggplot(
    surv_df, ggplot2::aes(x = time, y = surv)
  ) +
    ggplot2::geom_step(color = "#E67E22", linewidth = 1L) +
    ggplot2::geom_ribbon(
      ggplot2::aes(ymin = lower, ymax = upper),
      alpha = 0.2, fill = "#E67E22"
    ) +
    ggplot2::labs(
      title = "Time to pay, unpaid orders censored at current date",
      x = "Days since invoice", y = "Share still unpaid"
    ) +
    ggplot2::theme_minimal()
  ggplot2::ggsave(file.path(figures_dir, "pay_survival.png"),
    plot = p_surv, width = 8L, height = 5L, dpi = 150L
  )

  log_info("Fulfillment funnel analysis completed.")
  invisible(TRUE)
}

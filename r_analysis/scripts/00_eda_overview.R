#' Headless EDA overview of the `core` warehouse
#'
#' Mirrors `notebooks/00_eda_overview.qmd` without rendering anything: every
#' check runs as aggregate SQL plus small sampled pulls, charts go to PNG
#' files, and tables go to CSV files. Fully read only against `core`; it
#' creates no database objects.
#'
#' @param con Open DBI connection (optional, opened via `connect_db()` when NULL)
#' @param output_dir Directory for CSV result tables
#' @param figures_dir Directory for PNG charts
#' @return Invisible TRUE. Logs a clean/dirty verdict at the end.
#' @export
run_eda_overview <- function(con = NULL, output_dir = "r_analysis/output",
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

  qi <- function(x) paste0('"', gsub('"', '""', x, fixed = TRUE), '"')
  q <- function(con, sql) {
    if (exists("fix_int64", mode = "function")) {
      fix_int64(DBI::dbGetQuery(con, sql))
    } else {
      DBI::dbGetQuery(con, sql)
    }
  }

  dim_tables <- c(
    "dim_campaign", "dim_customers", "dim_geo", "dim_orders_flag", "dim_products"
  )
  fact_tables <- c(
    "fact_campaign_spend", "fact_inventory", "fact_less_fact",
    "fact_order_process", "fact_orders"
  )
  grain_keys <- list(
    fact_orders = c("order_id", "line_id"),
    fact_order_process = c("order_id"),
    fact_inventory = c("product_name", "period_month"),
    fact_campaign_spend = c("campaign_name", "spend_date"),
    fact_less_fact = c("campaign_name", "promoted_sku")
  )

  table_size <- function(table) {
    rows <- q(con, paste0("SELECT COUNT(*) AS n FROM core.", table))$n[[1L]]
    cols <- q(con, paste0(
      "SELECT COUNT(*) AS n FROM information_schema.columns",
      " WHERE table_schema = 'core' AND table_name = '", table, "'"
    ))$n[[1L]]
    data.frame(
      table_name = table, row_count = as.numeric(rows),
      column_count = as.numeric(cols), stringsAsFactors = FALSE
    )
  }

  log_info("Profiling dimensions...")
  dim_summary <- do.call(rbind, lapply(dim_tables, table_size))
  print(dim_summary)
  utils::write.csv(dim_summary, file.path(output_dir, "eda_dim_summary.csv"),
    row.names = FALSE
  )

  log_info("Profiling facts...")
  fact_summary <- do.call(rbind, lapply(fact_tables, table_size))
  print(fact_summary)
  utils::write.csv(fact_summary, file.path(output_dir, "eda_fact_summary.csv"),
    row.names = FALSE
  )

  # SCD2 block for dim_customers.
  log_info("Checking dim_customers SCD2 history...")
  scd2_status <- q(con, paste0(
    "SELECT ",
    " COUNT(*) FILTER (WHERE d.is_current) AS open_rows",
    " , COUNT(*) FILTER (WHERE NOT d.is_current) AS closed_rows",
    " , COUNT(DISTINCT d.customer_id) AS distinct_customers",
    " FROM core.dim_customers AS d"
  ))
  print(scd2_status)
  utils::write.csv(scd2_status, file.path(output_dir, "eda_scd2_status.csv"),
    row.names = FALSE
  )

  scd2_versions <- q(con, paste0(
    "SELECT ",
    " d.customer_id",
    " , COUNT(*) AS version_count",
    " FROM core.dim_customers AS d",
    " GROUP BY d.customer_id",
    " ORDER BY COUNT(*) DESC"
  ))
  utils::write.csv(scd2_versions,
    file.path(output_dir, "eda_scd2_versions.csv"),
    row.names = FALSE
  )
  p_versions <- ggplot2::ggplot(
    scd2_versions, ggplot2::aes(x = version_count)
  ) +
    ggplot2::geom_histogram(binwidth = 1L, fill = "#3498DB", color = "#2C3E50") +
    ggplot2::labs(
      title = "Customer version count distribution",
      x = "Versions per customer", y = "Customer count"
    ) +
    ggplot2::theme_minimal()
  ggplot2::ggsave(file.path(figures_dir, "eda_customer_versions.png"),
    plot = p_versions, width = 8L, height = 5L, dpi = 150L
  )

  scd2_spans <- q(con, paste0(
    "SELECT ",
    " EXTRACT(EPOCH FROM (COALESCE(d.valid_to, now()) - d.valid_from)) / 86400.0",
    " AS lifespan_days",
    " , d.is_current",
    " FROM core.dim_customers AS d"
  ))
  utils::write.csv(scd2_spans,
    file.path(output_dir, "eda_scd2_spans.csv"),
    row.names = FALSE
  )
  p_spans <- ggplot2::ggplot(scd2_spans, ggplot2::aes(x = lifespan_days)) +
    ggplot2::geom_histogram(bins = 40L, fill = "#2ECC71", color = "#2C3E50") +
    ggplot2::facet_wrap(~is_current, labeller = ggplot2::label_both) +
    ggplot2::labs(
      title = "Version lifespan, open against closed",
      x = "Lifespan in days", y = "Version count"
    ) +
    ggplot2::theme_minimal()
  ggplot2::ggsave(file.path(figures_dir, "eda_customer_spans.png"),
    plot = p_spans, width = 9L, height = 5L, dpi = 150L
  )

  # Grain checks on every fact natural key.
  log_info("Checking fact grains...")
  grain_results <- do.call(rbind, lapply(fact_tables, function(t) {
    key_cols <- grain_keys[[t]]
    quoted <- vapply(key_cols, qi, character(1L))
    group_list <- paste(quoted, collapse = " , ")
    not_null <- paste(paste0(quoted, " IS NOT NULL"), collapse = " AND ")
    res <- q(con, paste0(
      "SELECT COUNT(*) AS row_count",
      " , COALESCE(SUM(dup_rows), 0) AS extra_rows",
      " FROM core.", t,
      " LEFT JOIN (",
      " SELECT COUNT(*) - 1 AS dup_rows",
      " FROM core.", t,
      " WHERE ", not_null,
      " GROUP BY ", group_list,
      " HAVING COUNT(*) > 1",
      ") AS g ON TRUE"
    ))
    data.frame(
      table_name = t, grain = paste(key_cols, collapse = " + "),
      row_count = as.numeric(res$row_count[[1L]]),
      extra_rows = as.numeric(res$extra_rows[[1L]]),
      stringsAsFactors = FALSE
    )
  }))
  print(grain_results)
  utils::write.csv(grain_results, file.path(output_dir, "eda_grain_checks.csv"),
    row.names = FALSE
  )

  # NULL census per fact column.
  log_info("Counting NULLs across fact columns...")
  null_results <- do.call(rbind, lapply(fact_tables, function(t) {
    cols <- q(con, paste0(
      "SELECT c.column_name FROM information_schema.columns AS c",
      " WHERE c.table_schema = 'core' AND c.table_name = '", t, "'",
      " ORDER BY c.ordinal_position"
    ))$column_name
    parts <- vapply(cols, function(col) {
      paste0(
        "COUNT(*) FILTER (WHERE ", qi(col), " IS NULL) AS ", qi(paste0(col, "__n"))
      )
    }, character(1L))
    res <- q(con, paste0(
      "SELECT COUNT(*) AS rows_checked , ", paste(parts, collapse = " , "),
      " FROM core.", t
    ))
    data.frame(
      table_name = t,
      column_name = sub("__n$", "", names(res)[-1L]),
      null_count = as.numeric(unlist(res[1L, -1L], use.names = FALSE)),
      rows_checked = as.numeric(res$rows_checked[[1L]]),
      stringsAsFactors = FALSE
    )
  }))
  utils::write.csv(null_results, file.path(output_dir, "eda_null_counts.csv"),
    row.names = FALSE
  )

  # Measure summaries plus IQR outlier flags.
  log_info("Summarising numeric measures...")
  measure_cols <- list(
    fact_orders = c("quantity", "unit_price", "unit_cost", "discount_pct", "line_total"),
    fact_order_process = c(
      "amount", "days_order_to_ship", "days_ship_to_delivery",
      "days_order_to_invoice", "days_invoice_to_pay"
    ),
    fact_inventory = c("quantity"),
    fact_campaign_spend = c("impressions", "clicks", "spend")
  )
  flag_iqr <- function(x) {
    x <- x[!is.na(x)]
    if (length(x) < 5L) {
      return(c(lower = NA_real_, upper = NA_real_, flagged = 0L))
    }
    qs <- stats::quantile(x, probs = c(0.25, 0.75))
    iqr <- qs[[2L]] - qs[[1L]]
    lower <- qs[[1L]] - 1.5 * iqr
    upper <- qs[[2L]] + 1.5 * iqr
    c(lower = unname(lower), upper = unname(upper),
      flagged = sum(x < lower | x > upper))
  }
  stat_rows <- list()
  flag_rows <- list()
  for (t in names(measure_cols)) {
    live <- intersect(
      measure_cols[[t]],
      q(con, paste0(
        "SELECT c.column_name FROM information_schema.columns AS c",
        " WHERE c.table_schema = 'core' AND c.table_name = '", t, "'"
      ))$column_name
    )
    for (col in live) {
      res <- q(con, paste0(
        "SELECT MIN(", qi(col), ") AS mn, MAX(", qi(col), ") AS mx",
        ", AVG(", qi(col), ") AS av",
        ", PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ", qi(col), ") AS md",
        " FROM core.", t
      ))
      stat_rows[[paste(t, col)]] <- data.frame(
        table_name = t, measure = col,
        min = as.numeric(res$mn[[1L]]), max = as.numeric(res$mx[[1L]]),
        mean = as.numeric(res$av[[1L]]), median = as.numeric(res$md[[1L]]),
        stringsAsFactors = FALSE
      )
      samp <- q(con, paste0(
        "SELECT ", qi(col), " AS v FROM core.", t,
        " WHERE ", qi(col), " IS NOT NULL",
        " ORDER BY random() LIMIT 2000"
      ))
      vals <- suppressWarnings(as.numeric(samp$v))
      info <- flag_iqr(vals)
      flag_rows[[paste(t, col)]] <- data.frame(
        table_name = t, measure = col, sample_n = sum(!is.na(vals)),
        lower_bound = info[["lower"]], upper_bound = info[["upper"]],
        flagged = info[["flagged"]],
        stringsAsFactors = FALSE
      )
      plot_vals <- vals[!is.na(vals)]
      if (length(plot_vals) > 0L) {
        p <- ggplot2::ggplot(
          data.frame(value = plot_vals), ggplot2::aes(x = value)
        ) +
          ggplot2::geom_histogram(bins = 40L, fill = "#9B59B6", color = "#2C3E50") +
          ggplot2::labs(title = paste0(t, ": ", col), x = col, y = "Sample count") +
          ggplot2::theme_minimal()
        ggplot2::ggsave(
          file.path(figures_dir, paste0("eda_hist_", t, "_", col, ".png")),
          plot = p, width = 7L, height = 4.5, dpi = 150L
        )
      }
    }
  }
  utils::write.csv(do.call(rbind, stat_rows),
    file.path(output_dir, "eda_measure_summary.csv"),
    row.names = FALSE
  )
  utils::write.csv(do.call(rbind, flag_rows),
    file.path(output_dir, "eda_outlier_flags.csv"),
    row.names = FALSE
  )

  # Date coverage plus the inventory month continuity check.
  log_info("Checking date coverage...")
  date_cols <- q(con, paste0(
    "SELECT c.table_name, c.column_name",
    " FROM information_schema.columns AS c",
    " WHERE c.table_schema = 'core'",
    " AND c.table_name IN ('",
    paste(fact_tables, collapse = "', '"), "')",
    " AND c.data_type IN ('date', 'timestamp without time zone',",
    " 'timestamp with time zone')",
    " ORDER BY c.table_name, c.ordinal_position"
  ))
  date_results <- do.call(rbind, lapply(seq_len(nrow(date_cols)), function(i) {
    t <- date_cols$table_name[[i]]
    col <- date_cols$column_name[[i]]
    res <- q(con, paste0(
      "SELECT MIN(", qi(col), ") AS mn, MAX(", qi(col), ") AS mx",
      ", COUNT(DISTINCT ", qi(col), ") AS dc",
      ", COUNT(*) FILTER (WHERE ", qi(col), " IS NULL) AS nc",
      " FROM core.", t
    ))
    data.frame(
      table_name = t, column_name = col,
      min_value = as.character(res$mn[[1L]]),
      max_value = as.character(res$mx[[1L]]),
      distinct_count = as.numeric(res$dc[[1L]]),
      null_count = as.numeric(res$nc[[1L]]),
      stringsAsFactors = FALSE
    )
  }))
  utils::write.csv(date_results, file.path(output_dir, "eda_date_coverage.csv"),
    row.names = FALSE
  )
  inv_gap <- q(con, paste0(
    "SELECT COUNT(DISTINCT f.period_month) AS observed_months",
    " , (EXTRACT(YEAR FROM age(MAX(f.period_month), MIN(f.period_month))) * 12",
    " + EXTRACT(MONTH FROM age(MAX(f.period_month), MIN(f.period_month)))",
    " + 1) AS expected_months",
    " FROM core.fact_inventory AS f"
  ))
  utils::write.csv(inv_gap, file.path(output_dir, "eda_inventory_gap.csv"),
    row.names = FALSE
  )

  # Lightweight mirrors of the five quality loops (core only, read only).
  log_info("Running quality cross checks...")
  req_cols <- q(con, paste0(
    "SELECT c.table_name, c.column_name",
    " FROM information_schema.columns AS c",
    " WHERE c.table_schema = 'core'",
    " AND c.table_name IN ('",
    paste(c(dim_tables, fact_tables), collapse = "', '"), "')",
    " AND c.is_nullable = 'NO'",
    " AND c.data_type IN ('character varying', 'character', 'text')",
    " ORDER BY c.table_name, c.ordinal_position"
  ))
  blank_total <- 0L
  if (nrow(req_cols) > 0L) {
    blank_rows <- do.call(rbind, lapply(seq_len(nrow(req_cols)), function(i) {
      t <- req_cols$table_name[[i]]
      col <- req_cols$column_name[[i]]
      n <- q(con, paste0(
        "SELECT COUNT(*) AS n FROM core.", t,
        " WHERE NULLIF(BTRIM(", qi(col), "), '') IS NULL"
      ))$n[[1L]]
      data.frame(
        table_name = t, column_name = col,
        blank_rows = as.numeric(n), stringsAsFactors = FALSE
      )
    }))
    blank_total <- sum(blank_rows$blank_rows)
    utils::write.csv(blank_rows,
      file.path(output_dir, "eda_dq_required_text.csv"),
      row.names = FALSE
    )
  }

  future_total <- 0L
  if (nrow(date_cols) > 0L) {
    future_rows <- do.call(rbind, lapply(seq_len(nrow(date_cols)), function(i) {
      t <- date_cols$table_name[[i]]
      col <- date_cols$column_name[[i]]
      n <- q(con, paste0(
        "SELECT COUNT(*) AS n FROM core.", t,
        " WHERE ", qi(col), " > CURRENT_DATE"
      ))$n[[1L]]
      data.frame(
        table_name = t, column_name = col,
        future_rows = as.numeric(n), stringsAsFactors = FALSE
      )
    }))
    future_total <- sum(future_rows$future_rows)
    utils::write.csv(future_rows,
      file.path(output_dir, "eda_dq_future_dates.csv"),
      row.names = FALSE
    )
  }

  neg_total <- 0L
  neg_rows <- do.call(rbind, unlist(lapply(names(measure_cols), function(t) {
    live <- intersect(
      measure_cols[[t]],
      q(con, paste0(
        "SELECT c.column_name FROM information_schema.columns AS c",
        " WHERE c.table_schema = 'core' AND c.table_name = '", t, "'"
      ))$column_name
    )
    live <- intersect(live, c(
      "quantity", "unit_price", "unit_cost", "line_total",
      "amount", "impressions", "clicks", "spend"
    ))
    lapply(live, function(col) {
      n <- q(con, paste0(
        "SELECT COUNT(*) AS n FROM core.", t,
        " WHERE ", qi(col), " < 0"
      ))$n[[1L]]
      data.frame(
        table_name = t, column_name = col,
        negative_rows = as.numeric(n), stringsAsFactors = FALSE
      )
    })
  }), recursive = FALSE))
  if (!is.null(neg_rows)) {
    neg_total <- sum(neg_rows$negative_rows)
    utils::write.csv(neg_rows, file.path(output_dir, "eda_dq_negatives.csv"),
      row.names = FALSE
    )
  }

  orphans <- q(con, paste0(
    "SELECT 'fact_orders leaves customer_key unresolved' AS check_name",
    " , COUNT(*) AS unresolved_rows",
    " FROM core.fact_orders AS f",
    " LEFT JOIN core.dim_customers AS d ON d.customer_key = f.customer_key",
    " WHERE f.customer_key IS NULL OR d.customer_key IS NULL",
    " UNION ALL ",
    "SELECT 'fact_orders leaves product_key unresolved', COUNT(*)",
    " FROM core.fact_orders AS f",
    " LEFT JOIN core.dim_products AS d ON d.product_key = f.product_key",
    " WHERE f.product_key IS NULL OR d.product_key IS NULL",
    " UNION ALL ",
    "SELECT 'fact_orders leaves ship_geo_key unresolved', COUNT(*)",
    " FROM core.fact_orders AS f",
    " LEFT JOIN core.dim_geo AS g ON g.geo_key = f.ship_geo_key",
    " WHERE f.ship_geo_key IS NULL OR g.geo_key IS NULL",
    " UNION ALL ",
    "SELECT 'fact_orders leaves bill_geo_key unresolved', COUNT(*)",
    " FROM core.fact_orders AS f",
    " LEFT JOIN core.dim_geo AS g ON g.geo_key = f.bill_geo_key",
    " WHERE f.bill_geo_key IS NULL OR g.geo_key IS NULL",
    " UNION ALL ",
    "SELECT 'fact_order_process leaves customer_key unresolved', COUNT(*)",
    " FROM core.fact_order_process AS f",
    " LEFT JOIN core.dim_customers AS d ON d.customer_key = f.customer_key",
    " WHERE f.customer_key IS NULL OR d.customer_key IS NULL",
    " UNION ALL ",
    "SELECT 'fact_inventory leaves product_key unresolved', COUNT(*)",
    " FROM core.fact_inventory AS f",
    " LEFT JOIN core.dim_products AS d ON d.product_key = f.product_key",
    " WHERE f.product_key IS NULL OR d.product_key IS NULL",
    " UNION ALL ",
    "SELECT 'fact_campaign_spend leaves campaign_key unresolved', COUNT(*)",
    " FROM core.fact_campaign_spend AS f",
    " LEFT JOIN core.dim_campaign AS d ON d.campaign_key = f.campaign_key",
    " WHERE f.campaign_key IS NULL OR d.campaign_key IS NULL"
  ))
  utils::write.csv(orphans, file.path(output_dir, "eda_dq_orphans.csv"),
    row.names = FALSE
  )

  failures <- sum(
    sum(grain_results$extra_rows),
    blank_total, future_total, neg_total,
    sum(as.numeric(orphans$unresolved_rows))
  )
  log_info(paste("EDA cross check failures:", failures))
  if (failures == 0L) {
    log_info("Verdict: data is clean and ready for targeted analysis.")
  } else {
    log_warn("Verdict: failures found. Compare against the five quality loops.")
  }

  invisible(TRUE)
}

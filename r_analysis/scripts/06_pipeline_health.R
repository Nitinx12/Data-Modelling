#' Pipeline run health analysis
#'
#' Run duration trends from `core.pipeline_run_log` with interquartile
#' outlier flags, plus a stacked bar of stage durations per run. Skips
#' gracefully when the log table does not exist yet. Read only.
#'
#' @param con Open DBI connection (optional, opened via `connect_db()` when NULL)
#' @param output_dir Directory for CSV result tables
#' @param figures_dir Directory for PNG charts
#' @return Invisible TRUE
#' @export
run_pipeline_health <- function(con = NULL, output_dir = "r_analysis/output",
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

  exists <- DBI::dbGetQuery(con, paste0(
    "SELECT COUNT(*) AS n FROM information_schema.tables",
    " WHERE table_schema = 'core' AND table_name = 'pipeline_run_log'"
  ))$n[[1L]] > 0L
  if (!exists) {
    log_warn("core.pipeline_run_log not found, skipping pipeline health.")
    return(invisible(TRUE))
  }

  log_info("Summarising pipeline runs...")
  runs <- qdf(con, paste0(
    "SELECT "
    , " r.run_id"
    , " , r.stage"
    , " , r.model_name"
    , " , r.status"
    , " , r.duration_ms"
    , " , r.row_count"
    , " , r.started_at"
    , " , r.finished_at"
    , " FROM core.pipeline_run_log AS r"
    , " ORDER BY r.started_at"
  ))
  runs$started_at <- as.POSIXct(runs$started_at, tz = "UTC")
  runs$duration_s <- suppressWarnings(as.numeric(runs$duration_ms)) / 1000.0
  utils::write.csv(runs, file.path(output_dir, "pipeline_runs.csv"),
    row.names = FALSE
  )

  run_totals <- aggregate(
    duration_s ~ run_id, data = runs,
    FUN = function(x) sum(x, na.rm = TRUE)
  )
  names(run_totals)[2L] <- "total_s"
  first_seen <- aggregate(
    started_at ~ run_id, data = runs, FUN = function(x) min(x, na.rm = TRUE)
  )
  run_totals <- merge(run_totals, first_seen, by = "run_id")
  run_totals <- run_totals[order(run_totals$started_at), , drop = FALSE]

  qs <- stats::quantile(run_totals$total_s, probs = c(0.25, 0.75), na.rm = TRUE)
  iqr <- qs[[2L]] - qs[[1L]]
  upper <- qs[[2L]] + 1.5 * iqr
  run_totals$outlier <- run_totals$total_s > upper
  log_info(paste(
    "Slow run threshold (s):", round(unname(upper), 1L),
    "| flagged runs:", sum(run_totals$outlier)
  ))
  utils::write.csv(
    run_totals[run_totals$outlier, , drop = FALSE],
    file.path(output_dir, "pipeline_outliers.csv"),
    row.names = FALSE
  )

  p_trend <- ggplot2::ggplot(
    run_totals, ggplot2::aes(x = started_at, y = total_s)
  ) +
    ggplot2::geom_line(color = "#7F8C8D") +
    ggplot2::geom_point(
      ggplot2::aes(color = outlier), size = 2.5
    ) +
    ggplot2::geom_hline(
      yintercept = unname(upper), linetype = "dashed", color = "#C0392B"
    ) +
    ggplot2::labs(
      title = "Pipeline run duration trend with outlier threshold",
      x = "Run start", y = "Total duration in seconds", color = "Outlier"
    ) +
    ggplot2::theme_minimal()
  ggplot2::ggsave(file.path(figures_dir, "pipeline_health.png"),
    plot = p_trend, width = 9L, height = 5L, dpi = 150L
  )

  recent_ids <- utils::tail(unique(runs$run_id), 30L)
  recent <- runs[runs$run_id %in% recent_ids, , drop = FALSE]
  dropped <- sum(is.na(recent$duration_s))
  if (dropped > 0L) {
    log_info(paste(
      "Stage chart excludes rows without a logged duration:", dropped
    ))
  }
  p_stages <- ggplot2::ggplot(
    recent,
    ggplot2::aes(x = run_id, y = duration_s, fill = stage)
  ) +
    ggplot2::geom_col() +
    ggplot2::coord_flip() +
    ggplot2::labs(
      title = "Stage durations per run, most recent thirty runs",
      x = "Run", y = "Seconds", fill = "Stage"
    ) +
    ggplot2::theme_minimal()
  ggplot2::ggsave(file.path(figures_dir, "pipeline_stages.png"),
    plot = p_stages, width = 9L, height = 7L, dpi = 150L
  )

  log_info("Pipeline health analysis completed.")
  invisible(TRUE)
}

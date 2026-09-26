#' Ordered runner for the headless R analysis scripts
#'
#' Sources every numbered analysis script once and calls its `run_*()`
#' entry point with the shared warehouse connection. Scripts that do not
#' exist yet (03 through 07) are logged and skipped so the EDA and 01/02
#' stages keep running while later analyses are still being built.
#'
#' @param con Open DBI connection to the warehouse (from `connect_db()`)
#' @param output_dir Directory for CSV/RDS result tables
#' @param figures_dir Directory for PNG charts
#' @param scripts_dir Directory holding the numbered scripts. Guessed from the
#'   calling entry point when NULL.
#' @return Invisible TRUE
#' @export
run_all <- function(con, output_dir, figures_dir, scripts_dir = NULL) {
  if (is.null(scripts_dir)) {
    candidates <- character(0)
    try(
      {
        cmd_args <- commandArgs(trailingOnly = FALSE)
        file_arg <- grep("^--file=", cmd_args, value = TRUE)
        if (length(file_arg) == 1L) {
          entry_dir <- dirname(normalizePath(sub("^--file=", "", file_arg[[1L]])))
          candidates <- c(
            candidates,
            entry_dir,
            file.path(entry_dir, "scripts")
          )
        }
      },
      silent = TRUE
    )
    candidates <- c(
      candidates,
      file.path(find_project_root(), "r_analysis", "scripts")
    )
    hits <- vapply(
      candidates,
      function(d) file.exists(file.path(d, "01_customer_tenure.R")),
      logical(1L)
    )
    if (!any(hits)) {
      stop("Could not locate the numbered analysis scripts.")
    }
    scripts_dir <- candidates[which(hits)[1L]]
  }

  for (dir in c(output_dir, figures_dir)) {
    if (!dir.exists(dir)) {
      dir.create(dir, recursive = TRUE)
    }
  }

  analyses <- list(
    list(file = "01_customer_tenure.R", fun = "run_customer_tenure"),
    list(file = "02_revenue_seasonality.R", fun = "run_revenue_seasonality"),
    list(file = "03_fulfillment_funnel.R", fun = "run_fulfillment_funnel"),
    list(file = "04_campaign_lift.R", fun = "run_campaign_lift"),
    list(file = "05_inventory_health.R", fun = "run_inventory_health"),
    list(file = "06_pipeline_health.R", fun = "run_pipeline_health"),
    list(file = "07_geo_split.R", fun = "run_geo_split")
  )

  for (analysis in analyses) {
    script_path <- file.path(scripts_dir, analysis$file)
    if (!file.exists(script_path)) {
      log_warn(paste("Script not found, skipping:", analysis$file))
      next
    }
    log_info(paste("Running:", analysis$file))
    source(script_path)
    runner <- get(analysis$fun, mode = "function")
    runner(con, output_dir = output_dir, figures_dir = figures_dir)
    log_info(paste("Completed:", analysis$file))
  }

  invisible(TRUE)
}

#!/usr/bin/env Rscript
# CLI entry point for the R analysis layer (read only against `core`).
#
# Usage from the repository root:
#   Rscript r_analysis/run_r_script.R 00_eda_overview   # headless EDA profiling
#   Rscript r_analysis/run_r_script.R all               # every headless script
#
# Quarto renders are driven by `make eda` / `make notebooks`, not by this file.

args <- commandArgs(trailingOnly = TRUE)
mode <- if (length(args) >= 1L) args[[1L]] else "help"

resolve_entry_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) == 1L) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[[1L]]))))
  }
  candidate <- file.path(normalizePath(getwd(), mustWork = TRUE), "r_analysis")
  if (dir.exists(file.path(candidate, "scripts"))) {
    return(candidate)
  }
  normalizePath(getwd(), mustWork = TRUE)
}

entry_dir <- resolve_entry_dir()
scripts_dir <- file.path(entry_dir, "scripts")
output_dir <- file.path(entry_dir, "output")
figures_dir <- file.path(entry_dir, "figures")

source(file.path(scripts_dir, "logger.R"))
source(file.path(scripts_dir, "db_connect.R"))

# Project root is the parent of r_analysis/ when launched normally; fall back
# to the dotenv finder otherwise so log and output paths stay stable.
project_root <- dirname(entry_dir)
if (!dir.exists(file.path(project_root, "r_analysis"))) {
  project_root <- find_project_root()
  entry_dir <- file.path(project_root, "r_analysis")
  scripts_dir <- file.path(entry_dir, "scripts")
  output_dir <- file.path(entry_dir, "output")
  figures_dir <- file.path(entry_dir, "figures")
}

log_file <- init_logger(file.path(output_dir, "run_log.txt"))
log_info(paste0("Starting R analysis in mode: ", mode), log_file)

run_with_connection <- function(fun) {
  con <- connect_db()
  on.exit(disconnect_db(con), add = TRUE)
  fun(con)
}

if (mode == "00_eda_overview") {
  log_info("Running 00_eda_overview...", log_file)
  source(file.path(scripts_dir, "00_eda_overview.R"))
  run_with_connection(function(con) {
    run_eda_overview(con, output_dir = output_dir, figures_dir = figures_dir)
  })
  log_info("00_eda_overview completed", log_file)
} else if (mode == "all") {
  log_info("Running all headless analysis scripts...", log_file)
  source(file.path(scripts_dir, "run_all.R"))
  run_with_connection(function(con) {
    run_all(con, output_dir = output_dir, figures_dir = figures_dir)
  })
  log_info("All headless analysis scripts completed", log_file)
} else {
  cat("Usage: Rscript r_analysis/run_r_script.R [00_eda_overview|all]\n")
  quit(status = 1L)
}

log_info("R analysis completed", log_file)

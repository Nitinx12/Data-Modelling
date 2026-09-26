#' Logging utility for R analysis scripts
#'
#' Mirrors the output style of utils/logger.py in the Python pipeline.
#' Logs to console with timestamped messages.

#' Initialize logger
#'
#' @param log_file Optional path to log file (default: r_analysis/output/run_log.txt)
#' @export
init_logger <- function(log_file = NULL) {
  if (is.null(log_file)) {
    log_file <- file.path("r_analysis", "output", "run_log.txt")
  }

  # Create directory if needed
  log_dir <- dirname(log_file)
  if (!dir.exists(log_dir)) {
    dir.create(log_dir, recursive = TRUE)
  }

  # Create or overwrite log file with header
  cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), " [INFO] Logger initialized\n",
      file = log_file, append = FALSE)

  return(invisible(log_file))
}

#' Log an info message
#'
#' @param msg Message to log
#' @param log_file Log file path (from init_logger)
#' @export
log_info <- function(msg, log_file = NULL) {
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  line <- paste0(timestamp, " [INFO] ", msg)
  cat(line, "\n")
  if (!is.null(log_file)) {
    cat(line, "\n", file = log_file, append = TRUE)
  }
}

#' Log a warning message
#'
#' @param msg Message to log
#' @param log_file Log file path (from init_logger)
#' @export
log_warn <- function(msg, log_file = NULL) {
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  line <- paste0(timestamp, " [WARN] ", msg)
  cat(line, "\n")
  if (!is.null(log_file)) {
    cat(line, "\n", file = log_file, append = TRUE)
  }
}

#' Log an error message
#'
#' @param msg Message to log
#' @param log_file Log file path (from init_logger)
#' @export
log_error <- function(msg, log_file = NULL) {
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  line <- paste0(timestamp, " [ERROR] ", msg)
  cat(line, "\n")
  if (!is.null(log_file)) {
    cat(line, "\n", file = log_file, append = TRUE)
  }
}

#' Log a step/message
#'
#' @param msg Message to log
#' @param log_file Log file path (from init_logger)
#' @export
log_step <- function(msg, log_file = NULL) {
  log_info(msg, log_file)
}
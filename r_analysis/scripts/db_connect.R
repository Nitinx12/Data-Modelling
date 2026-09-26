#' Connect to PostgreSQL warehouse
#'
#' Reads credentials from the project root `.env` file (the same file the
#' Python pipeline uses) and establishes a read only DBI connection to the
#' `core` warehouse schema. Existing process environment variables win over
#' `.env` values so CI secret injection keeps working.
#'
#' @return DBI connection object to the warehouse database
#' @export
connect_db <- function() {
  load_dotenv()

  dbname <- Sys.getenv("POSTGRES_DATABASE")
  host <- Sys.getenv("POSTGRES_HOST", "localhost")
  port <- suppressWarnings(as.integer(Sys.getenv("POSTGRES_PORT", "5432")))
  user <- Sys.getenv("POSTGRES_USERNAME")
  password <- Sys.getenv("POSTGRES_PASSWORD")
  sslmode <- Sys.getenv("POSTGRES_SSLMODE")

  if (dbname == "" || user == "") {
    stop(
      "Missing POSTGRES_DATABASE or POSTGRES_USERNAME. ",
      "Copy .env.example to .env and fill it in."
    )
  }
  if (is.na(port)) {
    stop("POSTGRES_PORT is not a valid integer: '", Sys.getenv("POSTGRES_PORT"), "'")
  }

  con_args <- list(
    drv = RPostgres::Postgres(),
    dbname = dbname,
    host = host,
    port = port,
    user = user,
    password = password
  )
  if (sslmode != "") {
    con_args$sslmode <- sslmode
  }

  do.call(DBI::dbConnect, con_args)
}

#' Close database connection
#'
#' Safely disconnects from the PostgreSQL warehouse. No-op for NULL input
#' so callers can use it unconditionally inside `on.exit()`.
#'
#' @param con DBI connection object (or NULL)
#' @return Invisible TRUE
#' @export
disconnect_db <- function(con) {
  if (!is.null(con) && DBI::dbIsValid(con)) {
    DBI::dbDisconnect(con)
  }
  invisible(TRUE)
}

#' Execute SQL query and return data frame
#'
#' Thin wrapper around `DBI::dbGetQuery()` for read only SELECT statements.
#' Keeps every warehouse read in one place so result handling stays uniform.
#' BIGINT columns arrive as `integer64`; they are coerced to numeric so
#' downstream math, CSV output, and ggplot scales all behave.
#'
#' @param con DBI connection object
#' @param sql Single SELECT statement string
#' @return data.frame with the query result
#' @export
query_db <- function(con, sql) {
  fix_int64(DBI::dbGetQuery(con, sql))
}

#' Alias of `query_db()` for scripts that already define a local `q`
#'
#' @param con DBI connection object
#' @param sql Single SELECT statement string
#' @return data.frame with the query result
#' @export
qdf <- function(con, sql) {
  query_db(con, sql)
}

#' Coerce integer64 columns to numeric
#'
#' RPostgres maps PostgreSQL BIGINT to `bit64::integer64`, which ggplot
#' cannot scale and `write.csv` cannot format reliably. This converts every
#' such column in place. All warehouse counts fit in a double exactly.
#'
#' @param df data.frame returned from the warehouse
#' @return The same data.frame with integer64 columns as numeric
#' @export
fix_int64 <- function(df) {
  for (col in names(df)) {
    if (inherits(df[[col]], "integer64")) {
      df[[col]] <- as.numeric(df[[col]])
    }
  }
  df
}

#' Locate the project root directory
#'
#' Walks up from the working directory until a directory containing `.env`,
#' `r_analysis/`, or `.git` is found. Lets helpers work no matter whether R
#' was launched from the repo root, `r_analysis/`, or `r_analysis/scripts/`.
#'
#' @return Absolute path to the project root
#' @keywords internal
find_project_root <- function() {
  dir <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)
  repeat {
    markers <- file.path(dir, c(".env", "r_analysis", ".git"))
    if (any(file.exists(markers))) {
      return(dir)
    }
    parent <- dirname(dir)
    if (identical(parent, dir)) {
      # Fell off the filesystem root: fall back to the working directory.
      return(normalizePath(getwd(), winslash = "/", mustWork = TRUE))
    }
    dir <- parent
  }
}

#' Load `.env` values into the process environment
#'
#' Parses `KEY=VALUE` lines, strips surrounding quotes, skips comments and
#' blank lines, and honours an optional leading `export `. Variables already
#' present in the environment are left untouched.
#'
#' @param env_file Path to the dotenv file. Defaults to `.env` at the
#'   project root.
#' @return Invisible character vector of keys that were set
#' @keywords internal
load_dotenv <- function(env_file = file.path(find_project_root(), ".env")) {
  if (!file.exists(env_file)) {
    return(invisible(character(0)))
  }

  lines <- readLines(env_file, warn = FALSE)
  # Drop carriage returns so CRLF checkouts parse identically on Linux.
  lines <- gsub("\r$", "", lines)
  loaded <- character(0)

  for (line in lines) {
    line <- trimws(line)
    if (line == "" || startsWith(line, "#")) {
      next
    }
    if (startsWith(line, "export ")) {
      line <- trimws(substring(line, nchar("export ") + 1L))
    }
    eq <- regexpr("=", line, fixed = TRUE)
    if (eq < 1L) {
      next
    }
    key <- trimws(substr(line, 1L, eq - 1L))
    value <- trimws(substr(line, eq + 1L, nchar(line)))
    if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", key)) {
      next
    }
    # Strip one layer of matching single or double quotes.
    if (nchar(value) >= 2L) {
      first <- substr(value, 1L, 1L)
      last <- substr(value, nchar(value), nchar(value))
      if ((first == "\"" && last == "\"") || (first == "'" && last == "'")) {
        value <- substr(value, 2L, nchar(value) - 1L)
      }
    }
    if (Sys.getenv(key) == "") {
      do.call(Sys.setenv, stats::setNames(list(value), key))
      loaded <- c(loaded, key)
    }
  }

  invisible(loaded)
}

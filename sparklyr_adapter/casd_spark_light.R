CASD_REGISTRY_PATH <- "Software\\CASD\\Hadoop"
CASD_TOKEN_SCRIPT_NAME <- "refresh-tokens.ps1"
CASD_TOKEN_PREFIX <- "hadoop-r-"
CASD_TOKEN_EXT    <- ".dt"
CASD_DEFAULT_TIMEOUT <- 60L
CASD_DEFAULT_MASTER   <- "yarn"
CASD_DEFAULT_APP_NAME <- "rstudio"
CASD_DEFAULT_DRIVER_PORT <- 7077L
CASD_BLOCK_MANAGER_OFFSET <- 200L

CASD_DISABLED_CREDENTIALS <- c(
  "spark.security.credentials.hadoopfs.enabled",
  "spark.security.credentials.hive.enabled",
  "spark.security.credentials.hbase.enabled"
)

.casd_state <- new.env(parent = emptyenv())
.casd_state$tokens <- new.env(parent = emptyenv())
.casd_state$last_token <- NULL
.casd_state$has_original_token_env <- FALSE
.casd_state$original_token_env <- NULL

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

.casd_is_windows <- function() {
  .Platform$OS.type == "windows"
}

.casd_is_blank <- function(x) {
  if (is.null(x) || length(x) == 0L) return(TRUE)
  val <- tryCatch(as.character(x), error = function(e) NA_character_)
  val <- val[!is.na(val)]
  if (length(val) == 0L) return(TRUE)
  !any(nzchar(trimws(val)))
}

.casd_first_chr <- function(x) {
  if (is.null(x) || length(x) == 0L) return(NA_character_)
  val <- tryCatch(as.character(x[1L]), error = function(e) NA_character_)
  if (length(val) == 0L || is.na(val)) return(NA_character_)
  val <- trimws(val)
  val <- gsub('^"|"$', "", val)
  val <- trimws(val)
  if (!nzchar(val)) NA_character_ else val
}

.casd_normalize_path <- function(x) {
  if (is.character(x) && length(x) == 1L && !is.na(x) && nzchar(x)) {
    normalizePath(x, mustWork = FALSE)
  } else {
    x
  }
}

.casd_set_env_if_blank <- function(name, value) {
  if (is.character(value) && length(value) == 1L && !is.na(value) && nzchar(value) && !nzchar(Sys.getenv(name))) {
    envs <- list(value)
    names(envs) <- name
    do.call(Sys.setenv, envs)
  }
  invisible(Sys.getenv(name))
}

.casd_find_powershell <- function() {
  for (exe in c("powershell.exe", "pwsh.exe", "powershell", "pwsh")) {
    path <- unname(Sys.which(exe))
    if (nzchar(path)) return(path)
  }
  "powershell"
}

.casd_parse_port <- function(x) {
  if (is.null(x) || length(x) == 0L) return(NULL)
  p <- if (is.numeric(x)) {
    suppressWarnings(as.integer(x[1L]))
  } else {
    suppressWarnings(as.integer(as.character(x[1L])))
  }
  if (length(p) == 0L || is.na(p)) return(NULL)
  if (p < 1L || p > 65135L) return(NULL)
  p
}

get_casd_conf <- function() {
  if (!.casd_is_windows()) {
    stop("OS Error: This helper is designed exclusively for Windows environments.", call. = FALSE)
  }

  conf <- tryCatch({
    utils::readRegistry(CASD_REGISTRY_PATH, hive = "HCU")
  }, error = function(e) NULL)

  if (is.null(conf)) {
    stop(sprintf("Configuration Error: Missing registry key 'HKCU\\%s'.\nPlease run 'install-tokens.ps1'.", CASD_REGISTRY_PATH), call. = FALSE)
  }

  tools_path <- .casd_first_chr(conf$ToolsPath)
  if (is.na(tools_path)) {
    stop(sprintf("Configuration Error: Missing 'ToolsPath' value in 'HKCU\\%s'.", CASD_REGISTRY_PATH), call. = FALSE)
  }

  list(
    ToolsPath  = .casd_normalize_path(tools_path),
    SparkHome  = .casd_normalize_path(.casd_first_chr(conf$SparkHome)),
    HadoopConf = .casd_normalize_path(.casd_first_chr(conf$HadoopConf)),
    DriverPort = .casd_first_chr(conf$DriverPort)
  )
}

generate_casd_token <- function(timeout = CASD_DEFAULT_TIMEOUT) {
  cf <- get_casd_conf()
  ps_script <- normalizePath(file.path(cf$ToolsPath, CASD_TOKEN_SCRIPT_NAME), mustWork = FALSE)

  if (!file.exists(ps_script)) {
    stop(sprintf("File Error: '%s' not found in '%s'.", CASD_TOKEN_SCRIPT_NAME, cf$ToolsPath), call. = FALSE)
  }

  dt_path <- normalizePath(tempfile(pattern = CASD_TOKEN_PREFIX, fileext = CASD_TOKEN_EXT), mustWork = FALSE)
  success <- FALSE

  on.exit({
    if (!success) {
      crc_path <- file.path(dirname(dt_path), paste0(".", basename(dt_path), ".crc"))
      suppressWarnings(file.remove(c(dt_path, crc_path)))
    }
  }, add = TRUE)

  ps_args <- c("-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", shQuote(ps_script), "-Out", shQuote(dt_path), "-Quiet")

  timeout <- suppressWarnings(as.integer(timeout))
  if (length(timeout) == 0L || is.na(timeout) || timeout < 0L) {
    timeout <- CASD_DEFAULT_TIMEOUT
  }

  exe <- .casd_find_powershell()
  sys_args <- list(command = exe, args = ps_args, stdout = TRUE, stderr = TRUE)

  if ("timeout" %in% names(formals(system2))) sys_args$timeout <- timeout

  out <- tryCatch(
    suppressWarnings(do.call(system2, sys_args)),
    error = function(e) structure(character(), status = -1L, error_message = conditionMessage(e))
  )

  status <- attr(out, "status", exact = TRUE)
  if (is.null(status)) status <- 0L
  size <- if (file.exists(dt_path)) file.info(dt_path)$size else NA_integer_

  if (status != 0L || !isTRUE(size > 0L)) {
    err_msg <- attr(out, "error_message", exact = TRUE)
    if (!is.null(err_msg)) out <- c(out, err_msg)
    if (length(out) == 0L) out <- "(no output)"
    if (length(out) > 30L) out <- c(utils::head(out, 15L), "...", utils::tail(out, 15L))
    stop("Token generation failed.\nCommand: ", exe, " ", paste(ps_args, collapse = " "), "\nOutput:\n", paste(out, collapse = "\n"), call. = FALSE)
  }

  if (!isTRUE(.casd_state$has_original_token_env)) {
    old_env <- Sys.getenv("HADOOP_TOKEN_FILE_LOCATION")
    .casd_state$original_token_env <- if (nzchar(old_env)) old_env else NA_character_
    .casd_state$has_original_token_env <- TRUE
  }

  Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = dt_path)
  token_id <- basename(dt_path)
  .casd_state$tokens[[token_id]] <- dt_path
  .casd_state$last_token <- dt_path
  success <- TRUE
  message(sprintf("[OK] Spark YARN token generated: %s", dt_path))
  invisible(dt_path)
}

.casd_cleanup_token <- function(token_path = NULL) {
  if (is.null(token_path)) token_path <- .casd_state$last_token
  if (is.null(token_path) || !is.character(token_path) || length(token_path) != 1L || is.na(token_path) || !nzchar(token_path)) return(invisible(FALSE))

  token_path <- normalizePath(token_path, mustWork = FALSE)
  crc_path <- file.path(dirname(token_path), paste0(".", basename(token_path), ".crc"))
  suppressWarnings(file.remove(c(token_path, crc_path)))

  if (is.environment(.casd_state$tokens)) {
    for (key in ls(.casd_state$tokens)) {
      if (identical(.casd_state$tokens[[key]], token_path)) rm(list = key, envir = .casd_state$tokens)
    }
  }

  if (identical(.casd_state$last_token, token_path)) .casd_state$last_token <- NULL

  current_env <- Sys.getenv("HADOOP_TOKEN_FILE_LOCATION")
  if (nzchar(current_env)) current_env <- tryCatch(normalizePath(current_env, mustWork = FALSE), error = function(e) current_env)

  if (identical(current_env, token_path)) {
    remaining <- character(0)
    if (is.environment(.casd_state$tokens)) {
      remaining <- unlist(as.list(.casd_state$tokens), use.names = FALSE)
      remaining <- unique(remaining[is.character(remaining) & !is.na(remaining) & nzchar(remaining)])
    }

    if (length(remaining) > 0L) {
      new_env <- if (!is.null(.casd_state$last_token) && .casd_state$last_token %in% remaining) .casd_state$last_token else remaining[length(remaining)]
      Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = new_env)
    } else if (isTRUE(.casd_state$has_original_token_env)) {
      orig <- .casd_state$original_token_env
      if (is.character(orig) && length(orig) == 1L && !is.na(orig) && nzchar(orig)) Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = orig) else Sys.unsetenv("HADOOP_TOKEN_FILE_LOCATION")
      .casd_state$has_original_token_env <- FALSE
      .casd_state$original_token_env <- NULL
    } else {
      Sys.unsetenv("HADOOP_TOKEN_FILE_LOCATION")
    }
  }
  invisible(TRUE)
}


casd_spark_connect <- function(config = NULL,
                               master = "yarn",
                               app_name = "rstudio",
                               driver_port = NULL,
                               ...) {

  if (!requireNamespace("sparklyr", quietly = TRUE)) stop("Package Error: 'sparklyr' is required but not installed.", call. = FALSE)
  if (!is.character(master) || length(master) != 1L || is.na(master) || !nzchar(master)) stop("Configuration Error: `master` must be a non-empty string.", call. = FALSE)

  master <- trimws(master)
  cf <- get_casd_conf()

  .casd_set_env_if_blank("SPARK_HOME", cf$SparkHome)
  .casd_set_env_if_blank("HADOOP_CONF_DIR", cf$HadoopConf)

  cfg <- if (is.null(config)) sparklyr::spark_config() else config
  if (!is.list(cfg)) stop("Configuration Error: `config` must be NULL, a list, or sparklyr::spark_config().", call. = FALSE)

  # Disable built-in credentials since CASD handles token lifecycle via ps1
  for (cred in CASD_DISABLED_CREDENTIALS) cfg[[cred]] <- "false"

  user_input_port <- .casd_parse_port(driver_port)
  if (!.casd_is_blank(driver_port) && is.null(user_input_port)) stop("Configuration Error: `driver_port` must be an integer between 1 and 65535.", call. = FALSE)

  config_port   <- .casd_parse_port(cfg[["spark.driver.port"]])
  registry_port <- .casd_parse_port(cf$DriverPort)
  final_driver_port <- user_input_port %||% config_port %||% registry_port %||% CASD_DEFAULT_DRIVER_PORT

  if (!is.null(final_driver_port)) {
    cfg[["spark.driver.port"]] <- as.character(final_driver_port)

    if (is.null(cfg[["spark.driver.blockManager.port"]])) {
      bm_port <- final_driver_port + CASD_BLOCK_MANAGER_OFFSET

      if (bm_port <= 65535L) {
        cfg[["spark.driver.blockManager.port"]] <- as.character(bm_port)
      } else {
        warning("Port Warning: driver_port + offset exceeds 65535; leaving blockManager port unset.", call. = FALSE)
      }
    }
  }


  token_path <- NULL
  cleanup_on_error <- FALSE

  if (identical(tolower(master), "yarn")) {
    token_path <- generate_casd_token()
    cleanup_on_error <- TRUE
    on.exit(if (cleanup_on_error) .casd_cleanup_token(token_path), add = TRUE)
  }

  spark_home <- Sys.getenv("SPARK_HOME")
  if (!nzchar(spark_home)) spark_home <- NULL
  if (!is.null(spark_home) && !dir.exists(spark_home)) warning(sprintf("Configuration Warning: SPARK_HOME '%s' does not exist.", spark_home), call. = FALSE)

  hadoop_conf <- Sys.getenv("HADOOP_CONF_DIR")
  if (nzchar(hadoop_conf) && !dir.exists(hadoop_conf)) warning(sprintf("Configuration Warning: HADOOP_CONF_DIR '%s' does not exist.", hadoop_conf), call. = FALSE)

  message("[\u21BA] Connecting to Spark on ", master, "...")

  extra_args <- list(...)
  if (!"spark_home" %in% names(extra_args) && !is.null(spark_home)) extra_args$spark_home <- spark_home

  connect_args <- c(list(master = master, app_name = app_name, config = cfg), extra_args)
  sc <- do.call(sparklyr::spark_connect, connect_args)

  cleanup_on_error <- FALSE
  if (!is.null(token_path)) sc <- tryCatch(structure(sc, casd_token_path = token_path), error = function(e) sc)

  sc
}

casd_spark_disconnect <- function(sc = NULL) {
  token_path <- NULL
  if (!is.null(sc)) {
    token_path <- attr(sc, "casd_token_path", exact = TRUE)
    if (is.null(token_path) && is.environment(.casd_state$tokens) && length(ls(.casd_state$tokens)) == 1L) {
      token_path <- .casd_state$last_token
    }
  } else {
    token_path <- .casd_state$last_token
  }

  if (!is.null(sc)) {
    if (!requireNamespace("sparklyr", quietly = TRUE)) {
      warning("Package Error: 'sparklyr' is required to disconnect; only token cleanup will run.", call. = FALSE)
    } else {
      is_open <- tryCatch(sparklyr::spark_connection_is_open(sc), error = function(e) FALSE)
      if (isTRUE(is_open)) {
        tryCatch({
          sparklyr::spark_disconnect(sc)
          message("[OK] Spark disconnected successfully.")
        }, error = function(e) warning("Spark disconnection encountered an error: ", conditionMessage(e), call. = FALSE))
      } else {
        message("[INFO] Spark connection is already closed or invalid.")
      }
    }
  }

  .casd_cleanup_token(token_path)
  invisible(TRUE)
}

casd_cleanup_tokens <- function(all = TRUE) {
  if (isTRUE(all) && is.environment(.casd_state$tokens)) {
    paths <- unique(unlist(as.list(.casd_state$tokens), use.names = FALSE))
    for (p in paths) .casd_cleanup_token(p)
  } else {
    .casd_cleanup_token(.casd_state$last_token)
  }
  invisible(TRUE)
}

reg.finalizer(.casd_state, function(env) {
  tryCatch({
    toks <- if (is.environment(env$tokens)) as.list(env$tokens) else list()
    paths <- unlist(c(toks, list(env$last_token)), use.names = FALSE)
    if (length(paths) == 0L) return(invisible(NULL))
    paths <- unique(normalizePath(paths[is.character(paths) & !is.na(paths) & nzchar(paths)], mustWork = FALSE))
    for (p in paths) unlink(c(p, file.path(dirname(p), paste0(".", basename(p), ".crc"))), force = TRUE)

    current <- Sys.getenv("HADOOP_TOKEN_FILE_LOCATION")
    if (nzchar(current)) {
      current_norm <- tryCatch(normalizePath(current, mustWork = FALSE), error = function(e) current)
      if (current_norm %in% paths) {
        orig <- env$original_token_env
        if (is.character(orig) && length(orig) == 1L && !is.na(orig) && nzchar(orig)) Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = orig) else Sys.unsetenv("HADOOP_TOKEN_FILE_LOCATION")
      }
    }
    invisible(NULL)
  }, error = function(e) NULL)
}, onexit = TRUE)
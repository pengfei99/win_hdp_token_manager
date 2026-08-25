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

  # Try converting to character.
  val <- tryCatch(
    as.character(x),
    error = function(e) NA_character_
  )

  # Remove NA values.
  val <- val[!is.na(val)]

  # If nothing remains, it is blank.
  if (length(val) == 0L) return(TRUE)

  # If all remaining values are empty/whitespace-only, it is blank.
  !any(nzchar(trimws(val)))
}

.casd_first_chr <- function(x) {
  # If the input is missing or empty, return NA.
  if (is.null(x) || length(x) == 0L) return(NA_character_)

  # Try to convert the first element to character.
  val <- tryCatch(
    as.character(x[1L]),
    error = function(e) NA_character_
  )

  # If conversion failed or produced NA, return NA.
  if (length(val) == 0L || is.na(val)) return(NA_character_)

  # Remove surrounding whitespace.
  val <- trimws(val)

  # Remove accidental surrounding double quotes.
  #
  # Example:
  # "\"C:\\CASD\"" becomes "C:\CASD"
  val <- gsub('^"|"$', "", val)

  # Remove whitespace again after quote removal.
  val <- trimws(val)

  # If the result is empty, treat it as missing.
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
  # Only set the environment variable if:
  # - value is a non-missing string
  # - value is not empty
  # - current environment variable is blank/unset
  if (is.character(value) &&
      length(value) == 1L &&
      !is.na(value) &&
      nzchar(value) &&
      !nzchar(Sys.getenv(name))) {

    # R does not allow direct dynamic naming like:
    # Sys.setenv(name = value)
    #
    # So we build a named list and call Sys.setenv() with do.call().
    envs <- list(value)
    names(envs) <- name
    do.call(Sys.setenv, envs)
  }

  invisible(Sys.getenv(name))
}
.casd_find_powershell <- function() {
  for (exe in c("powershell.exe", "pwsh.exe", "powershell", "pwsh")) {
    path <- unname(Sys.which(exe))

    # Sys.which returns "" when the executable is not found.
    if (nzchar(path)) return(path)
  }

  "powershell"
}

.casd_parse_port <- function(x) {
  # Missing input.
  if (is.null(x) || length(x) == 0L) return(NULL)

  # Convert to integer.
  # suppressWarnings() is used because as.integer("abc") warns.
  p <- if (is.numeric(x)) {
    suppressWarnings(as.integer(x[1L]))
  } else {
    suppressWarnings(as.integer(as.character(x[1L])))
  }

  # If conversion failed, return NULL.
  if (length(p) == 0L || is.na(p)) return(NULL)

  # Ports must be between 1 and 65535-400.
  if (p < 1L || p > 65135L) return(NULL)

  p
}


get_casd_conf <- function() {
  # This helper is Windows-only because it uses readRegistry().
  if (!.casd_is_windows()) {
    stop(
      "OS Error: This helper is designed exclusively for Windows environments.",
      call. = FALSE
    )
  }

  # Read registry key.
  # If the key does not exist or cannot be read, return NULL.
  conf <- tryCatch({
    utils::readRegistry(CASD_REGISTRY_PATH, hive = "HCU")
  }, error = function(e) NULL)

  # If the registry key is missing, fail with installation guidance.
  if (is.null(conf)) {
    stop(
      sprintf("Configuration Error: Missing registry key 'HKCU\\%s'.\n", CASD_REGISTRY_PATH),
      "Please run 'install-tokens.ps1' before using this helper.",
      call. = FALSE
    )
  }

  # ToolsPath is required.
  tools_path <- .casd_first_chr(conf$ToolsPath)

  if (is.na(tools_path)) {
    stop(
      sprintf("Configuration Error: Missing 'ToolsPath' value in 'HKCU\\%s'.", CASD_REGISTRY_PATH),
      call. = FALSE
    )
  }

  # Return a normalized configuration list.
  #
  # Optional values may be NA_character_.
  list(
    ToolsPath  = .casd_normalize_path(tools_path),
    SparkHome  = .casd_normalize_path(.casd_first_chr(conf$SparkHome)),
    HadoopConf = .casd_normalize_path(.casd_first_chr(conf$HadoopConf)),
    DriverPort = .casd_first_chr(conf$DriverPort)
  )
}


generate_casd_token <- function() {
  # Load CASD configuration from registry.
  cf <- get_casd_conf()

  # build full path to the token generation script.
  ps_script <- normalizePath(file.path(cf$ToolsPath, CASD_TOKEN_SCRIPT_NAME), mustWork = FALSE)

  # the token generation script must exist
  if (!file.exists(ps_script)) {
    stop(sprintf("File Error: '%s' not found in '%s'.", CASD_TOKEN_SCRIPT_NAME, cf$ToolsPath), call. = FALSE)
  }

  # Temporary token file.
  #
  # tempfile() gives a unique filename, avoiding collisions between
  # multiple R sessions or repeated connections.
  dt_path <- normalizePath(
    tempfile(pattern = CASD_TOKEN_PREFIX, fileext = CASD_TOKEN_EXT),
    mustWork = FALSE
  )

  success <- FALSE

  on.exit({
    if (!success) {
      crc_path <- file.path(
        dirname(dt_path),
        paste0(".", basename(dt_path), ".crc")
      )

      suppressWarnings(file.remove(c(dt_path, crc_path)))
    }
  }, add = TRUE)

  ps_args <- c(
    "-NonInteractive",
    "-ExecutionPolicy", "Bypass",
    "-File", shQuote(ps_script),
    "-Out", shQuote(dt_path),
    "-Quiet"
  )

  # Normalize user input timeout. if user input is not valid, use CASD_DEFAULT_TIMEOUT
  # timeout = 0 means no timeout in system2().
  timeout <- suppressWarnings(as.integer(timeout))
  if (length(timeout) == 0L || is.na(timeout) || timeout < 0L) {
    timeout <- CASD_DEFAULT_TIMEOUT
  }

  # Find PowerShell executable.
  exe <- .casd_find_powershell()

  # Build system2() arguments.
  sys_args <- list(
    command = exe,
    args = ps_args,
    stdout = TRUE,
    stderr = TRUE
  )

  if ("timeout" %in% names(formals(system2))) {
    sys_args$timeout <- timeout
  }

  out <- tryCatch(
    suppressWarnings(do.call(system2, sys_args)),
    error = function(e) {
      # If system2 itself fails, create a fake output object.
      structure(
        character(),
        status = -1L,
        error_message = conditionMessage(e)
      )
    }
  )

  # system2() usually attaches a status attribute only when non-zero.
  status <- attr(out, "status", exact = TRUE)
  if (is.null(status)) status <- 0L

  # Check that the token file exists and has non-zero size.
  size <- if (file.exists(dt_path)) file.info(dt_path)$size else NA_integer_

  # If PowerShell failed or token file is missing/empty, stop.
  if (status != 0L || !isTRUE(size > 0L)) {

    # If system2 itself failed, append its error message.
    err_msg <- attr(out, "error_message", exact = TRUE)
    if (!is.null(err_msg)) out <- c(out, err_msg)

    # Make empty output easier to read in error messages.
    if (length(out) == 0L) {
      out <- "(no output)"
    }

    # Avoid flooding the console if PowerShell produced lots of output.
    if (length(out) > 30L) {
      out <- c(
        utils::head(out, 15L),
        "...",
        utils::tail(out, 15L)
      )
    }

    stop(
      "Token generation failed.\n",
      "Command: ", exe, " ", paste(ps_args, collapse = " "), "\n",
      "Output:\n", paste(out, collapse = "\n"),
      call. = FALSE
    )
  }

  if (!isTRUE(.casd_state$has_original_token_env)) {
    old_env <- Sys.getenv("HADOOP_TOKEN_FILE_LOCATION")

    .casd_state$original_token_env <- if (nzchar(old_env)) old_env else NA_character_
    .casd_state$has_original_token_env <- TRUE
  }

  # Hadoop/Spark client libraries read this environment variable to
  # locate delegation token credentials.
  Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = dt_path)

  # Track token in state.
  #
  # The key is the basename because environment object names should be
  # simple strings.
  token_id <- basename(dt_path)
  .casd_state$tokens[[token_id]] <- dt_path

  # track as the latest token.
  .casd_state$last_token <- dt_path

  # Mark generation as successful so on.exit() does not delete the file.
  success <- TRUE

  message(sprintf("[OK] Spark YARN token generated: %s", dt_path))

  invisible(dt_path)
}

.casd_cleanup_token <- function(token_path = NULL) {

  # Default to the last generated token.
  if (is.null(token_path)) {
    token_path <- .casd_state$last_token
  }

  # If there is no valid token path, do nothing.
  if (is.null(token_path) ||
      !is.character(token_path) ||
      length(token_path) != 1L ||
      is.na(token_path) ||
      !nzchar(token_path)) {
    return(invisible(FALSE))
  }

  # Normalize path so comparisons are stable.
  token_path <- normalizePath(token_path, mustWork = FALSE)

  # Hadoop often creates a CRC file next to credential files:
  #
  #   file.dt
  #   .file.dt.crc
  #
  # We try to delete both.
  crc_path <- file.path(
    dirname(token_path),
    paste0(".", basename(token_path), ".crc")
  )

  suppressWarnings(file.remove(c(token_path, crc_path)))

  # Remove this token from the tracked tokens environment.
  if (is.environment(.casd_state$tokens)) {
    for (key in ls(.casd_state$tokens)) {
      if (identical(.casd_state$tokens[[key]], token_path)) {
        rm(list = key, envir = .casd_state$tokens)
      }
    }
  }

  # If we removed the latest token, clear latest tracking fields.
  if (identical(.casd_state$last_token, token_path)) {
    .casd_state$last_token <- NULL
  }
  current_env <- Sys.getenv("HADOOP_TOKEN_FILE_LOCATION")

  if (nzchar(current_env)) {
    current_env <- tryCatch(
      normalizePath(current_env, mustWork = FALSE),
      error = function(e) current_env
    )
  }

  if (identical(current_env, token_path)) {

    # Collect remaining tracked token paths.
    remaining <- character(0)

    if (is.environment(.casd_state$tokens)) {
      remaining <- unlist(as.list(.casd_state$tokens), use.names = FALSE)

      # Keep only non-empty character paths.
      remaining <- remaining[
        is.character(remaining) &
        !is.na(remaining) &
        nzchar(remaining)
      ]

      remaining <- unique(remaining)
    }

    if (length(remaining) > 0L) {
      # If there are multiple tokens, prefer the current last_token.
      new_env <- if (!is.null(.casd_state$last_token) &&
                     .casd_state$last_token %in% remaining) {
        .casd_state$last_token
      } else {
        remaining[length(remaining)]
      }

      Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = new_env)

    } else if (isTRUE(.casd_state$has_original_token_env)) {
      orig <- .casd_state$original_token_env

      # Restore original if it was a non-empty string.
      if (is.character(orig) &&
          length(orig) == 1L &&
          !is.na(orig) &&
          nzchar(orig)) {
        Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = orig)
      } else {
        # Original was blank/unset.
        Sys.unsetenv("HADOOP_TOKEN_FILE_LOCATION")
      }

      # Clear saved original value.
      .casd_state$has_original_token_env <- FALSE
      .casd_state$original_token_env <- NULL

    } else {
      # No original value saved; simply unset.
      Sys.unsetenv("HADOOP_TOKEN_FILE_LOCATION")
    }
  }

  invisible(TRUE)
}


casd_spark_connect <- function(config = NULL,
                               master = "yarn",
                               app_name = "rstudio",
                               driver_port = NULL) {
 # Checks if the package is installed without attaching it to the global search path
  if (!requireNamespace("sparklyr", quietly = TRUE)) {
    stop("Package Error: 'sparklyr' is required but not installed.", call. = FALSE)
  }

 # Validate user input spark session master value.
  if (!is.character(master) ||
      length(master) != 1L ||
      is.na(master) ||
      !nzchar(master)) {
    stop(
      "Configuration Error: `master` must be a non-empty string.",
      call. = FALSE
    )
  }

  # Normalize master string.
  master <- trimws(master)

  # Read CASD registry configuration.
  cf <- get_casd_conf()

  .casd_set_env_if_blank("SPARK_HOME", cf$SparkHome)
  .casd_set_env_if_blank("HADOOP_CONF_DIR", cf$HadoopConf)

  cfg <- if (is.null(config)) sparklyr::spark_config() else config

  if (!is.list(cfg)) {
    stop(
      "Configuration Error: `config` must be NULL, a list, or sparklyr::spark_config().",
      call. = FALSE
    )
  }

  cfg$spark.security.credentials.hadoopfs.enabled <- "false"
  cfg$spark.security.credentials.hive.enabled     <- "false"
  cfg$spark.security.credentials.hbase.enabled    <- "false"

  user_input_port <- .casd_parse_port(driver_port)

  # If the user explicitly supplied a bad port, fail.
  if (!.casd_is_blank(driver_port) && is.null(user_input_port)) {
    stop(
      "Configuration Error: `driver_port` must be an integer between 1 and 65535.",
      call. = FALSE
    )
  }

  config_port   <- .casd_parse_port(cfg[["spark.driver.port"]])
  registry_port <- .casd_parse_port(cf$DriverPort)

  # the overwrite priority is function argument > user input spark config  > win registry > CASD_DEFAULT_DRIVER_PORT
  final_driver_port <- user_input_port %||% config_port %||% registry_port %||% CASD_DEFAULT_DRIVER_PORT

  if (!is.null(final_driver_port)) {
    # setup driver port
    cfg[["spark.driver.port"]] <- as.character(final_driver_port)

    if (.casd_is_blank(cfg[["spark.driver.blockManager.port"]])) {
      bm_port <- final_port + 200L

      # last check on blockManager port
      if (bm_port <= 65535L) {
        cfg[["spark.driver.blockManager.port"]] <- as.character(bm_port)
      } else {
        warning(
          "Port Warning: driver_port + 200 exceeds 65535; leaving blockManager port unset.",
          call. = FALSE
        )
      }
    }
  }


  token_path <- NULL
  cleanup_on_error <- FALSE

  if (identical(tolower(master), "yarn")) {
    token_path <- generate_casd_token()

    # If spark_connect() fails, this flag ensures we clean up the token.
    cleanup_on_error <- TRUE

    # on.exit() runs when this function exits.
    #
    # If connection succeeds, we set cleanup_on_error <- FALSE later.
    # If connection fails or user aborts, cleanup_on_error remains TRUE.
    on.exit(
      if (cleanup_on_error) .casd_cleanup_token(token_path),
      add = TRUE
    )
  }

  spark_home <- Sys.getenv("SPARK_HOME")
  if (!nzchar(spark_home)) spark_home <- NULL

  # Warn if SPARK_HOME points to a missing directory.
  if (!is.null(spark_home) && !dir.exists(spark_home)) {
    warning(
      sprintf("Configuration Warning: SPARK_HOME '%s' does not exist.", spark_home),
      call. = FALSE
    )
  }

  # Warn if HADOOP_CONF_DIR points to a missing directory.
  hadoop_conf <- Sys.getenv("HADOOP_CONF_DIR")
  if (nzchar(hadoop_conf) && !dir.exists(hadoop_conf)) {
    warning(
      sprintf("Configuration Warning: HADOOP_CONF_DIR '%s' does not exist.", hadoop_conf),
      call. = FALSE
    )
  }

  message("[\u21BA] Connecting to Spark on ", master, "...")

  # Capture extra arguments supplied by the user.
  extra_args <- list(...)

  # Add spark_home only if:
  # - we have a non-NULL spark_home
  # - user did not already pass spark_home in ...
  if (!"spark_home" %in% names(extra_args) && !is.null(spark_home)) {
    extra_args$spark_home <- spark_home
  }

  # Build final argument list for sparklyr::spark_connect().
  connect_args <- c(
    list(
      master = master,
      app_name = app_name,
      config = cfg
    ),
    extra_args
  )

  # Connect to Spark.
  sc <- do.call(sparklyr::spark_connect, connect_args)

  # Connection succeeded.
  # Do not remove token on normal function exit.
  cleanup_on_error <- FALSE

  if (!is.null(token_path)) {
    sc <- tryCatch(
      structure(sc, casd_token_path = token_path),
      error = function(e) sc
    )
  }

  sc
}


casd_spark_disconnect <- function(sc = NULL) {

  token_path <- NULL

  if (!is.null(sc)) {
    # Preferred case:
    # casd_spark_connect() attached the token path to sc.
    token_path <- attr(sc, "casd_token_path", exact = TRUE)

    if (is.null(token_path) &&
        is.environment(.casd_state$tokens) &&
        length(ls(.casd_state$tokens)) == 1L) {
      token_path <- .casd_state$last_token
    }
  } else {
    # If no connection object was supplied, clean the last token.
    token_path <- .casd_state$last_token
  }

  # Disconnect Spark if a connection object was supplied.
  if (!is.null(sc)) {

    if (!requireNamespace("sparklyr", quietly = TRUE)) {
      warning(
        "Package Error: 'sparklyr' is required to disconnect; only token cleanup will run.",
        call. = FALSE
      )
    } else {

      # Check whether the connection is still open.
      #
      # This is wrapped in tryCatch because sc may already be invalid,
      # closed, or not a real sparklyr connection object.
      is_open <- tryCatch(
        sparklyr::spark_connection_is_open(sc),
        error = function(e) FALSE
      )

      if (isTRUE(is_open)) {
        tryCatch(
          {
            sparklyr::spark_disconnect(sc)
            message("[OK] Spark disconnected successfully.")
          },
          error = function(e) {
            warning(
              "Spark disconnection encountered an error: ",
              conditionMessage(e),
              call. = FALSE
            )
          }
        )
      } else {
        message("[INFO] Spark connection is already closed or invalid.")
      }
    }
  }

  # Clean token file, CRC file, state, and environment variable.
  .casd_cleanup_token(token_path)

  invisible(TRUE)
}


casd_cleanup_tokens <- function(all = TRUE) {

  if (isTRUE(all) && is.environment(.casd_state$tokens)) {

    # Take a snapshot of tracked token paths.
    paths <- unique(unlist(as.list(.casd_state$tokens), use.names = FALSE))

    # Clean each tracked token.
    for (p in paths) {
      .casd_cleanup_token(p)
    }

  } else {
    # Clean only the latest token.
    .casd_cleanup_token(.casd_state$last_token)
  }

  invisible(TRUE)
}

reg.finalizer(
  .casd_state,
  function(env) {

    # Finalizers should be as defensive as possible.
    # We wrap everything in tryCatch so cleanup errors do not interrupt
    # R shutdown.
    tryCatch(
      {

        # Collect tracked token paths from state.
        toks <- if (is.environment(env$tokens)) as.list(env$tokens) else list()

        # Include latest token fields too, just in case.
        paths <- unlist(
          c(toks, list(env$last_token)),
          use.names = FALSE
        )

        # Nothing to clean.
        if (length(paths) == 0L) return(invisible(NULL))

        # Keep only valid non-empty character paths.
        paths <- paths[
          is.character(paths) &
          !is.na(paths) &
          nzchar(paths)
        ]

        if (length(paths) == 0L) return(invisible(NULL))

        # Normalize paths.
        paths <- unique(normalizePath(paths, mustWork = FALSE))

        # Delete each token file and its CRC file.
        for (p in paths) {
          crc <- file.path(
            dirname(p),
            paste0(".", basename(p), ".crc")
          )

          unlink(c(p, crc), force = TRUE)
        }

        # If HADOOP_TOKEN_FILE_LOCATION points to one of the deleted
        # token files, restore original value or unset it.
        current <- Sys.getenv("HADOOP_TOKEN_FILE_LOCATION")

        if (nzchar(current)) {
          current_norm <- tryCatch(
            normalizePath(current, mustWork = FALSE),
            error = function(e) current
          )

          if (current_norm %in% paths) {
            orig <- env$original_token_env

            if (is.character(orig) &&
                length(orig) == 1L &&
                !is.na(orig) &&
                nzchar(orig)) {
              Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = orig)
            } else {
              Sys.unsetenv("HADOOP_TOKEN_FILE_LOCATION")
            }
          }
        }

        invisible(NULL)
      },
      error = function(e) NULL
    )
  },
  onexit = TRUE
)
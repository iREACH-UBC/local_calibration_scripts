# QAQ_apply_general_calibration.R
#
# Callable QAQ calibration runner (NO downsampling; assumes files are already 15-min binned).
#
# INPUT (default):
#   ../apply_calibrations/apply_calibrations_joined_downsampled_data/<sensor_id>/*.csv
#   (each CSV should already be downsampled and contain DATE, CO, NO, NO2, O3, CO2, T, RH, PM2.5)
#
# OUTPUT (default):
#   ../apply_calibrations/apply_calibrations_calibrated_data/<sensor_id>/<input_basename>_pred.csv
#
# Timezone:
# - Stored DATE strings are UTC but not timezone-aware.
# - We therefore parse DATE as UTC explicitly (tz_in="UTC").
# - Output DATE defaults to UTC (tz_out="UTC"). Override if you want local display.
#
# Model selection:
# - If generalized_model = TRUE (default): use generalized calibration object for all sensors (currently set to 2032, change in line 51)
# - Else: use each sensor's own calibration object (<sensor_id>/Calibration_Models.obj)
# - You can still force a single explicit model_path for all sensors by passing model_path=...

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(lubridate)
  library(tibble)
  library(fs)
  library(purrr)
  library(stringr)
  library(gtools)
})

# ---- defaults (relative to the working directory) ----------------------------
default_in_root    <- file.path("..", "apply_calibrations", "apply_calibrations_joined_downsampled_data")
default_out_root   <- file.path("..", "apply_calibrations", "apply_calibrations_calibrated_data")
default_models_root <- file.path("..", "calibration_models")  # adjust as needed

# ---- CAPS core loader --------------------------------------------------------
.ensure_caps_loaded <- function(caps_core_path = "caps_core.R") {
  if (!exists("CAPS_Hybrid_Apply", mode = "function")) {
    if (!file_exists(caps_core_path)) stop("caps_core.R not found at: ", caps_core_path)
    source(caps_core_path)
  }
  invisible(TRUE)
}

# ---- resolve model path (generalized vs per-sensor) --------------------------
.resolve_model_path <- function(sensor_id,
                                generalized_model,
                                models_root,
                                generalized_id = "2032",
                                model_filename = "Calibration_Models.obj",
                                model_path = NULL) {
  # Highest priority: explicit model_path (forces one model for all sensors)
  if (!is.null(model_path) && nzchar(model_path)) return(model_path)
  
  if (is.null(models_root) || !nzchar(models_root)) {
    stop("Provide either model_path=... OR models_root=... (folder containing <sensor_id>/Calibration_Models.obj).")
  }
  
  use_id <- if (isTRUE(generalized_model)) generalized_id else sensor_id
  file.path(models_root, use_id, model_filename)
}

# ---- load calibration_models safely + cache by path --------------------------
.load_calibration_models_cached <- local({
  cache <- new.env(parent = emptyenv())  # model_path -> calibration_models
  function(model_path) {
    mp <- normalizePath(model_path, winslash = "/", mustWork = FALSE)
    if (exists(mp, envir = cache, inherits = FALSE)) {
      return(get(mp, envir = cache, inherits = FALSE))
    }
    if (!file.exists(mp)) stop("QAQ calibration model not found at: ", mp)
    
    e <- new.env(parent = emptyenv())
    load(mp, envir = e)
    if (!exists("calibration_models", envir = e, inherits = FALSE)) {
      stop("Model file did not create `calibration_models`: ", mp)
    }
    assign(mp, e$calibration_models, envir = cache)
    e$calibration_models
  }
})

# ---- read one already-downsampled QAQ file ----------------------------------
.read_one_qaq_ds <- function(path, tz_in = "UTC") {
  df <- suppressMessages(readr::read_csv(path, show_col_types = FALSE))
  
  need <- c("DATE", "CO", "NO", "NO2", "O3", "CO2", "T", "RH", "PM2.5")
  miss <- setdiff(need, names(df))
  if (length(miss) > 0) {
    warning("Skipping (missing): ", basename(path), " ??? ", paste(miss, collapse = ", "))
    return(NULL)
  }
  
  out <- df %>%
    transmute(
      # DATE is a plain string (not tz-aware). Interpret explicitly as UTC (or tz_in).
      date   = mdy_hm(.data$DATE, tz = tz_in, quiet = TRUE),
      CO     = suppressWarnings(parse_number(as.character(.data$CO))),
      NO     = suppressWarnings(parse_number(as.character(.data$NO))),
      NO2    = suppressWarnings(parse_number(as.character(.data$NO2))),
      O3     = suppressWarnings(parse_number(as.character(.data$O3))),
      CO2    = suppressWarnings(parse_number(as.character(.data$CO2))),
      T      = suppressWarnings(parse_number(as.character(.data$T))),
      RH     = suppressWarnings(parse_number(as.character(.data$RH))),
      `PM2.5`= suppressWarnings(parse_number(as.character(.data$`PM2.5`)))
    ) %>%
    filter(!is.na(date)) %>%
    arrange(date) %>%
    distinct(date, .keep_all = TRUE)
  
  if (!nrow(out)) return(NULL)
  out
}

# ---- to drop any negative values --------------------------------------------
.drop_negative_rows <- function(df, cols, verbose = TRUE) {
  cols <- intersect(cols, names(df))
  if (!length(cols)) return(df)
  
  neg_mask <- Reduce(
    `|`,
    lapply(cols, function(c) !is.na(df[[c]]) & df[[c]] < 0),
    init = FALSE
  )
  
  n_neg <- if (is.logical(neg_mask)) sum(neg_mask) else 0L
  
  if (n_neg > 0 && isTRUE(verbose)) {
    message("negative values detected and dropped")
  }
  
  if (n_neg > 0) df[!neg_mask, , drop = FALSE] else df
}

# ---- apply QAQ gas calibration ----------------------------------------------
.apply_qaq_gas_calibration <- function(df, calibration_models) {
  df_clean <- df %>% select(date, CO, NO, NO2, O3, CO2, T, RH, `PM2.5`)
  
  gas_mat <- df_clean %>%
    select(CO, NO, NO2, O3, CO2, T, RH) %>%
    as.matrix()
  colnames(gas_mat) <- paste0("input", seq_len(ncol(gas_mat)))
  
  pred_gas <- tibble(
    date = df_clean$date,
    NO2  = as.numeric(CAPS_Hybrid_Apply(calibration_models$gas$Hybrid$NO2, gas_mat)),
    NO   = as.numeric(CAPS_Hybrid_Apply(calibration_models$gas$Hybrid$NO,  gas_mat)),
    CO2  = as.numeric(CAPS_Hybrid_Apply(calibration_models$gas$Hybrid$CO2, gas_mat)),
    O3   = as.numeric(CAPS_Hybrid_Apply(calibration_models$gas$Hybrid$O3,  gas_mat)),
    CO   = as.numeric(CAPS_Hybrid_Apply(calibration_models$gas$Hybrid$CO,  gas_mat))
  )
  
  # Keep PM2.5 as-is
  pred_gas %>%
    left_join(
      df_clean %>% select(date, `PM2.5`) %>% rename(PM2_5 = `PM2.5`),
      by = "date"
    )
}

# ---- public callable ---------------------------------------------------------
qaq_apply_general_calibration <- function(sensor_ids,
                                          # model selection:
                                          generalized_model = TRUE,
                                          models_root       = default_models_root,
                                          generalized_id    = "MOD-00617",
                                          model_filename    = "Calibration_Models.obj",
                                          model_path        = NULL,  # optional override for all sensors
                                          # other settings:
                                          caps_core_path    = "caps_core.R",
                                          in_root           = default_in_root,
                                          out_root          = default_out_root,
                                          tz_in             = "UTC",
                                          tz_out            = "UTC",
                                          overwrite         = TRUE,
                                          verbose           = TRUE) {
  sensor_ids <- as.character(sensor_ids)
  
  .ensure_caps_loaded(caps_core_path)
  
  in_root  <- normalizePath(in_root, winslash = "/", mustWork = FALSE)
  out_root <- normalizePath(out_root, winslash = "/", mustWork = FALSE)
  dir_create(out_root)
  
  results <- list()
  
  for (id in sensor_ids) {
    if (verbose) {
      message("\n????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????")
      message("Calibrating QAQ sensor: ", id)
    }
    
    sensor_dir <- file.path(in_root, id)
    if (!dir_exists(sensor_dir)) {
      warning("Sensor dir does not exist for ", id, ": ", sensor_dir)
      next
    }
    
    files <- dir_ls(sensor_dir, type = "file", glob = "*.csv")
    if (!length(files)) {
      warning("No CSV files found for ", id, " in ", sensor_dir)
      next
    }
    
    # Choose model path based on generalized_model flag (or forced model_path)
    this_model_path <- .resolve_model_path(
      sensor_id         = id,
      generalized_model = generalized_model,
      models_root       = models_root,
      generalized_id    = generalized_id,
      model_filename    = model_filename,
      model_path        = model_path
    )
    
    if (verbose) message("??? Using model: ", this_model_path)
    
    # Cached load (loads once per unique path)
    calibration_models <- .load_calibration_models_cached(this_model_path)
    
    out_dir <- file.path(out_root, id)
    dir_create(out_dir)
    
    for (f in files) {
      base <- path_ext_remove(path_file(f))
      out_file <- file.path(out_dir, paste0(base, "_pred.csv"))
      
      if (file_exists(out_file) && !overwrite) {
        if (verbose) message("Exists (skipped): ", out_file)
        next
      }
      
      if (verbose) message("??? Reading: ", path_file(f))
      df <- .read_one_qaq_ds(f, tz_in = tz_in)
      if (is.null(df) || !nrow(df)) {
        if (verbose) message("  (no usable rows)")
        next
      }
      
      if (verbose) message("??? Applying QAQ gas calibration ???")
      pred <- .apply_qaq_gas_calibration(df, calibration_models)
      
      pred_out <- pred %>%
        mutate(DATE = format(with_tz(date, tz_out), "%m/%d/%Y %H:%M")) %>%
        select(DATE, CO, NO, NO2, O3, CO2, PM2_5)
      
      # Drop any rows where any pollutant is negative
      pred_out <- .drop_negative_rows(pred_out, cols = c("CO", "NO", "NO2", "O3", "CO2", "PM2_5"), verbose = verbose)
      
      if (!nrow(pred_out)) {
        warning("All rows dropped after negative-value filtering for: ", id, " / ", path_file(f))
        next
      }
      
      write_csv(pred_out, out_file, na = "")
      if (verbose) message("Wrote: ", out_file)
      
      results[[length(results) + 1]] <- list(
        sensor_id         = id,
        in_file           = f,
        out_file          = out_file,
        rows              = nrow(pred_out),
        model_path        = this_model_path,
        generalized_model = generalized_model,
        tz_in             = tz_in,
        tz_out            = tz_out
      )
    }
  }
  
  invisible(results)
}

# ---- optional CLI ------------------------------------------------------------
# Examples:
#   (1) generalized model (MOD-00617):
#     Rscript QAQ_apply_general_calibration.R \
#       --sensors MOD-00619,MOD-00623 \
#       --models-root C:/.../RAMP_Calibration_Models \
#       --generalized TRUE --generalized-id MOD-00617
#
#   (2) per-sensor models:
#     Rscript QAQ_apply_general_calibration.R \
#       --sensors MOD-00619,MOD-00623 \
#       --models-root C:/.../RAMP_Calibration_Models \
#       --generalized FALSE
#
#   (3) force a single explicit model for all sensors:
#     Rscript QAQ_apply_general_calibration.R \
#       --sensors MOD-00619,MOD-00623 \
#       --model C:/.../MOD-00617/Calibration_Models.obj
.parse_args <- function(args) {
  get_flag <- function(flag, default = NULL) {
    i <- match(flag, args)
    if (!is.na(i) && i < length(args)) return(args[[i + 1]])
    default
  }
  
  sensors_raw <- get_flag("--sensors", NA_character_)
  if (is.na(sensors_raw)) stop("Missing --sensors (comma-separated), e.g. --sensors MOD-00619,MOD-00623")
  
  generalized_raw <- get_flag("--generalized", "TRUE")
  generalized_val <- tolower(generalized_raw) %in% c("true", "t", "1", "yes", "y")
  
  list(
    sensors        = strsplit(sensors_raw, ",", fixed = TRUE)[[1]] |> str_trim() |> (\(x) x[nzchar(x)])(),
    model          = get_flag("--model", NULL),
    models_root    = get_flag("--models-root", default_models_root),
    generalized    = generalized_val,
    generalized_id = get_flag("--generalized-id", "MOD-00617"),
    model_filename = get_flag("--model-filename", "Calibration_Models.obj"),
    caps           = get_flag("--caps",  "caps_core.R"),
    in_root        = get_flag("--in-root",  default_in_root),
    out_root       = get_flag("--out-root", default_out_root),
    tz_in          = get_flag("--tz-in",  "UTC"),
    tz_out         = get_flag("--tz-out", "UTC"),
    overwrite      = !("--no-overwrite" %in% args),
    verbose        = !("--quiet" %in% args)
  )
}

if (identical(environmentName(environment()), "R_GlobalEnv") && !interactive() && !isTRUE(getOption("pipeline.sourced"))) {
  a <- .parse_args(commandArgs(trailingOnly = TRUE))
  
  # If --model not provided, we require --models-root to exist (folder; file is checked later)
  if (is.null(a$model) && (is.null(a$models_root) || !nzchar(a$models_root))) {
    stop("Provide --model <path> OR --models-root <folder containing <sensor_id>/Calibration_Models.obj>.")
  }
  
  qaq_apply_general_calibration(
    sensor_ids        = a$sensors,
    generalized_model = a$generalized,
    models_root       = a$models_root,
    generalized_id    = a$generalized_id,
    model_filename    = a$model_filename,
    model_path        = a$model,
    caps_core_path    = a$caps,
    in_root           = a$in_root,
    out_root          = a$out_root,
    tz_in             = a$tz_in,
    tz_out            = a$tz_out,
    overwrite         = a$overwrite,
    verbose           = a$verbose
  )
}

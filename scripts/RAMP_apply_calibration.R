#!/usr/bin/env Rscript
# RAMP_apply_calibration.R
#
# Callable RAMP calibration runner (NO downsampling; assumes files are already 15-min binned).
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
# - We parse DATE as tz_in explicitly (default tz_in="UTC").
# - Output DATE formatted in tz_out (default tz_out="UTC").
#
# Model selection:
# - Gas models (CO/NO/NO2/O3/CO2):
#     Priority:
#       1) model_path (explicit; file OR folder) -> used for all sensors
#       2) generalized_model=TRUE -> models_root/<generalized_id>/<model_filename>
#       3) generalized_model=FALSE -> models_root/<sensor_id>/<model_filename>
#
# - PM2.5 model:
#     Toggle whether to use generalized PM via pm_use_generalized.
#     Priority:
#       1) pm_model_path (explicit; file OR folder) -> used for all sensors
#       2) pm_use_generalized=TRUE -> models_root/<pm_generalized_id>/<model_filename>  (default)
#       3) pm_use_generalized=FALSE ->
#            - if model_path is set: use model_path for PM as well
#            - else: use the same ID-selection as gases under models_root
#
# Negative handling:
# - drop_negative_values = TRUE (default): drops any row where a predicted pollutant is negative.
# - drop_negative_values = FALSE: keeps negative values in output.
#
# Notes:
# - "model_path" and "pm_model_path" may be either:
#     (a) a full file path to Calibration_Models.obj, OR
#     (b) a folder path containing Calibration_Models.obj

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(lubridate)
  library(tibble)
  library(fs)
  library(purrr)
  library(stringr)
  library(gtools)
  library(randomForest)  # often needed by loaded model objects
})

# ---- defaults (relative to the working directory) ----------------------------
default_in_root     <- file.path("..", "apply_calibrations", "apply_calibrations_joined_downsampled_data")
default_out_root    <- file.path("..", "apply_calibrations", "apply_calibrations_calibrated_data")
default_models_root <- file.path("..", "calibration_models")  # folder containing <id>/Calibration_Models.obj

# ---- CAPS core loader --------------------------------------------------------
.ensure_caps_loaded <- function(caps_core_path = "caps_core.R") {
  if (!exists("CAPS_Hybrid_Apply", mode = "function") ||
      !exists("CAPS_PR_Apply", mode = "function")) {
    if (!file_exists(caps_core_path)) stop("caps_core.R not found at: ", caps_core_path)
    source(caps_core_path)
  }
  invisible(TRUE)
}

# ---- helper: accept file OR folder and return model file path ----------------
.as_model_file <- function(path, model_filename = "Calibration_Models.obj") {
  if (is.null(path) || !nzchar(path)) return(NULL)
  if (dir.exists(path)) return(file.path(path, model_filename))
  path
}

# ---- resolve model path (gas) ------------------------------------------------
.resolve_gas_model_path <- function(sensor_id,
                                    generalized_model,
                                    models_root,
                                    generalized_id = "2032",
                                    model_filename = "Calibration_Models.obj",
                                    model_path = NULL) {
  
  # explicit override: file OR folder
  mp <- .as_model_file(model_path, model_filename)
  if (!is.null(mp) && nzchar(mp)) return(mp)
  
  if (is.null(models_root) || !nzchar(models_root)) {
    stop("Provide either model_path=... OR models_root=... (folder containing <sensor_id>/Calibration_Models.obj).")
  }
  
  # robustness: if someone passed a file path as models_root, accept it as an explicit model file
  if (file.exists(models_root) && !dir.exists(models_root)) {
    return(models_root)
  }
  
  use_id <- if (isTRUE(generalized_model)) generalized_id else sensor_id
  file.path(models_root, use_id, model_filename)
}

# ---- resolve model path (PM) -------------------------------------------------
.resolve_pm_model_path <- function(sensor_id,
                                   pm_use_generalized = TRUE,
                                   generalized_model,
                                   models_root,
                                   generalized_id = "2032",
                                   pm_generalized_id = "2032",
                                   model_filename = "Calibration_Models.obj",
                                   model_path = NULL,
                                   pm_model_path = NULL) {
  
  # explicit PM override: file OR folder
  pp <- .as_model_file(pm_model_path, model_filename)
  if (!is.null(pp) && nzchar(pp)) return(pp)
  
  # If pm_use_generalized, use pm_generalized_id under models_root (unless models_root is itself a file)
  if (isTRUE(pm_use_generalized)) {
    if (is.null(models_root) || !nzchar(models_root)) {
      stop("pm_use_generalized=TRUE requires models_root=... (folder containing <pm_generalized_id>/Calibration_Models.obj) or pm_model_path=...")
    }
    if (file.exists(models_root) && !dir.exists(models_root)) {
      return(models_root)
    }
    return(file.path(models_root, pm_generalized_id, model_filename))
  }
  
  # pm_use_generalized=FALSE:
  # If a gas model_path was explicitly provided, default PM to that same model unless pm_model_path overrides it.
  mp <- .as_model_file(model_path, model_filename)
  if (!is.null(mp) && nzchar(mp)) return(mp)
  
  # Otherwise select PM model using the same ID-selection logic as gases under models_root
  if (is.null(models_root) || !nzchar(models_root)) {
    stop("pm_use_generalized=FALSE requires model_path=... OR models_root=... (folder containing <id>/Calibration_Models.obj).")
  }
  if (file.exists(models_root) && !dir.exists(models_root)) {
    return(models_root)
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
    if (!file.exists(mp)) stop("Calibration model not found at: ", mp)
    
    e <- new.env(parent = emptyenv())
    load(mp, envir = e)
    
    if (!exists("calibration_models", envir = e, inherits = FALSE)) {
      stop("Model file did not create `calibration_models`: ", mp)
    }
    
    assign(mp, e$calibration_models, envir = cache)
    e$calibration_models
  }
})

# ---- model structure assertions ----------------------------------------------
.assert_gas_models <- function(gas_models, model_path_for_msg = "<unknown>") {
  need <- c("NO2", "NO", "CO2", "O3", "CO")
  if (is.null(gas_models$gas$Hybrid)) {
    stop("Gas model object does not contain gas$Hybrid as expected.\nModel path: ", model_path_for_msg)
  }
  miss <- setdiff(need, names(gas_models$gas$Hybrid))
  if (length(miss) > 0) {
    stop("Gas model missing Hybrid entries: ", paste(miss, collapse = ", "),
         "\nModel path: ", model_path_for_msg)
  }
  invisible(TRUE)
}

.assert_pm_models <- function(pm_models, model_path_for_msg = "<unknown>") {
  if (is.null(pm_models$pm$Regression$PM2_5)) {
    stop("PM model object does not contain pm$Regression$PM2_5 as expected.\nModel path: ", model_path_for_msg)
  }
  invisible(TRUE)
}

# ---- read one already-downsampled file --------------------------------------
.read_one_ramp_ds <- function(path, tz_in = "UTC") {
  df <- suppressMessages(readr::read_csv(path, show_col_types = FALSE))
  
  need <- c("DATE", "CO", "NO", "NO2", "O3", "CO2", "T", "RH", "PM2.5")
  miss <- setdiff(need, names(df))
  if (length(miss) > 0) {
    warning("Skipping (missing): ", basename(path), " → ", paste(miss, collapse = ", "))
    return(NULL)
  }
  
  out <- df %>%
    transmute(
      date    = mdy_hm(.data$DATE, tz = tz_in, quiet = TRUE),
      CO      = suppressWarnings(parse_number(as.character(.data$CO))),
      NO      = suppressWarnings(parse_number(as.character(.data$NO))),
      NO2     = suppressWarnings(parse_number(as.character(.data$NO2))),
      O3      = suppressWarnings(parse_number(as.character(.data$O3))),
      CO2     = suppressWarnings(parse_number(as.character(.data$CO2))),
      T       = suppressWarnings(parse_number(as.character(.data$T))),
      RH      = suppressWarnings(parse_number(as.character(.data$RH))),
      `PM2.5` = suppressWarnings(parse_number(as.character(.data$`PM2.5`)))
    ) %>%
    filter(!is.na(date)) %>%
    arrange(date) %>%
    distinct(date, .keep_all = TRUE)
  
  if (!nrow(out)) return(NULL)
  out
}

# ---- drop negative rows -------------------------------------------------------
.drop_negative_rows <- function(df, cols, verbose = TRUE) {
  cols <- intersect(cols, names(df))
  if (!length(cols)) return(df)
  
  neg_mask <- Reduce(
    `|`,
    lapply(cols, function(c) !is.na(df[[c]]) & df[[c]] < 0),
    init = FALSE
  )
  
  n_neg <- if (is.logical(neg_mask)) sum(neg_mask) else 0L
  if (n_neg > 0 && isTRUE(verbose)) message("negative values detected and dropped")
  
  if (n_neg > 0) df[!neg_mask, , drop = FALSE] else df
}

# ---- apply RAMP calibration (gas + PM2.5) -----------------------------------
.apply_ramp_caps_calibration <- function(df, gas_models, pm_models,
                                         gas_model_path_for_msg = "<gas>",
                                         pm_model_path_for_msg = "<pm>") {
  .assert_gas_models(gas_models, gas_model_path_for_msg)
  .assert_pm_models(pm_models, pm_model_path_for_msg)
  
  df_clean <- df %>% select(date, CO, NO, NO2, O3, CO2, T, RH, `PM2.5`)
  
  # predictors: gases (7 inputs)
  gas_mat <- df_clean %>%
    select(CO, NO, NO2, O3, CO2, T, RH) %>%
    as.matrix()
  colnames(gas_mat) <- paste0("input", seq_len(ncol(gas_mat)))
  
  # predictors: PM (4 inputs) = PM2.5 raw + T + RH + DP
  pm_df <- df_clean %>%
    transmute(
      PM2_5_raw = `PM2.5`,
      T = T,
      RH = RH,
      DP = 243.12 *
        (log(RH / 100) + 17.62 * T / (243.12 + T)) /
        (17.62 - (log(RH / 100) + 17.62 * T / (243.12 + T)))
    )
  
  pm_mat <- pm_df %>% as.matrix()
  colnames(pm_mat) <- paste0("input", seq_len(ncol(pm_mat)))
  
  # gases: Hybrid models
  pred_gas <- tibble(
    date = df_clean$date,
    NO2  = as.numeric(CAPS_Hybrid_Apply(gas_models$gas$Hybrid$NO2, gas_mat)),
    NO   = as.numeric(CAPS_Hybrid_Apply(gas_models$gas$Hybrid$NO,  gas_mat)),
    CO2  = as.numeric(CAPS_Hybrid_Apply(gas_models$gas$Hybrid$CO2, gas_mat)),
    O3   = as.numeric(CAPS_Hybrid_Apply(gas_models$gas$Hybrid$O3,  gas_mat)),
    CO   = as.numeric(CAPS_Hybrid_Apply(gas_models$gas$Hybrid$CO,  gas_mat))
  )
  
  # PM2.5: PR model
  pred_pm <- as.numeric(CAPS_PR_Apply(pm_models$pm$Regression$PM2_5, pm_mat))
  
  pred_gas %>%
    mutate(PM2_5 = pred_pm)
}

# ---- public callable ---------------------------------------------------------
ramp_apply_calibration <- function(sensor_ids,
                                   # gas model selection:
                                   generalized_model   = FALSE,
                                   models_root         = default_models_root,
                                   generalized_id      = "2032",
                                   model_filename      = "Calibration_Models.obj",
                                   model_path          = NULL,   # gas override: file OR folder for all sensors
                                   # PM model selection:
                                   pm_use_generalized  = TRUE,
                                   pm_generalized_id   = "2032",
                                   pm_model_path       = NULL,   # PM override: file OR folder for all sensors
                                   # negative filtering:
                                   drop_negative_values = TRUE,  # NEW toggle (default TRUE)
                                   # other settings:
                                   caps_core_path      = "caps_core.R",
                                   in_root             = default_in_root,
                                   out_root            = default_out_root,
                                   tz_in               = "UTC",
                                   tz_out              = "UTC",
                                   overwrite           = TRUE,
                                   verbose             = TRUE) {
  
  sensor_ids <- as.character(sensor_ids)
  .ensure_caps_loaded(caps_core_path)
  
  in_root  <- normalizePath(in_root, winslash = "/", mustWork = FALSE)
  out_root <- normalizePath(out_root, winslash = "/", mustWork = FALSE)
  dir_create(out_root)
  
  results <- list()
  
  for (id in sensor_ids) {
    if (verbose) {
      message("\n────────────────────────────────────────")
      message("Calibrating RAMP sensor: ", id)
    }
    
    tryCatch({
    
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
    
    # ---- resolve/load gas model ---------------------------------------------
    gas_path <- .resolve_gas_model_path(
      sensor_id         = id,
      generalized_model = generalized_model,
      models_root       = models_root,
      generalized_id    = generalized_id,
      model_filename    = model_filename,
      model_path        = model_path
    )
    if (verbose) message("→ Using gas model: ", gas_path)
    gas_models <- .load_calibration_models_cached(gas_path)
    
    # ---- resolve/load PM model ----------------------------------------------
    pm_path <- .resolve_pm_model_path(
      sensor_id          = id,
      pm_use_generalized = pm_use_generalized,
      generalized_model  = generalized_model,
      models_root        = models_root,
      generalized_id     = generalized_id,
      pm_generalized_id  = pm_generalized_id,
      model_filename     = model_filename,
      model_path         = model_path,
      pm_model_path      = pm_model_path
    )
    if (verbose) {
      msg_kind <- if (!is.null(pm_model_path) && nzchar(pm_model_path)) "forced"
      else if (isTRUE(pm_use_generalized)) "generalized"
      else if (!is.null(model_path) && nzchar(model_path)) "same-as-gas (forced)"
      else "matched-to-gas-selection"
      message("→ Using PM model (", msg_kind, "): ", pm_path)
      message("→ Drop negative values: ", if (isTRUE(drop_negative_values)) "TRUE" else "FALSE")
    }
    pm_models <- .load_calibration_models_cached(pm_path)
    
    out_dir <- file.path(out_root, id)
    dir_create(out_dir)
    
    for (f in files) {
      base <- path_ext_remove(path_file(f))
      out_file <- file.path(out_dir, paste0(base, "_pred.csv"))
      
      if (file_exists(out_file) && !overwrite) {
        if (verbose) message("Exists (skipped): ", out_file)
        next
      }
      
      if (verbose) message("→ Reading: ", path_file(f))
      df <- .read_one_ramp_ds(f, tz_in = tz_in)
      if (is.null(df) || !nrow(df)) {
        if (verbose) message("  (no usable rows)")
        next
      }
      
      if (verbose) message("→ Applying RAMP CAPS calibration (gas + PM2.5) …")
      pred <- .apply_ramp_caps_calibration(
        df,
        gas_models = gas_models,
        pm_models  = pm_models,
        gas_model_path_for_msg = gas_path,
        pm_model_path_for_msg  = pm_path
      )
      
      pred_out <- pred %>%
        mutate(DATE = format(with_tz(date, tz_out), "%m/%d/%Y %H:%M")) %>%
        select(DATE, CO, NO, NO2, O3, CO2, PM2_5)
      
      if (isTRUE(drop_negative_values)) {
        pred_out <- .drop_negative_rows(
          pred_out,
          cols = c("CO", "NO", "NO2", "O3", "CO2", "PM2_5"),
          verbose = verbose
        )
        
        if (!nrow(pred_out)) {
          warning("All rows dropped after negative-value filtering for: ", id, " / ", path_file(f))
          next
        }
      }
      
      write_csv(pred_out, out_file, na = "")
      if (verbose) message("Wrote: ", out_file)
      
      results[[length(results) + 1]] <- list(
        sensor_id            = id,
        in_file              = f,
        out_file             = out_file,
        rows                 = nrow(pred_out),
        gas_model_path       = gas_path,
        pm_model_path        = pm_path,
        generalized_model    = generalized_model,
        pm_use_generalized   = pm_use_generalized,
        drop_negative_values = drop_negative_values,
        tz_in                = tz_in,
        tz_out               = tz_out
      )
    }
    
    }, error = function(e) {
      warning("SKIPPED sensor ", id, " due to error: ", conditionMessage(e))
    })
  }
  
  invisible(results)
}

# ---- optional CLI ------------------------------------------------------------
.parse_args <- function(args) {
  get_flag <- function(flag, default = NULL) {
    i <- match(flag, args)
    if (!is.na(i) && i < length(args)) return(args[[i + 1]])
    default
  }
  
  sensors_raw <- get_flag("--sensors", NA_character_)
  if (is.na(sensors_raw)) stop("Missing --sensors (comma-separated), e.g. --sensors 2021,2040")
  
  generalized_raw <- get_flag("--generalized", "FALSE")
  generalized_val <- tolower(generalized_raw) %in% c("true", "t", "1", "yes", "y")
  
  pm_gen_raw <- get_flag("--pm-generalized", "TRUE")
  pm_gen_val <- tolower(pm_gen_raw) %in% c("true", "t", "1", "yes", "y")
  
  drop_neg_raw <- get_flag("--drop-negatives", "TRUE")
  drop_neg_val <- tolower(drop_neg_raw) %in% c("true", "t", "1", "yes", "y")
  
  # convenience switch overrides everything else
  if ("--keep-negatives" %in% args) drop_neg_val <- FALSE
  
  list(
    sensors            = strsplit(sensors_raw, ",", fixed = TRUE)[[1]] |>
      str_trim() |> (\(x) x[nzchar(x)])(),
    model              = get_flag("--model", NULL),       # gas: file OR folder
    pm_model           = get_flag("--pm-model", NULL),    # pm: file OR folder
    models_root        = get_flag("--models-root", default_models_root),
    generalized        = generalized_val,
    generalized_id     = get_flag("--generalized-id", "2032"),
    pm_use_generalized = pm_gen_val,
    pm_generalized_id  = get_flag("--pm-generalized-id", "2032"),
    drop_negatives     = drop_neg_val,
    model_filename     = get_flag("--model-filename", "Calibration_Models.obj"),
    caps               = get_flag("--caps", "caps_core.R"),
    in_root            = get_flag("--in-root",  default_in_root),
    out_root           = get_flag("--out-root", default_out_root),
    tz_in              = get_flag("--tz-in",  "UTC"),
    tz_out             = get_flag("--tz-out", "UTC"),
    overwrite          = !("--no-overwrite" %in% args),
    verbose            = !("--quiet" %in% args)
  )
}

if (identical(environmentName(environment()), "R_GlobalEnv") && !interactive() && !isTRUE(getOption("pipeline.sourced"))) {
  a <- .parse_args(commandArgs(trailingOnly = TRUE))
  
  if ((is.null(a$model) || !nzchar(a$model)) && (is.null(a$models_root) || !nzchar(a$models_root))) {
    stop("Provide --model <file-or-folder> OR --models-root <folder containing <id>/Calibration_Models.obj>.")
  }
  
  ramp_apply_calibration(
    sensor_ids          = a$sensors,
    generalized_model   = a$generalized,
    models_root         = a$models_root,
    generalized_id      = a$generalized_id,
    model_filename      = a$model_filename,
    model_path          = a$model,
    pm_use_generalized  = a$pm_use_generalized,
    pm_generalized_id   = a$pm_generalized_id,
    pm_model_path       = a$pm_model,
    drop_negative_values = a$drop_negatives,
    caps_core_path      = a$caps,
    in_root             = a$in_root,
    out_root            = a$out_root,
    tz_in               = a$tz_in,
    tz_out              = a$tz_out,
    overwrite           = a$overwrite,
    verbose             = a$verbose
  )
}

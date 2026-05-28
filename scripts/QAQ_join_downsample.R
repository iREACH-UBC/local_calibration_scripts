#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(lubridate)
  library(purrr)
  library(fs)
  library(stringr)
  library(openair)
  library(tibble)
})

# =============================================================================
# QAQ join + downsample (15 min) per sensor
#
# INPUT (default):
#   ../apply_calibrations/apply_calibrations_data/<sensor_id>/*.csv
#
# OUTPUT:
#   ../apply_calibrations/apply_calibrations_joined_downsampled_data/<sensor_id>/
#     <YYYY-MM-DD>_to_<YYYY-MM-DD>_<sensor_id>.csv
#
# Timestamp handling:
#   Uses a UTC timestamp string like "2025-05-02T21:08:16" (NOT tz-aware).
#   We explicitly interpret it as UTC.
# =============================================================================

# ---- Defaults (relative to current working directory) ------------------------
default_in_root  <- file.path("..", "apply_calibrations", "apply_calibrations_data")
default_out_root <- file.path("..", "apply_calibrations", "apply_calibrations_joined_downsampled_data")
default_avg_time <- "15 min"

# ---- Helpers ----------------------------------------------------------------
parse_utc_timestamp <- function(x) {
  # Be robust to common variants:
  #   "2025-05-02T21:08:16"
  #   "2025-05-02T21:08:16Z"
  #   "2025-05-02 21:08:16"
  x <- as.character(x)
  x <- gsub("Z$", "", x)
  x <- gsub("T", " ", x, fixed = TRUE)
  # Interpret as UTC (even though string has no tz info)
  ymd_hms(x, tz = "UTC", quiet = TRUE)
}

read_one_qaq <- function(path) {
  df <- suppressMessages(readr::read_csv(path, show_col_types = FALSE))
  
  # Required columns (timestamp must be UTC string)
  # If your files use different names, add them here.
  ts_candidates <- c("timestamp", "timestamp_utc", "timestamp_local")
  ts_col <- intersect(ts_candidates, names(df))
  if (!length(ts_col)) {
    warning("Skipping (missing timestamp): ", basename(path),
            " → needs one of: ", paste(ts_candidates, collapse = ", "))
    return(NULL)
  }
  ts_col <- ts_col[[1]]
  
  need <- c("co","no","no2","o3","co2","temp","rh","pm25")
  miss <- setdiff(need, names(df))
  if (length(miss) > 0) {
    warning("Skipping (missing): ", basename(path), " → ", paste(miss, collapse = ", "))
    return(NULL)
  }
  
  out <- df %>%
    transmute(
      date   = parse_utc_timestamp(.data[[ts_col]]),   # POSIXct in UTC
      CO     = as.numeric(.data$co),
      NO     = as.numeric(.data$no),
      NO2    = as.numeric(.data$no2),
      O3     = as.numeric(.data$o3),
      CO2    = as.numeric(.data$co2),
      T      = as.numeric(.data$temp),
      RH     = as.numeric(.data$rh),
      `PM2.5`= as.numeric(.data$pm25)
    ) %>%
    filter(!is.na(date))
  
  if (!nrow(out)) return(NULL)
  out
}

# ---- Core: one sensor --------------------------------------------------------
process_qaq_sensor_join_downsample <- function(id,
                                               in_root = default_in_root,
                                               out_root = default_out_root,
                                               avg_time = default_avg_time,
                                               overwrite = TRUE) {
  message("\n────────────────────────────────────────")
  message("Processing QAQ sensor: ", id)
  
  sensor_dir <- file.path(in_root, id)
  if (!dir_exists(sensor_dir)) {
    warning("Sensor dir does not exist for ", id, ": ", sensor_dir)
    return(invisible(NULL))
  }
  
  # Read all CSVs in the sensor folder
  files <- dir_ls(sensor_dir, type = "file", glob = "*.csv")
  if (!length(files)) {
    warning("No CSV files found for ", id, " in ", sensor_dir)
    return(invisible(NULL))
  }
  
  message("Reading ", length(files), " QAQ CSVs for ", id, "…")
  data_list <- map(files, read_one_qaq)
  data_list <- data_list[!vapply(data_list, is.null, logical(1))]
  if (!length(data_list)) {
    warning("No usable QAQ files for ", id)
    return(invisible(NULL))
  }
  
  raw_df <- bind_rows(data_list) %>%
    arrange(date) %>%
    distinct(date, .keep_all = TRUE)
  
  if (!nrow(raw_df)) {
    warning("No rows after merge for ", id)
    return(invisible(NULL))
  }
  
  # Determine actual covered date range (UTC)
  d_start <- as.Date(min(raw_df$date, na.rm = TRUE), tz = "UTC")
  d_end   <- as.Date(max(raw_df$date, na.rm = TRUE), tz = "UTC")
  
  # Downsample (openair expects a column named 'date')
  anchor <- floor_date(min(raw_df$date, na.rm = TRUE), unit = avg_time)
  ds <- openair::timeAverage(
    raw_df,
    avg.time    = avg_time,
    start.date  = anchor,
    data.thresh = 0
  ) %>%
    as_tibble()
  
  if (!nrow(ds)) {
    warning("No rows after downsampling for ", id)
    return(invisible(NULL))
  }
  
  # Output columns (UTC)
  ds_out <- ds %>%
    mutate(
      DATE = format(with_tz(date, "UTC"), "%m/%d/%Y %H:%M")
    ) %>%
    select(DATE, CO, NO, NO2, O3, CO2, T, RH, `PM2.5`)
  
  # Output path
  out_dir <- file.path(out_root, id)
  dir_create(out_dir)
  
  out_file <- file.path(out_dir, sprintf("%s_to_%s_%s.csv", d_start, d_end, id))
  
  if (file_exists(out_file) && !overwrite) {
    message("Exists (skipped): ", out_file)
    return(invisible(out_file))
  }
  
  write_csv(ds_out, out_file, na = "")
  message("Wrote: ", out_file)
  
  invisible(out_file)
}

# ---- Public callable wrapper -------------------------------------------------
qaq_join_downsample_all <- function(sensor_ids,
                                    in_root = default_in_root,
                                    out_root = default_out_root,
                                    avg_time = default_avg_time,
                                    overwrite = TRUE) {
  sensor_ids <- as.character(sensor_ids)
  walk(sensor_ids, ~process_qaq_sensor_join_downsample(.x, in_root, out_root, avg_time, overwrite))
  invisible(TRUE)
}

# ---- Optional CLI ------------------------------------------------------------
# Example:
#   Rscript QAQ_join_downsample.R --sensors MOD-00619,MOD-00623 --in-root ../apply_calibrations/apply_calibrations_data
parse_args <- function(args) {
  get_flag <- function(flag, default = NULL) {
    i <- match(flag, args)
    if (!is.na(i) && i < length(args)) return(args[[i + 1]])
    default
  }
  
  sensors_raw <- get_flag("--sensors", NA_character_)
  if (is.na(sensors_raw)) stop("Missing --sensors (comma-separated), e.g. --sensors MOD-00619,MOD-00623")
  
  list(
    sensors   = strsplit(sensors_raw, ",", fixed = TRUE)[[1]] |> str_trim() |> (\(x) x[nzchar(x)])(),
    in_root   = get_flag("--in-root",  default_in_root),
    out_root  = get_flag("--out-root", default_out_root),
    avg_time  = get_flag("--avg-time", default_avg_time),
    overwrite = !("--no-overwrite" %in% args)
  )
}

if (identical(environmentName(environment()), "R_GlobalEnv") && !interactive() && !isTRUE(getOption("pipeline.sourced"))) {
  a <- parse_args(commandArgs(trailingOnly = TRUE))
  qaq_join_downsample_all(
    sensor_ids = a$sensors,
    in_root    = a$in_root,
    out_root   = a$out_root,
    avg_time   = a$avg_time,
    overwrite  = a$overwrite
  )
}

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
# RAMP join + downsample (15 min) per sensor
#
# INPUT (default):
#   ../apply_calibrations/apply_calibrations_data/<sensor_id>/*.csv
#
# OUTPUT (default):
#   ../apply_calibrations/apply_calibrations_joined_downsampled_data/<sensor_id>/
#     <YYYY-MM-DD>_to_<YYYY-MM-DD>_<sensor_id>.csv
#
# Timezone handling:
#   - Interpret timestamp strings as UTC (even if they have no tz info)
#   - Output DATE formatted in UTC "%m/%d/%Y %H:%M"
#
#
# =-=-= DOES THE SAME THING AS RAMP_join_downsample.R BUT INCLUDES WIND =-=-=-=
#
# =============================================================================

# ---- Defaults (relative to current working directory) ------------------------
default_in_root  <- file.path("..", "apply_calibrations", "apply_calibrations_data")
default_out_root <- file.path("..", "apply_calibrations", "apply_calibrations_joined_downsampled_data")
default_avg_time <- "15 min"

# ---- Helpers ----------------------------------------------------------------
parse_ramp_timestamp_utc <- function(x) {
  # Robust to common RAMP variants:
  #   "11/01/2025 12:15"
  #   "11/01/2025 12:15:00"
  #   "2025-11-01 12:15"
  #   "2025-11-01T12:15:00"
  x <- as.character(x)
  x <- gsub("Z$", "", x)
  x <- gsub("T", " ", x, fixed = TRUE)
  
  suppressWarnings(
    parse_date_time(
      x,
      orders = c("mdy HMS", "mdy HM", "ymd HMS", "ymd HM"),
      tz = "UTC"
    )
  )
}

read_one_ramp <- function(path) {
  df <- suppressMessages(readr::read_csv(path, show_col_types = FALSE))
  
  need <- c("DATE", "CO", "NO", "NO2", "O3", "CO2", "T", "RH", "PM2.5", "WD", "WS")
  miss <- setdiff(need, names(df))
  if (length(miss) > 0) {
    warning("Skipping (missing): ", basename(path), " → ", paste(miss, collapse = ", "))
    return(NULL)
  }
  
  out <- df %>%
    transmute(
      date    = parse_ramp_timestamp_utc(.data$DATE),
      CO      = as.numeric(.data$CO),
      NO      = as.numeric(.data$NO),
      NO2     = as.numeric(.data$NO2),
      O3      = as.numeric(.data$O3),
      CO2     = as.numeric(.data$CO2),
      T       = as.numeric(.data$T),
      RH      = as.numeric(.data$RH),
      `PM2.5` = as.numeric(.data$`PM2.5`),
      WD      = as.numeric(.data$WD),
      WS      = as.numeric(.data$WS)
    ) %>%
    filter(!is.na(date))
  
  if (!nrow(out)) return(NULL)
  out
}

# Optional: filter by filename leading date "YYYY-MM-DD..."
extract_lead_date <- function(paths) {
  m <- str_match(basename(paths), "^(\\d{4}-\\d{2}-\\d{2})")
  as.Date(m[, 2])
}

# ---- Core: one sensor (same signature pattern as QAQ) ------------------------
process_ramp_sensor_join_downsample <- function(id,
                                                in_root = default_in_root,
                                                out_root = default_out_root,
                                                avg_time = default_avg_time,
                                                overwrite = TRUE,
                                                date_start = NULL,
                                                date_end = NULL) {
  message("\n────────────────────────────────────────")
  message("Processing RAMP sensor: ", id)
  
  sensor_dir <- file.path(in_root, id)
  if (!dir_exists(sensor_dir)) {
    warning("Sensor dir does not exist for ", id, ": ", sensor_dir)
    return(invisible(NULL))
  }
  
  files <- dir_ls(sensor_dir, type = "file", glob = "*.csv")
  if (!length(files)) {
    warning("No CSV files found for ", id, " in ", sensor_dir)
    return(invisible(NULL))
  }
  
  # Optional filename-date filtering (kept optional to preserve call structure)
  if (!is.null(date_start) || !is.null(date_end)) {
    if (is.null(date_start) || is.null(date_end)) {
      stop("If using date filtering, provide BOTH date_start and date_end.")
    }
    date_start <- as.Date(date_start)
    date_end   <- as.Date(date_end)
    stopifnot(date_start <= date_end)
    
    lead_dates <- extract_lead_date(files)
    keep <- !is.na(lead_dates) & lead_dates >= date_start & lead_dates <= date_end
    files <- files[keep]
    
    if (!length(files)) {
      warning("No matching CSVs in range for ", id, " (", date_start, " to ", date_end, ")")
      return(invisible(NULL))
    }
  }
  
  message("Reading ", length(files), " RAMP CSVs for ", id, "…")
  data_list <- map(files, read_one_ramp)
  data_list <- data_list[!vapply(data_list, is.null, logical(1))]
  if (!length(data_list)) {
    warning("No usable RAMP files for ", id)
    return(invisible(NULL))
  }
  
  raw_df <- bind_rows(data_list) %>%
    arrange(date) %>%
    distinct(date, .keep_all = TRUE)
  
  if (!nrow(raw_df)) {
    warning("No rows after merge for ", id)
    return(invisible(NULL))
  }
  
  # Actual covered range (UTC)
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
    mutate(DATE = format(with_tz(date, "UTC"), "%m/%d/%Y %H:%M")) %>%
    select(DATE, CO, NO, NO2, O3, CO2, T, RH, `PM2.5`, WD, WS)
  
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

# ---- Public callable wrapper (same as QAQ) ----------------------------------
ramp_join_downsample_all <- function(sensor_ids,
                                     in_root = default_in_root,
                                     out_root = default_out_root,
                                     avg_time = default_avg_time,
                                     overwrite = TRUE,
                                     date_start = NULL,
                                     date_end = NULL) {
  sensor_ids <- as.character(sensor_ids)
  walk(sensor_ids, ~process_ramp_sensor_join_downsample(
    id        = .x,
    in_root   = in_root,
    out_root  = out_root,
    avg_time  = avg_time,
    overwrite = overwrite,
    date_start = date_start,
    date_end   = date_end
  ))
  invisible(TRUE)
}

# ---- Optional CLI (same structure as QAQ; date flags optional) ---------------
# Example:
#   Rscript RAMP_join_downsample.R --sensors 2021,2040 --in-root ../apply_calibrations/apply_calibrations_data
# Optional:
#   --date-start 2025-11-01 --date-end 2025-12-01
parse_args <- function(args) {
  get_flag <- function(flag, default = NULL) {
    i <- match(flag, args)
    if (!is.na(i) && i < length(args)) return(args[[i + 1]])
    default
  }
  
  sensors_raw <- get_flag("--sensors", NA_character_)
  if (is.na(sensors_raw)) stop("Missing --sensors (comma-separated), e.g. --sensors 2021,2040")
  
  ds <- get_flag("--date-start", NULL)
  de <- get_flag("--date-end",   NULL)
  
  list(
    sensors    = strsplit(sensors_raw, ",", fixed = TRUE)[[1]] |> str_trim() |> (\(x) x[nzchar(x)])(),
    in_root    = get_flag("--in-root",  default_in_root),
    out_root   = get_flag("--out-root", default_out_root),
    avg_time   = get_flag("--avg-time", default_avg_time),
    overwrite  = !("--no-overwrite" %in% args),
    date_start = ds,
    date_end   = de
  )
}

if (identical(environmentName(environment()), "R_GlobalEnv") && !interactive()) {
  a <- parse_args(commandArgs(trailingOnly = TRUE))
  ramp_join_downsample_all(
    sensor_ids = a$sensors,
    in_root    = a$in_root,
    out_root   = a$out_root,
    avg_time   = a$avg_time,
    overwrite  = a$overwrite,
    date_start = a$date_start,
    date_end   = a$date_end
  )
}

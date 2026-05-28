options(pipeline.sourced = TRUE)
local({ source(file.path('C:/ProgramData/iREACH/scripts', 'QAQ_apply_calibration.R')) })
qaq_apply_general_calibration(
  sensor_ids        = c('MOD-00632','MOD-00616','MOD-00625','MOD-00631','MOD-00623','MOD-00628','MOD-00627','MOD-00629','MOD-00614','MOD-00617','MOD-00618','MOD-00613','MOD-00622','MOD-00621'),
  generalized_model = FALSE,
  models_root       = 'C:/ProgramData/iREACH/calibration_objects',
  in_root           = 'C:/ProgramData/iREACH/data/downsampled',
  out_root          = 'C:/ProgramData/iREACH/data/calibrated',
  caps_core_path    = file.path('C:/ProgramData/iREACH/scripts', 'caps_core.R'),
  tz_in             = 'UTC',
  tz_out            = 'UTC'
)
local({ source(file.path('C:/ProgramData/iREACH/scripts', 'RAMP_apply_calibration.R')) })
ramp_apply_calibration(
  sensor_ids           = c('2021','2022','2023','2024','2025','2026','2027','2028','2029','2030','2031','2033','2035','2036','2037','2039','2040','2042','2043','2044','2045','2046','2047','2048','2049','2020'),
  generalized_model    = FALSE,
  models_root          = 'C:/ProgramData/iREACH/calibration_objects',
  pm_use_generalized   = TRUE,
  pm_generalized_id    = '2032',
  drop_negative_values = FALSE,
  in_root              = 'C:/ProgramData/iREACH/data/downsampled',
  out_root             = 'C:/ProgramData/iREACH/data/calibrated',
  caps_core_path       = file.path('C:/ProgramData/iREACH/scripts', 'caps_core.R'),
  tz_in                = 'UTC',
  tz_out               = 'UTC'
)

options(pipeline.sourced = TRUE)
source('C:/ProgramData/iREACH/scripts/QAQ_apply_calibration.R')
qaq_apply_general_calibration(
  sensor_ids        = c('MOD-00632','MOD-00616','MOD-00625','MOD-00631','MOD-00623','MOD-00628','MOD-00627','MOD-00629','MOD-00614','MOD-00617','MOD-00618','MOD-00613','MOD-00622','MOD-00621'),
  generalized_model = FALSE,
  models_root       = 'C:/ProgramData/iREACH/calibration_objects',
  in_root           = 'C:/ProgramData/iREACH/data/downsampled',
  out_root          = 'C:/ProgramData/iREACH/data/calibrated',
  caps_core_path    = 'C:/ProgramData/iREACH/scripts/caps_core.R',
  tz_in             = 'UTC',
  tz_out            = 'UTC'
)

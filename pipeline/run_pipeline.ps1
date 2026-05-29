# =============================================================================
# iREACH LCS Pipeline - run_pipeline.ps1
# Runs every 15 minutes via Task Scheduler (SYSTEM account).
# =============================================================================

param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
$ROOT = "C:\ProgramData\iREACH"

$CFG = @{
    ScriptsDir      = "$ROOT\scripts"
    CalObjDir       = "$ROOT\calibration_objects"
    RawDir          = "$ROOT\data\raw"
    DownsampledDir  = "$ROOT\data\downsampled"
    CalibratedDir   = "$ROOT\data\calibrated"
    PublishDir      = "$ROOT\data\publish"
    OutputDir       = "$ROOT\output"
    LogDir          = "$ROOT\logs"
    PipelineDir     = "$ROOT\pipeline"
    RScriptExe      = "C:\Program Files\R\R-4.5.3\bin\Rscript.exe"
    PythonExe       = "C:\ProgramData\Python\bin\python.exe"
    GitExe          = "C:\Program Files\Git\cmd\git.exe"
    R2Bucket        = "lcs-calibrated-data"
    R2Endpoint      = "https://bfde061b9c815bbce1c08766ebac283d.r2.cloudflarestorage.com"
    R2Prefix        = "calibrated"
    RepoDir         = "$ROOT\output"
    GitBranch       = "main"
    QAQSensorIDs    = @(
        "MOD-00632","MOD-00616","MOD-00625","MOD-00631","MOD-00623",
        "MOD-00628","MOD-00627","MOD-00629","MOD-00614","MOD-00617",
        "MOD-00618","MOD-00613","MOD-00622","MOD-00621"
    )
    RAMPSensorIDs   = @(
        "2021","2022","2023","2024","2025","2026","2027","2028","2029","2030",
        "2031","2033","2035","2036","2037","2039","2040","2042","2043","2044",
        "2045","2046","2047","2048","2049","2020"
    )
}

# ---------------------------------------------------------------------------
# LOCK FILE
# ---------------------------------------------------------------------------
$LockFile = "$($CFG.PipelineDir)\pipeline.lock"

if (-not $Force) {
    if (Test-Path $LockFile) {
        $lockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
        if ($lockAge.TotalMinutes -lt 30) {
            Write-Host "Previous run still active. Exiting."
            exit 0
        }
        Remove-Item $LockFile -Force
    }
    New-Item $LockFile -ItemType File -Force | Out-Null
}

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
$LogFile = "$($CFG.LogDir)\pipeline_$(Get-Date -f 'yyyy-MM-dd').log"

function Write-Log {
    param([string]$Level, [string]$Msg)
    $line = "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][$Level] $Msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
function Log-Info  { param([string]$m) Write-Log "INFO " $m }
function Log-Warn  { param([string]$m) Write-Log "WARN " $m }
function Log-Error { param([string]$m) Write-Log "ERROR" $m }

# ---------------------------------------------------------------------------
# ENSURE DIRECTORIES EXIST
# ---------------------------------------------------------------------------
@(
    $CFG.RawDir, $CFG.DownsampledDir, $CFG.CalibratedDir,
    $CFG.PublishDir, $CFG.OutputDir, $CFG.LogDir
) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# ---------------------------------------------------------------------------
# STEP RUNNER
# ---------------------------------------------------------------------------
function Invoke-Step {
    param([string]$Label, [scriptblock]$Block)
    Log-Info "START $Label"
    try {
        & $Block
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
        Log-Info "OK $Label"
    } catch {
        Log-Error "FAILED $Label - $_"
        if (Test-Path $LockFile) { Remove-Item $LockFile -Force }
        throw
    }
}

# ---------------------------------------------------------------------------
# DATE WINDOW
# ---------------------------------------------------------------------------
$UtcNow    = [System.DateTime]::UtcNow
$EndDate   = $UtcNow.Date
$StartDate = $EndDate.AddDays(-2)
$StartUTC  = $StartDate.ToString("yyyy-MM-dd")
$EndUTC    = $EndDate.ToString("yyyy-MM-dd")
$EtZone    = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")
$NowET     = [System.TimeZoneInfo]::ConvertTimeFromUtc($UtcNow, $EtZone)
$StartET   = $StartDate.ToString("yyyy-MM-dd")
$EndET     = $NowET.Date.ToString("yyyy-MM-dd")
$Month     = Get-Date -Format "yyyy-MM"

Log-Info "Pipeline starting"
Log-Info "UTC window: $StartUTC to $EndUTC"
Log-Info "ET window: $StartET to $EndET"
Log-Info "Month: $Month"

# ---------------------------------------------------------------------------
# 1. CLEAN RAW DATA (wipe and redownload fresh 48h window each run)
# ---------------------------------------------------------------------------
Log-Info "Clearing raw data for fresh 48h download..."
@($CFG.QAQSensorIDs + $CFG.RAMPSensorIDs) | ForEach-Object {
    $sensorRaw = "$($CFG.RawDir)\$_"
    if (Test-Path $sensorRaw) {
        Remove-Item "$sensorRaw\*.csv" -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 2. DOWNLOAD
# ---------------------------------------------------------------------------
Invoke-Step "Download QAQ" {
    & $CFG.PythonExe "$($CFG.ScriptsDir)\QAQ_download.py" `
        --sensors  $CFG.QAQSensorIDs `
        --start    $StartUTC `
        --end      $EndUTC `
        --out-root $CFG.RawDir
}

Invoke-Step "Download RAMP" {
    & $CFG.PythonExe "$($CFG.ScriptsDir)\RAMP_download.py" `
        --sensors  $CFG.RAMPSensorIDs `
        --start    $StartET `
        --end      $EndET `
        --out-root $CFG.RawDir `
        --base-url "http://18.222.146.48/RAMP/v1/raw"
}

# ---------------------------------------------------------------------------
# 2. JOIN AND DOWNSAMPLE
# ---------------------------------------------------------------------------
Log-Info "Clearing downsampled data for fresh join..."
@($CFG.QAQSensorIDs + $CFG.RAMPSensorIDs) | ForEach-Object {
    $sensorDs = "$($CFG.DownsampledDir)\$_"
    if (Test-Path $sensorDs) {
        Remove-Item "$sensorDs\*.csv" -Force -ErrorAction SilentlyContinue
    }
}
$qaqIds  = "'" + ($CFG.QAQSensorIDs  -join "','") + "'"
$rampIds = "'" + ($CFG.RAMPSensorIDs -join "','") + "'"

$ScriptsDir    = $CFG.ScriptsDir    -replace '\\','/'
$RawDir        = $CFG.RawDir        -replace '\\','/'
$DownsampledDir= $CFG.DownsampledDir-replace '\\','/'
$CalibratedDir = $CFG.CalibratedDir -replace '\\','/'
$CalObjDir     = $CFG.CalObjDir     -replace '\\','/'

$rJoin = @"
options(pipeline.sourced = TRUE)
source(file.path('$ScriptsDir', 'QAQ_join_downsample.R'))
qaq_join_downsample_all(
  sensor_ids = c($qaqIds),
  in_root    = '$RawDir',
  out_root   = '$DownsampledDir',
  avg_time   = '15 min',
  overwrite  = TRUE
)
source(file.path('$ScriptsDir', 'RAMP_join_downsample.R'))
ramp_join_downsample_all(
  sensor_ids = c($rampIds),
  in_root    = '$RawDir',
  out_root   = '$DownsampledDir',
  avg_time   = '15 min',
  overwrite  = TRUE
)
"@

Invoke-Step "Join and downsample" {
    $tmp = "C:\ProgramData\iREACH\pipeline\tmp_pipeline_join.R"
    Set-Content $tmp $rJoin -Encoding ASCII
    & $CFG.RScriptExe $tmp
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 3. CALIBRATE
# ---------------------------------------------------------------------------
Log-Info "Clearing calibrated data for fresh calibration..."
@($CFG.QAQSensorIDs + $CFG.RAMPSensorIDs) | ForEach-Object {
    $sensorCal = "$($CFG.CalibratedDir)\$_"
    if (Test-Path $sensorCal) {
        Remove-Item "$sensorCal\*.csv" -Force -ErrorAction SilentlyContinue
    }
}
$rCal = @"
options(pipeline.sourced = TRUE)
local({ source(file.path('$ScriptsDir', 'QAQ_apply_calibration.R')) })
qaq_apply_general_calibration(
  sensor_ids        = c($qaqIds),
  generalized_model = FALSE,
  models_root       = '$CalObjDir',
  in_root           = '$DownsampledDir',
  out_root          = '$CalibratedDir',
  caps_core_path    = file.path('$ScriptsDir', 'caps_core.R'),
  tz_in             = 'UTC',
  tz_out            = 'UTC'
)
local({ source(file.path('$ScriptsDir', 'RAMP_apply_calibration.R')) })
ramp_apply_calibration(
  sensor_ids           = c($rampIds),
  generalized_model    = FALSE,
  models_root          = '$CalObjDir',
  pm_use_generalized   = TRUE,
  pm_generalized_id    = '2032',
  drop_negative_values = FALSE,
  in_root              = '$DownsampledDir',
  out_root             = '$CalibratedDir',
  caps_core_path       = file.path('$ScriptsDir', 'caps_core.R'),
  tz_in                = 'UTC',
  tz_out               = 'UTC'
)
"@

Invoke-Step "Calibrate" {
    $tmp = "C:\ProgramData\iREACH\pipeline\tmp_pipeline_cal.R"
    Set-Content $tmp $rCal -Encoding ASCII
    & $CFG.RScriptExe $tmp
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 4. BUILD MONTHLY COMBINED CSV AND UPLOAD TO R2
# ---------------------------------------------------------------------------
Invoke-Step "Upload to R2" {
    & $CFG.PythonExe "$($CFG.PipelineDir)\upload_to_r2.py" `
        --calibrated-dir $CFG.CalibratedDir `
        --publish-dir    $CFG.PublishDir `
        --bucket         $CFG.R2Bucket `
        --endpoint       $CFG.R2Endpoint `
        --month          $Month `
        --no-merge
}

# ---------------------------------------------------------------------------
# 5. GENERATE JSON
# ---------------------------------------------------------------------------
Invoke-Step "Generate JSON" {
    & $CFG.PythonExe "$($CFG.ScriptsDir)\generate_json.py" `
        --base-dir    $CFG.CalibratedDir `
        --meta-csv    "$($CFG.ScriptsDir)\sensor_metadata.csv" `
        --output-json "$($CFG.OutputDir)\pollutant_data.json"
}

# ---------------------------------------------------------------------------
# 6. GENERATE ELUSIVE JSON
# ---------------------------------------------------------------------------
Invoke-Step "Generate Elusive JSON" {
    & $CFG.PythonExe "$($CFG.ScriptsDir)\generate_elusive_json.py" `
        --base-dir    $CFG.CalibratedDir `
        --output-dir  "$ROOT\elusive_output\data"
}

# ---------------------------------------------------------------------------
# 7. GIT PUSH (main dashboard)
# ---------------------------------------------------------------------------
Invoke-Step "Git push" {
    Push-Location $CFG.RepoDir
    try {
        & $CFG.GitExe add "pollutant_data.json"
        $status = & $CFG.GitExe status --porcelain
        if ($status) {
            $msg = "auto: pollutant_data.json $(Get-Date -f 'yyyy-MM-dd HH:mm') UTC"
            & $CFG.GitExe commit -m $msg
            & $CFG.GitExe push origin $CFG.GitBranch
            Log-Info "Pushed to GitHub"
        } else {
            Log-Info "No changes to commit"
        }
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# 8. GIT PUSH (Elusive dashboard)
# ---------------------------------------------------------------------------
Invoke-Step "Git push Elusive" {
    $ElusiveRepoDir = "$ROOT\elusive_output"
    Push-Location $ElusiveRepoDir
    try {
        & $CFG.GitExe add "data/history.geojson" "data/latest.json"
        $status = & $CFG.GitExe status --porcelain
        if ($status) {
            $msg = "auto: elusive data $(Get-Date -f 'yyyy-MM-dd HH:mm') UTC"
            & $CFG.GitExe commit -m $msg
            & $CFG.GitExe push origin main
            Log-Info "Pushed Elusive to GitHub"
        } else {
            Log-Info "No Elusive changes to commit"
        }
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# DONE
# ---------------------------------------------------------------------------
if (Test-Path $LockFile) { Remove-Item $LockFile -Force }
Log-Info "Pipeline complete"
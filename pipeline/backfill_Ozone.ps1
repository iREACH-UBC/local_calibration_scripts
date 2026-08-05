# =============================================================================
# backfill_Ozone.ps1
# RAMP + QAQ ozone-override backfill for selected sensors only.
#
# Purpose:
#   - Run from April 1, 2025 onward by default.
#   - Only process the RAMP and QAQ sensors listed in the O3 override lists.
#   - Only query each sensor from its deployment date onward.
#
# O3 model routing:
#   - Selected RAMP sensors use generalized O3 model from calibration object 2032.
#   - Selected QAQ sensors use generalized O3 model from calibration object MOD-00111.
#   - Other gas pollutants remain sensor-specific because generalized_model=FALSE.
#   - RAMP PM2.5 remains generalized 2032.
#   - QAQ PM2.5 remains raw passthrough, assuming your overwritten QAQ_apply_calibration.R
#     preserves the previous PM passthrough behavior.
#
# Notes:
#   - This assumes you overwrote:
#       C:\ProgramData\iREACH\scripts\RAMP_apply_calibration.R
#       C:\ProgramData\iREACH\scripts\QAQ_apply_calibration.R
#     with the ozone-override versions.
#
# Usage examples:
#   .\backfill.ps1
#   .\backfill.ps1 -StartOverride "2025-09-01"
#   .\backfill.ps1 -StartOverride "2025-09-01" -EndOverride "2026-04-04"
# =============================================================================

param(
    [string]$StartOverride = "2025-04-01",
    [string]$EndOverride   = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
$ROOT           = "C:\ProgramData\iREACH"
$ScriptsDirW    = "$ROOT\scripts"
$CalObjDirW     = "$ROOT\calibration_objects"
$RawDirW        = "$ROOT\backfill\raw"
$DownDirW       = "$ROOT\backfill\downsampled"
$CalDirW        = "$ROOT\backfill\calibrated"
$PublishDirW    = "$ROOT\backfill\publish"
$LogDir         = "$ROOT\logs"
$PipelineDir    = "$ROOT\pipeline"

$RScriptExe     = "C:\Program Files\R\R-4.5.3\bin\Rscript.exe"
$PythonExe      = "C:\ProgramData\Python\bin\python.exe"

$R2Bucket       = "lcs-calibrated-data"
$R2Endpoint     = "https://bfde061b9c815bbce1c08766ebac283d.r2.cloudflarestorage.com"

# Use forward slashes inside generated R code.
$ScriptsDir     = $ScriptsDirW  -replace '\\','/'
$CalObjDir      = $CalObjDirW   -replace '\\','/'
$RawDir         = $RawDirW      -replace '\\','/'
$DownDir        = $DownDirW     -replace '\\','/'
$CalDir         = $CalDirW      -replace '\\','/'

# Backfill window.
$BACKFILL_START = [datetime]$StartOverride
if ($EndOverride -and $EndOverride.Trim().Length -gt 0) {
    $BACKFILL_END = [datetime]$EndOverride
} else {
    # Default: run through today UTC.
    $BACKFILL_END = [System.DateTime]::UtcNow.Date
}

if ($BACKFILL_END -lt $BACKFILL_START) {
    throw "EndOverride cannot be earlier than StartOverride."
}

# ---------------------------------------------------------------------------
# SELECTED SENSORS ONLY
# ---------------------------------------------------------------------------

# RAMP sensors requested for generalized ozone via 2032.
$RAMP_O3_SENSORS = @(
    "2020", "2044", "2037", "2026", "2049",
    "2035", "2045", "2027", "2029", "2038",
    "2028", "2036", "2046", "2047", "2048"
)

# QAQ sensors requested for generalized ozone via MOD-00111.
$QAQ_O3_SENSORS = @(
    "MOD-00629", "MOD-00614", "MOD-00617", "MOD-00618",
    "MOD-00613", "MOD-00615", "MOD-00622", "MOD-00621"
)

# ---------------------------------------------------------------------------
# DEPLOYMENT DATES
# Only sensors in the two lists above are processed.
#
# IMPORTANT:
#   2038 and MOD-00615 were in your requested O3 lists, but were not present
#   in the deployment-date table you provided. Add them below once confirmed.
#   Until then, this script logs and skips those two sensors rather than
#   querying from the wrong date.
# ---------------------------------------------------------------------------

$DEPLOY_RAMP = @{
    "2020" = "2025-04-29"
    "2044" = "2025-06-17"
    "2037" = "2025-06-19"
    "2026" = "2025-07-14"
    "2049" = "2025-07-14"
    "2035" = "2025-07-16"
    "2045" = "2025-07-17"
    "2027" = "2025-07-29"
    "2029" = "2025-07-29"
    # "2038" = "YYYY-MM-DD"   # TODO: add confirmed deployment date
    "2028" = "2025-10-30"
    "2036" = "2025-12-12"
    "2046" = "2026-02-09"
    "2047" = "2026-02-09"
    "2048" = "2026-03-06"
}

$DEPLOY_QAQ = @{
    "MOD-00629" = "2025-07-08"
    "MOD-00614" = "2025-07-16"
    "MOD-00617" = "2025-09-03"
    "MOD-00618" = "2025-09-17"
    "MOD-00613" = "2025-09-19"
    # "MOD-00615" = "YYYY-MM-DD"   # TODO: add confirmed deployment date
    "MOD-00622" = "2025-10-30"
    "MOD-00621" = "2025-10-30"
}

# ---------------------------------------------------------------------------
# ENSURE DIRECTORIES
# ---------------------------------------------------------------------------
@(
    $RawDirW, $DownDirW, $CalDirW, $PublishDirW,
    $LogDir, $PipelineDir
) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
$LogFile = "$LogDir\backfill_$(Get-Date -f 'yyyy-MM-dd').log"

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
# HELPERS
# ---------------------------------------------------------------------------

function Invoke-External {
    param(
        [string]$Label,
        [scriptblock]$Command
    )

    Log-Info "START $Label"
    & $Command
    $exitCode = $LASTEXITCODE

    if ($null -ne $exitCode -and $exitCode -ne 0) {
        throw "$Label failed with exit code $exitCode"
    }

    Log-Info "OK $Label"
}

function Quote-R-Vector {
    param([string[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) {
        return "character(0)"
    }

    $escaped = $Values | ForEach-Object {
        "'" + ($_ -replace "'", "\\'") + "'"
    }
    return "c(" + ($escaped -join ",") + ")"
}

function Get-SensorStart {
    param(
        [string]$SensorId,
        [hashtable]$DeployTable,
        [datetime]$ChunkStart
    )

    if (-not $DeployTable.ContainsKey($SensorId)) {
        return $null
    }

    $deployDate = [datetime]$DeployTable[$SensorId]
    if ($deployDate -gt $ChunkStart) {
        return $deployDate
    }
    return $ChunkStart
}

function Get-ActiveSensorsForChunk {
    param(
        [string[]]$Sensors,
        [hashtable]$DeployTable,
        [datetime]$ChunkStart,
        [datetime]$ChunkEndExclusive
    )

    $active = @()

    foreach ($sid in $Sensors) {
        if (-not $DeployTable.ContainsKey($sid)) {
            Log-Warn "Skipping $sid because no deployment date is defined."
            continue
        }

        $deployDate = [datetime]$DeployTable[$sid]

        # Active in this chunk if deployment happens before the exclusive end.
        if ($deployDate -lt $ChunkEndExclusive) {
            $active += $sid
        }
    }

    return $active
}

function Clear-SensorCsvs {
    param([string[]]$Sensors)

    foreach ($sid in $Sensors) {
        @("$RawDirW\$sid", "$DownDirW\$sid", "$CalDirW\$sid") | ForEach-Object {
            $folder = $_
            if (Test-Path $folder) {
                Get-ChildItem "$folder\*.csv" -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        Remove-Item $_.FullName -Force
                    } catch {
                        Log-Warn "Could not delete $($_.FullName): $_"
                    }
                }
            }
        }
    }
}

function Download-RampForChunk {
    param(
        [string[]]$Sensors,
        [datetime]$ChunkStart,
        [datetime]$ChunkEndExclusive
    )

    foreach ($sid in $Sensors) {
        $sensorStart = Get-SensorStart -SensorId $sid -DeployTable $DEPLOY_RAMP -ChunkStart $ChunkStart
        if ($null -eq $sensorStart) { continue }

        $startDate = $sensorStart.ToString("yyyy-MM-dd")
        $endDate   = $ChunkEndExclusive.ToString("yyyy-MM-dd")

        Log-Info "Downloading RAMP $sid from $startDate to $endDate exclusive"
        Invoke-External "Download RAMP $sid" {
            & $PythonExe "$ScriptsDirW\RAMP_download.py" `
                --sensors  $sid `
                --start    $startDate `
                --end      $endDate `
                --out-root $RawDirW `
                --base-url "http://18.222.146.48/RAMP/v1/raw"
        }
    }
}

function Download-QaqForChunk {
    param(
        [string[]]$Sensors,
        [datetime]$ChunkStart,
        [datetime]$ChunkEndExclusive
    )

    foreach ($sid in $Sensors) {
        $sensorStart = Get-SensorStart -SensorId $sid -DeployTable $DEPLOY_QAQ -ChunkStart $ChunkStart
        if ($null -eq $sensorStart) { continue }

        $startDate = $sensorStart.ToString("yyyy-MM-dd")
        $endDate   = $ChunkEndExclusive.ToString("yyyy-MM-dd")

        Log-Info "Downloading QAQ $sid from $startDate to $endDate exclusive"
        Invoke-External "Download QAQ $sid" {
            & $PythonExe "$ScriptsDirW\QAQ_download.py" `
                --sensors  $sid `
                --start    $startDate `
                --end      $endDate `
                --out-root $RawDirW
        }
    }
}

# ---------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ---------------------------------------------------------------------------

Log-Info "Backfill starting"
Log-Info "Window: $($BACKFILL_START.ToString('yyyy-MM-dd')) to $($BACKFILL_END.ToString('yyyy-MM-dd')) inclusive"
Log-Info "RAMP O3 override model: 2032"
Log-Info "QAQ O3 override model: MOD-00111"

if (-not (Test-Path $RScriptExe)) {
    throw "Rscript.exe not found at: $RScriptExe"
}
if (-not (Test-Path $PythonExe)) {
    throw "Python executable not found at: $PythonExe"
}
if (-not (Test-Path "$ScriptsDirW\RAMP_apply_calibration.R")) {
    throw "Missing RAMP_apply_calibration.R in $ScriptsDirW"
}
if (-not (Test-Path "$ScriptsDirW\QAQ_apply_calibration.R")) {
    throw "Missing QAQ_apply_calibration.R in $ScriptsDirW"
}
if (-not (Test-Path "$CalObjDirW\2032\Calibration_Models.obj")) {
    throw "Missing RAMP generalized O3/PM calibration object: $CalObjDirW\2032\Calibration_Models.obj"
}
if (-not (Test-Path "$CalObjDirW\MOD-00111\Calibration_Models.obj")) {
    throw "Missing QAQ generalized O3 calibration object: $CalObjDirW\MOD-00111\Calibration_Models.obj"
}

# Log missing deployment dates once up front.
foreach ($sid in $RAMP_O3_SENSORS) {
    if (-not $DEPLOY_RAMP.ContainsKey($sid)) {
        Log-Warn "No deployment date for RAMP $sid; it will be skipped until added to DEPLOY_RAMP."
    }
}
foreach ($sid in $QAQ_O3_SENSORS) {
    if (-not $DEPLOY_QAQ.ContainsKey($sid)) {
        Log-Warn "No deployment date for QAQ $sid; it will be skipped until added to DEPLOY_QAQ."
    }
}

# ---------------------------------------------------------------------------
# MONTHLY BACKFILL LOOP
# ---------------------------------------------------------------------------

$cursor = [datetime]::new($BACKFILL_START.Year, $BACKFILL_START.Month, 1)

while ($cursor -le $BACKFILL_END) {
    $chunkStart = $cursor

    # Respect StartOverride if it is mid-month.
    if ($chunkStart -lt $BACKFILL_START) {
        $chunkStart = $BACKFILL_START
    }

    $nextMonth = ([datetime]::new($cursor.Year, $cursor.Month, 1)).AddMonths(1)

    # Use half-open interval [chunkStart, chunkEndExclusive).
    $globalEndExclusive = $BACKFILL_END.AddDays(1)
    if ($nextMonth -lt $globalEndExclusive) {
        $chunkEndExclusive = $nextMonth
    } else {
        $chunkEndExclusive = $globalEndExclusive
    }

    $monthStr = $cursor.ToString("yyyy-MM")

    Log-Info "====================================================================="
    Log-Info "MONTH $monthStr | $($chunkStart.ToString('yyyy-MM-dd')) to $($chunkEndExclusive.ToString('yyyy-MM-dd')) exclusive"
    Log-Info "====================================================================="

    $rampActive = Get-ActiveSensorsForChunk `
        -Sensors $RAMP_O3_SENSORS `
        -DeployTable $DEPLOY_RAMP `
        -ChunkStart $chunkStart `
        -ChunkEndExclusive $chunkEndExclusive

    $qaqActive = Get-ActiveSensorsForChunk `
        -Sensors $QAQ_O3_SENSORS `
        -DeployTable $DEPLOY_QAQ `
        -ChunkStart $chunkStart `
        -ChunkEndExclusive $chunkEndExclusive

    if (-not $rampActive -and -not $qaqActive) {
        Log-Info "No requested sensors active for $monthStr"
        $cursor = $cursor.AddMonths(1)
        continue
    }

    if ($rampActive) { Log-Info "RAMP active: $($rampActive -join ', ')" }
    if ($qaqActive)  { Log-Info "QAQ active:  $($qaqActive  -join ', ')" }

    # Clean only the requested sensors, not the full fleet.
    Clear-SensorCsvs -Sensors (@($RAMP_O3_SENSORS) + @($QAQ_O3_SENSORS))

    # -----------------------------------------------------------------------
    # 1. DOWNLOAD
    # -----------------------------------------------------------------------
    if ($rampActive) {
        Download-RampForChunk -Sensors $rampActive -ChunkStart $chunkStart -ChunkEndExclusive $chunkEndExclusive
    }

    if ($qaqActive) {
        Download-QaqForChunk -Sensors $qaqActive -ChunkStart $chunkStart -ChunkEndExclusive $chunkEndExclusive
    }

    # Prepare R vectors.
    $rampIdsR = Quote-R-Vector -Values $rampActive
    $qaqIdsR  = Quote-R-Vector -Values $qaqActive
    $rampO3R  = Quote-R-Vector -Values $RAMP_O3_SENSORS
    $qaqO3R   = Quote-R-Vector -Values $QAQ_O3_SENSORS

    # -----------------------------------------------------------------------
    # 2. JOIN AND DOWNSAMPLE
    # -----------------------------------------------------------------------
    $rJoin = @"
options(pipeline.sourced = TRUE)

"@

    if ($rampActive) {
        $rJoin += @"
source(file.path('$ScriptsDir', 'RAMP_join_downsample.R'))
ramp_join_downsample_all(
  sensor_ids = $rampIdsR,
  in_root    = '$RawDir',
  out_root   = '$DownDir',
  avg_time   = '15 min',
  overwrite  = TRUE
)

"@
    }

    if ($qaqActive) {
        $rJoin += @"
source(file.path('$ScriptsDir', 'QAQ_join_downsample.R'))
qaq_join_downsample_all(
  sensor_ids = $qaqIdsR,
  in_root    = '$RawDir',
  out_root   = '$DownDir',
  avg_time   = '15 min',
  overwrite  = TRUE
)

"@
    }

    $tmpJoin = "$PipelineDir\tmp_backfill_join.R"
    Set-Content $tmpJoin $rJoin -Encoding ASCII

    try {
        Invoke-External "Join and downsample $monthStr" {
            & $RScriptExe $tmpJoin
        }
    } finally {
        Remove-Item $tmpJoin -ErrorAction SilentlyContinue
    }

    # -----------------------------------------------------------------------
    # 3. CALIBRATE
    # -----------------------------------------------------------------------
    $rCal = @"
options(pipeline.sourced = TRUE)

"@

    if ($rampActive) {
        $rCal += @"
local({ source(file.path('$ScriptsDir', 'RAMP_apply_calibration.R')) })
ramp_apply_calibration(
  sensor_ids                       = $rampIdsR,
  generalized_model                = FALSE,
  models_root                      = '$CalObjDir',
  ozone_use_generalized_sensor_ids = $rampO3R,
  ozone_generalized_id             = '2032',
  pm_use_generalized               = TRUE,
  pm_generalized_id                = '2032',
  drop_negative_values             = FALSE,
  in_root                          = '$DownDir',
  out_root                         = '$CalDir',
  caps_core_path                   = file.path('$ScriptsDir', 'caps_core.R'),
  tz_in                            = 'UTC',
  tz_out                           = 'UTC'
)

"@
    }

    if ($qaqActive) {
        $rCal += @"
local({ source(file.path('$ScriptsDir', 'QAQ_apply_calibration.R')) })
qaq_apply_general_calibration(
  sensor_ids                       = $qaqIdsR,
  generalized_model                = FALSE,
  models_root                      = '$CalObjDir',
  ozone_use_generalized_sensor_ids = $qaqO3R,
  ozone_generalized_id             = 'MOD-00111',
  in_root                          = '$DownDir',
  out_root                         = '$CalDir',
  caps_core_path                   = file.path('$ScriptsDir', 'caps_core.R'),
  tz_in                            = 'UTC',
  tz_out                           = 'UTC'
)

"@
    }

    $tmpCal = "$PipelineDir\tmp_backfill_cal.R"
    Set-Content $tmpCal $rCal -Encoding ASCII

    try {
        Invoke-External "Calibrate $monthStr" {
            & $RScriptExe $tmpCal
        }
    } finally {
        Remove-Item $tmpCal -ErrorAction SilentlyContinue
    }

    # -----------------------------------------------------------------------
    # 4. UPLOAD TO R2
    # -----------------------------------------------------------------------
    Invoke-External "Upload to R2 $monthStr" {
        & $PythonExe "$PipelineDir\upload_to_r2.py" `
            --calibrated-dir $CalDirW `
            --publish-dir    $PublishDirW `
            --bucket         $R2Bucket `
            --endpoint       $R2Endpoint `
            --month          $monthStr
    }

    $cursor = $cursor.AddMonths(1)
}

Log-Info "Backfill complete"

# =============================================================================
# backfill.ps1  -  RAMP + QAQ, May 2025 through April 4 2026
# =============================================================================
param([string]$StartOverride = "")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
$R2Prefix       = "calibrated"

$ScriptsDir     = $ScriptsDirW  -replace '\\','/'
$CalObjDir      = $CalObjDirW   -replace '\\','/'
$RawDir         = $RawDirW      -replace '\\','/'
$DownDir        = $DownDirW     -replace '\\','/'
$CalDir         = $CalDirW      -replace '\\','/'

$BACKFILL_END   = [datetime]"2026-06-01"
$EtZone         = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")

# ---------------------------------------------------------------------------
# DEPLOYMENT DATES
# ---------------------------------------------------------------------------
$DEPLOY_RAMP = @{
    "2020"="2025-04-29"; "2021"="2025-04-29"; "2022"="2025-06-18"; "2023"="2025-10-09"
    "2024"="2025-07-14"; "2025"="2026-02-09"; "2026"="2025-07-14"; "2027"="2025-07-29"
    "2028"="2025-10-30"; "2029"="2025-07-29"; "2030"="2025-07-29"; "2031"="2026-03-06"
    "2033"="2025-07-14"; "2035"="2025-07-16"; "2036"="2025-12-12"; "2037"="2025-06-19"
    "2039"="2025-12-12"; "2040"="2025-06-17"; "2042"="2025-07-16"; "2043"="2025-07-17"
    "2044"="2025-06-17"; "2045"="2025-07-17"; "2046"="2026-02-09"; "2047"="2026-02-09"
    "2048"="2026-03-06"; "2049"="2025-07-14"
}

$DEPLOY_QAQ = @{
    "MOD-00629"="2025-07-08"; "MOD-00632"="2025-07-08"
    "MOD-00614"="2025-07-16"; "MOD-00616"="2025-07-16"
    "MOD-00617"="2025-09-03"; "MOD-00625"="2025-09-03"
    "MOD-00618"="2025-09-17"; "MOD-00631"="2025-09-17"
    "MOD-00613"="2025-09-19"; "MOD-00623"="2025-09-19"
    "MOD-00622"="2025-10-30"; "MOD-00628"="2025-10-09"
    "MOD-00621"="2025-10-30"; "MOD-00627"="2025-10-30"
    "MOD-00624"="2026-05-26"
}

$ALL_RAMP = @(
    "2020","2021","2022","2023","2024","2025","2026","2027","2028","2029","2030",
    "2031","2033","2035","2036","2037","2039","2040","2042","2043","2044",
    "2045","2046","2047","2048","2049"
)

$ALL_QAQ = @(
    "MOD-00632","MOD-00616","MOD-00625","MOD-00631","MOD-00623",
    "MOD-00628","MOD-00627","MOD-00629","MOD-00614","MOD-00617",
    "MOD-00618","MOD-00613","MOD-00622","MOD-00621","MOD-00624"
)

$LogFile = "$LogDir\backfill_$(Get-Date -f 'yyyy-MM-dd').log"
function Log-Info  { param([string]$m) $l="[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][INFO ] $m"; Write-Host $l; Add-Content $LogFile $l -Encoding UTF8 }
function Log-Error { param([string]$m) $l="[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][ERROR] $m"; Write-Host $l; Add-Content $LogFile $l -Encoding UTF8 }

Log-Info "Backfill starting"

$cursor = [datetime]"2025-05-01"
while ($cursor -le $BACKFILL_END) {
    $mStart   = $cursor
    $mEnd     = $mStart.AddMonths(1).AddDays(-1)
    if ($mEnd -gt $BACKFILL_END) { $mEnd = $BACKFILL_END }
    $monthStr = $mStart.ToString("yyyy-MM")
    $startUTC = $mStart.ToString("yyyy-MM-dd")
    $endUTC   = $mEnd.ToString("yyyy-MM-dd")
    $startET  = [System.TimeZoneInfo]::ConvertTimeFromUtc($mStart, $EtZone).ToString("yyyy-MM-dd")
    $endET    = [System.TimeZoneInfo]::ConvertTimeFromUtc($mEnd.AddDays(1), $EtZone).ToString("yyyy-MM-dd")

    if ($StartOverride -and $mStart -lt [datetime]$StartOverride) {
        Log-Info "SKIP $monthStr"
        $cursor = $cursor.AddMonths(1)
        continue
    }

    # Filter active sensors for this month
    $rampActive = $ALL_RAMP | Where-Object { $DEPLOY_RAMP[$_] -and [datetime]$DEPLOY_RAMP[$_] -le $mEnd }
    $qaqActive  = $ALL_QAQ  | Where-Object { $DEPLOY_QAQ[$_]  -and [datetime]$DEPLOY_QAQ[$_]  -le $mEnd }

    if (-not $rampActive -and -not $qaqActive) {
        Log-Info "No sensors active for $monthStr"
        $cursor = $cursor.AddMonths(1)
        continue
    }

    Log-Info "--- $monthStr $startUTC to $endUTC ---"
    if ($rampActive) { Log-Info "RAMP: $($rampActive -join ', ')" }
    if ($qaqActive)  { Log-Info "QAQ:  $($qaqActive  -join ', ')" }

    # Combine all active sensors for cleanup
    $allActive = @()
    if ($rampActive) { $allActive += $rampActive }
    if ($qaqActive)  { $allActive += $qaqActive }

    # 0. Clean raw + downsampled + calibrated for active sensors
    Log-Info "Cleaning data folders..."
    foreach ($sid in $allActive) {
        @("$RawDirW\$sid", "$DownDirW\$sid", "$CalDirW\$sid") | ForEach-Object {
            $folder = $_
            if (Test-Path $folder) {
                Get-ChildItem "$folder\*.csv" -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        takeown /F $_.FullName /A | Out-Null
                        icacls $_.FullName /grant Administrators:F | Out-Null
                        Remove-Item $_.FullName -Force
                    } catch {
                        Log-Warn "Could not delete $($_.FullName): $_"
                    }
                }
            }
        }
    }

    # 1. Download RAMP
    if ($rampActive) {
        $rampIds = "'" + ($rampActive -join "','") + "'"
        Log-Info "Downloading RAMP..."
        try {
            & $PythonExe "$ScriptsDirW\RAMP_download.py" --sensors $rampActive --start $startET --end $endET --out-root $RawDirW --base-url "http://18.222.146.48/RAMP/v1/raw"
            Log-Info "OK RAMP download"
        } catch {
            Log-Error "FAILED RAMP download - $_"
        }
    }

    # 2. Download QAQ
    if ($qaqActive) {
        $qaqIds = "'" + ($qaqActive -join "','") + "'"
        Log-Info "Downloading QAQ..."
        try {
            & $PythonExe "$ScriptsDirW\QAQ_download.py" --sensors $qaqActive --start $startUTC --end $endUTC --out-root $RawDirW
            Log-Info "OK QAQ download"
        } catch {
            Log-Error "FAILED QAQ download - $_"
        }
    }

    # 3. Join & downsample
    $rJoin = "options(pipeline.sourced=TRUE)" + [Environment]::NewLine
    if ($rampActive) {
        $rJoin += "source(file.path('$ScriptsDir','RAMP_join_downsample.R'))" + [Environment]::NewLine
        $rJoin += "ramp_join_downsample_all(sensor_ids=c($rampIds),in_root='$RawDir',out_root='$DownDir',avg_time='15 min',overwrite=TRUE)" + [Environment]::NewLine
    }
    if ($qaqActive) {
        $rJoin += "source(file.path('$ScriptsDir','QAQ_join_downsample.R'))" + [Environment]::NewLine
        $rJoin += "qaq_join_downsample_all(sensor_ids=c($qaqIds),in_root='$RawDir',out_root='$DownDir',avg_time='15 min',overwrite=TRUE)" + [Environment]::NewLine
    }
    $tmp = "$PipelineDir\tmp_backfill_join.R"
    Set-Content $tmp $rJoin -Encoding ASCII
    Log-Info "Joining..."
    try { & $RScriptExe $tmp; Log-Info "OK Join" } catch { Log-Error "FAILED Join - $_" }
    Remove-Item $tmp -ErrorAction SilentlyContinue

    # 4. Calibrate
    $rCal = "options(pipeline.sourced=TRUE)" + [Environment]::NewLine
    if ($rampActive) {
        $rCal += "local({source(file.path('$ScriptsDir','RAMP_apply_calibration.R'))})" + [Environment]::NewLine
        $rCal += "ramp_apply_calibration(sensor_ids=c($rampIds),generalized_model=FALSE,models_root='$CalObjDir',pm_use_generalized=TRUE,pm_generalized_id='2032',drop_negative_values=FALSE,in_root='$DownDir',out_root='$CalDir',caps_core_path=file.path('$ScriptsDir','caps_core.R'),tz_in='UTC',tz_out='UTC')" + [Environment]::NewLine
    }
    if ($qaqActive) {
        $rCal += "local({source(file.path('$ScriptsDir','QAQ_apply_calibration.R'))})" + [Environment]::NewLine
        $rCal += "qaq_apply_general_calibration(sensor_ids=c($qaqIds),generalized_model=FALSE,models_root='$CalObjDir',generalized_id='MOD-00617',in_root='$DownDir',out_root='$CalDir',caps_core_path=file.path('$ScriptsDir','caps_core.R'),tz_in='UTC',tz_out='UTC')" + [Environment]::NewLine
    }
    $tmp = "$PipelineDir\tmp_backfill_cal.R"
    Set-Content $tmp $rCal -Encoding ASCII
    Log-Info "Calibrating..."
    try { & $RScriptExe $tmp; Log-Info "OK Calibrate" } catch { Log-Error "FAILED Calibrate - $_" }
    Remove-Item $tmp -ErrorAction SilentlyContinue

    # 5. Upload to R2
    Log-Info "Uploading..."
    try {
        & $PythonExe "$PipelineDir\upload_to_r2.py" --calibrated-dir $CalDirW --publish-dir $PublishDirW --bucket $R2Bucket --endpoint $R2Endpoint --month $monthStr
        Log-Info "OK Upload"
    } catch {
        Log-Error "FAILED Upload - $_"
    }

    $cursor = $cursor.AddMonths(1)
}

Log-Info "Backfill complete"

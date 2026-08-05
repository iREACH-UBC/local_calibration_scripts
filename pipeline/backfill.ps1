# =============================================================================
# backfill.ps1
#
# Backfills:
#   - July 1-31, 2026
#   - August 1-2, 2026
#
# RAMP endpoint behaviour:
#   The first four UTC hours of day X are stored in endpoint file X-1.
#   Therefore, RAMP downloads begin one endpoint day before each target period.
# =============================================================================

param(
    [string]$StartOverride = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

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

# R paths use forward slashes
$ScriptsDir     = $ScriptsDirW -replace '\\', '/'
$CalObjDir      = $CalObjDirW  -replace '\\', '/'
$RawDir         = $RawDirW     -replace '\\', '/'
$DownDir        = $DownDirW    -replace '\\', '/'
$CalDir         = $CalDirW     -replace '\\', '/'

# Backfill July 2026 and August 1-2, 2026
$BACKFILL_START = [datetime]"2026-07-01"
$BACKFILL_END   = [datetime]"2026-08-02"

# -----------------------------------------------------------------------------
# Deployment dates
# -----------------------------------------------------------------------------

$DEPLOY_RAMP = @{
    "2020" = "2025-04-29"
    "2021" = "2025-04-29"
    "2022" = "2025-06-18"
    "2023" = "2025-10-09"
    "2024" = "2025-07-14"
    "2025" = "2026-02-09"
    "2026" = "2025-07-14"
    "2027" = "2025-07-29"
    "2028" = "2025-10-30"
    "2029" = "2025-07-29"
    "2030" = "2025-07-29"
    "2031" = "2026-03-06"
    "2033" = "2025-07-14"
    "2035" = "2025-07-16"
    "2036" = "2025-12-12"
    "2037" = "2025-06-19"
    "2039" = "2025-12-12"
    "2040" = "2025-06-17"
    "2042" = "2025-07-16"
    "2043" = "2025-07-17"
    "2044" = "2025-06-17"
    "2045" = "2025-07-17"
    "2046" = "2026-02-09"
    "2047" = "2026-02-09"
    "2048" = "2026-03-06"
    "2049" = "2025-07-14"
}

$DEPLOY_QAQ = @{
    "MOD-00629" = "2025-07-08"
    "MOD-00632" = "2025-07-08"
    "MOD-00614" = "2025-07-16"
    "MOD-00616" = "2025-07-16"
    "MOD-00617" = "2025-09-03"
    "MOD-00625" = "2025-09-03"
    "MOD-00618" = "2025-09-17"
    "MOD-00631" = "2025-09-17"
    "MOD-00613" = "2025-09-19"
    "MOD-00623" = "2025-09-19"
    "MOD-00622" = "2025-10-30"
    "MOD-00628" = "2025-10-09"
    "MOD-00621" = "2025-10-30"
    "MOD-00627" = "2025-10-30"
    "MOD-00624" = "2026-05-26"
    "MOD-00620" = "2026-07-22"
}

$ALL_RAMP = @(
    "2020", "2021", "2022", "2023", "2024", "2025", "2026",
    "2027", "2028", "2029", "2030", "2031", "2033", "2035",
    "2036", "2037", "2039", "2040", "2042", "2043", "2044",
    "2045", "2046", "2047", "2048", "2049"
)

$ALL_QAQ = @(
    "MOD-00632", "MOD-00616", "MOD-00625", "MOD-00631",
    "MOD-00623", "MOD-00628", "MOD-00627", "MOD-00629",
    "MOD-00614", "MOD-00617", "MOD-00618", "MOD-00613",
    "MOD-00622", "MOD-00621", "MOD-00624", "MOD-00620"
)

# -----------------------------------------------------------------------------
# Directory and executable checks
# -----------------------------------------------------------------------------

$RequiredExecutables = @(
    $PythonExe,
    $RScriptExe
)

foreach ($Executable in $RequiredExecutables) {
    if (-not (Test-Path $Executable)) {
        throw "Required executable not found: $Executable"
    }
}

$RequiredScripts = @(
    "$ScriptsDirW\RAMP_download.py",
    "$ScriptsDirW\QAQ_download.py",
    "$ScriptsDirW\RAMP_join_downsample.R",
    "$ScriptsDirW\QAQ_join_downsample.R",
    "$ScriptsDirW\RAMP_apply_calibration.R",
    "$ScriptsDirW\QAQ_apply_calibration.R",
    "$ScriptsDirW\caps_core.R",
    "$PipelineDir\upload_to_r2.py"
)

foreach ($Script in $RequiredScripts) {
    if (-not (Test-Path $Script)) {
        throw "Required script not found: $Script"
    }
}

$RequiredDirectories = @(
    $RawDirW,
    $DownDirW,
    $CalDirW,
    $PublishDirW,
    $LogDir,
    $PipelineDir
)

foreach ($Directory in $RequiredDirectories) {
    if (-not (Test-Path $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

$LogFile = "$LogDir\backfill_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )

    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Level] $Message"
    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line -Encoding UTF8
}

function Log-Info {
    param([string]$Message)
    Write-Log -Level "INFO " -Message $Message
}

function Log-Warn {
    param([string]$Message)
    Write-Log -Level "WARN " -Message $Message
}

function Log-Error {
    param([string]$Message)
    Write-Log -Level "ERROR" -Message $Message
}

# -----------------------------------------------------------------------------
# Native-command wrapper
# -----------------------------------------------------------------------------

function Invoke-Step {
    param(
        [string]$Label,
        [scriptblock]$Command
    )

    Log-Info "START $Label"

    try {
        & $Command

        $ExitCode = $LASTEXITCODE

        if ($null -ne $ExitCode -and $ExitCode -ne 0) {
            throw "$Label exited with code $ExitCode"
        }

        Log-Info "OK $Label"
    }
    catch {
        Log-Error "FAILED $Label - $($_.Exception.Message)"
        throw
    }
}

# -----------------------------------------------------------------------------
# Start override
# -----------------------------------------------------------------------------

$ParsedStartOverride = $null

if ($StartOverride) {
    try {
        $ParsedStartOverride = [datetime]$StartOverride
    }
    catch {
        throw "Invalid StartOverride '$StartOverride'. Use YYYY-MM-DD."
    }
}

# -----------------------------------------------------------------------------
# Backfill
# -----------------------------------------------------------------------------

Log-Info "Backfill starting"
Log-Info "Backfill period: $($BACKFILL_START.ToString('yyyy-MM-dd')) to $($BACKFILL_END.ToString('yyyy-MM-dd'))"

$Cursor = $BACKFILL_START

while ($Cursor -le $BACKFILL_END) {
    $MonthStart = $Cursor
    $MonthEnd   = $MonthStart.AddMonths(1).AddDays(-1)

    if ($MonthEnd -gt $BACKFILL_END) {
        $MonthEnd = $BACKFILL_END
    }

    $MonthString = $MonthStart.ToString("yyyy-MM")

    if ($ParsedStartOverride -and $MonthStart -lt $ParsedStartOverride) {
        Log-Info "SKIP $MonthString because of StartOverride"
        $Cursor = $Cursor.AddMonths(1)
        continue
    }

    # QAQ uses the actual requested UTC dates.
    $StartUTC = $MonthStart.ToString("yyyy-MM-dd")
    $EndUTC   = $MonthEnd.ToString("yyyy-MM-dd")

    # The RAMP endpoint file for day X-1 contains the first four UTC hours
    # of day X during daylight saving time. Request one extra endpoint day.
    $StartRAMP = $MonthStart.AddDays(-1).ToString("yyyy-MM-dd")
    $EndRAMP   = $MonthEnd.ToString("yyyy-MM-dd")

    # Sensors deployed by the end of this period
    $RampActive = @(
        $ALL_RAMP | Where-Object {
            $DEPLOY_RAMP[$_] -and
            [datetime]$DEPLOY_RAMP[$_] -le $MonthEnd
        }
    )

    $QaqActive = @(
        $ALL_QAQ | Where-Object {
            $DEPLOY_QAQ[$_] -and
            [datetime]$DEPLOY_QAQ[$_] -le $MonthEnd
        }
    )

    if ($RampActive.Count -eq 0 -and $QaqActive.Count -eq 0) {
        Log-Info "No sensors active for $MonthString"
        $Cursor = $Cursor.AddMonths(1)
        continue
    }

    Log-Info "------------------------------------------------------------"
    Log-Info "$MonthString target UTC period: $StartUTC to $EndUTC"
    Log-Info "$MonthString RAMP endpoint period: $StartRAMP to $EndRAMP"

    if ($RampActive.Count -gt 0) {
        Log-Info "RAMP sensors: $($RampActive -join ', ')"
    }

    if ($QaqActive.Count -gt 0) {
        Log-Info "QAQ sensors: $($QaqActive -join ', ')"
    }

    $AllActive = @($RampActive) + @($QaqActive)

    # -------------------------------------------------------------------------
    # 0. Clean temporary backfill data
    # -------------------------------------------------------------------------

    Log-Info "Cleaning temporary data folders for $MonthString"

    foreach ($SensorID in $AllActive) {
        $SensorDirectories = @(
            "$RawDirW\$SensorID",
            "$DownDirW\$SensorID",
            "$CalDirW\$SensorID"
        )

        foreach ($SensorDirectory in $SensorDirectories) {
            if (-not (Test-Path $SensorDirectory)) {
                continue
            }

            Get-ChildItem `
                -Path "$SensorDirectory\*.csv" `
                -File `
                -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try {
                        Remove-Item -Path $_.FullName -Force
                    }
                    catch {
                        Log-Warn "Normal deletion failed for $($_.FullName); attempting ownership reset"

                        try {
                            takeown.exe /F $_.FullName /A | Out-Null
                            icacls.exe $_.FullName /grant "Administrators:F" | Out-Null
                            Remove-Item -Path $_.FullName -Force
                        }
                        catch {
                            throw "Could not delete $($_.FullName): $($_.Exception.Message)"
                        }
                    }
                }
        }
    }

    # -------------------------------------------------------------------------
    # 1. Download RAMP
    # -------------------------------------------------------------------------

    if ($RampActive.Count -gt 0) {
        Invoke-Step "RAMP download for $MonthString" {
            & $PythonExe "$ScriptsDirW\RAMP_download.py" `
                --sensors $RampActive `
                --start $StartRAMP `
                --end $EndRAMP `
                --out-root $RawDirW `
                --base-url "http://18.222.146.48/RAMP/v1/raw"
        }
    }

    # -------------------------------------------------------------------------
    # 2. Download QAQ
    # -------------------------------------------------------------------------

    if ($QaqActive.Count -gt 0) {
        Invoke-Step "QAQ download for $MonthString" {
            & $PythonExe "$ScriptsDirW\QAQ_download.py" `
                --sensors $QaqActive `
                --start $StartUTC `
                --end $EndUTC `
                --out-root $RawDirW
        }
    }

    # -------------------------------------------------------------------------
    # 3. Join and downsample
    # -------------------------------------------------------------------------

    $RJoin = "options(pipeline.sourced=TRUE)" + [Environment]::NewLine

    if ($RampActive.Count -gt 0) {
        $RampIDs = "'" + ($RampActive -join "','") + "'"

        $RJoin +=
            "source(file.path('$ScriptsDir','RAMP_join_downsample.R'))" +
            [Environment]::NewLine

        $RJoin +=
            "ramp_join_downsample_all(" +
            "sensor_ids=c($RampIDs)," +
            "in_root='$RawDir'," +
            "out_root='$DownDir'," +
            "avg_time='15 min'," +
            "overwrite=TRUE)" +
            [Environment]::NewLine
    }

    if ($QaqActive.Count -gt 0) {
        $QaqIDs = "'" + ($QaqActive -join "','") + "'"

        $RJoin +=
            "source(file.path('$ScriptsDir','QAQ_join_downsample.R'))" +
            [Environment]::NewLine

        $RJoin +=
            "qaq_join_downsample_all(" +
            "sensor_ids=c($QaqIDs)," +
            "in_root='$RawDir'," +
            "out_root='$DownDir'," +
            "avg_time='15 min'," +
            "overwrite=TRUE)" +
            [Environment]::NewLine
    }

    $TemporaryJoinScript = "$PipelineDir\tmp_backfill_join.R"
    Set-Content -Path $TemporaryJoinScript -Value $RJoin -Encoding ASCII

    try {
        Invoke-Step "Join and downsample for $MonthString" {
            & $RScriptExe $TemporaryJoinScript
        }
    }
    finally {
        Remove-Item -Path $TemporaryJoinScript -Force -ErrorAction SilentlyContinue
    }

    # -------------------------------------------------------------------------
    # 4. Calibrate
    # -------------------------------------------------------------------------

    $RCalibration = "options(pipeline.sourced=TRUE)" + [Environment]::NewLine

    if ($RampActive.Count -gt 0) {
        $RampIDs = "'" + ($RampActive -join "','") + "'"

        $RCalibration +=
            "local({source(file.path('$ScriptsDir','RAMP_apply_calibration.R'))})" +
            [Environment]::NewLine

        $RCalibration +=
            "ramp_apply_calibration(" +
            "sensor_ids=c($RampIDs)," +
            "generalized_model=FALSE," +
            "models_root='$CalObjDir'," +
            "pm_use_generalized=TRUE," +
            "pm_generalized_id='2032'," +
            "drop_negative_values=FALSE," +
            "in_root='$DownDir'," +
            "out_root='$CalDir'," +
            "caps_core_path=file.path('$ScriptsDir','caps_core.R')," +
            "tz_in='UTC'," +
            "tz_out='UTC')" +
            [Environment]::NewLine
    }

    if ($QaqActive.Count -gt 0) {
        $QaqIDs = "'" + ($QaqActive -join "','") + "'"

        $RCalibration +=
            "local({source(file.path('$ScriptsDir','QAQ_apply_calibration.R'))})" +
            [Environment]::NewLine

        $RCalibration +=
            "qaq_apply_general_calibration(" +
            "sensor_ids=c($QaqIDs)," +
            "generalized_model=FALSE," +
            "models_root='$CalObjDir'," +
            "generalized_id='MOD-00617'," +
            "in_root='$DownDir'," +
            "out_root='$CalDir'," +
            "caps_core_path=file.path('$ScriptsDir','caps_core.R')," +
            "tz_in='UTC'," +
            "tz_out='UTC')" +
            [Environment]::NewLine
    }

    $TemporaryCalibrationScript = "$PipelineDir\tmp_backfill_cal.R"
    Set-Content -Path $TemporaryCalibrationScript -Value $RCalibration -Encoding ASCII

    try {
        Invoke-Step "Calibration for $MonthString" {
            & $RScriptExe $TemporaryCalibrationScript
        }
    }
    finally {
        Remove-Item -Path $TemporaryCalibrationScript -Force -ErrorAction SilentlyContinue
    }

    # -------------------------------------------------------------------------
    # 5. Upload daily files and merge monthly files
    # -------------------------------------------------------------------------

    Invoke-Step "R2 upload for $MonthString" {
        & $PythonExe "$PipelineDir\upload_to_r2.py" `
            --calibrated-dir $CalDirW `
            --publish-dir $PublishDirW `
            --bucket $R2Bucket `
            --endpoint $R2Endpoint `
            --month $MonthString
    }

    Log-Info "Completed $MonthString"
    $Cursor = $Cursor.AddMonths(1)
}

Log-Info "Backfill complete"
Log-Info "Log file: $LogFile"
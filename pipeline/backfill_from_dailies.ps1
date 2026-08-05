# iREACH - Backfill monthly R2 files from existing daily CSVs
# Downloads daily CSVs from R2 for the specified months and merges
# them into the monthly files. Much faster than re-running the full pipeline.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ROOT        = "C:\ProgramData\iREACH"
$PythonExe   = "C:\ProgramData\Python\bin\python.exe"
$PipelineDir = "$ROOT\pipeline"
$PublishDir  = "$ROOT\backfill\publish"
$CalDir      = "$ROOT\backfill\calibrated_from_dailies"
$LogDir      = "$ROOT\logs"
$R2Bucket    = "lcs-calibrated-data"
$R2Endpoint  = "https://bfde061b9c815bbce1c08766ebac283d.r2.cloudflarestorage.com"

$MONTHS = @("2026-06", "2026-07")

$LogFile = "$LogDir\backfill_dailies_$(Get-Date -f 'yyyy-MM-dd').log"
function Write-Log {
    param([string]$Level, [string]$Msg)
    $line = "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][$Level] $Msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
function Log-Info  { param([string]$m) Write-Log "INFO " $m }
function Log-Error { param([string]$m) Write-Log "ERROR" $m }

# Ensure output dirs exist
New-Item -ItemType Directory -Path $CalDir   -Force | Out-Null
New-Item -ItemType Directory -Path $PublishDir -Force | Out-Null

Log-Info "Backfill from dailies starting for: $($MONTHS -join ', ')"

# Configure rclone r2 remote
Log-Info "Configuring rclone..."
rclone config create r2 s3 provider Cloudflare `
    access_key_id     $env:R2_ACCESS_KEY_ID `
    secret_access_key $env:R2_SECRET_ACCESS_KEY `
    endpoint          $R2Endpoint 2>&1 | Out-Null

foreach ($month in $MONTHS) {
    Log-Info "--- Downloading daily CSVs for $month ---"

    # Download all daily CSVs for this month from R2 into CalDir/<sensor_id>/
    # R2 structure: daily/<sensor_id>/<yyyy-MM>/<sensor_id>_<yyyy_MM_dd>.csv
    rclone copy "r2:$R2Bucket/daily" $CalDir `
        --include "/*/$month/*.csv" `
        --progress 2>&1

    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Log-Error "rclone download failed for $month (exit $LASTEXITCODE)"
        continue
    }
    Log-Info "Download complete for $month"

    # Move files from <sensor>/<yyyy-MM>/<file>.csv to <sensor>/<file>.csv
    # so upload_to_r2.py can find them (it expects flat sensor dirs)
    Get-ChildItem "$CalDir\*\$month\*.csv" -Recurse | ForEach-Object {
        $dest = "$CalDir\$($_.Directory.Parent.Name)\$($_.Name)"
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item $_.FullName $dest -Force
    }

    Log-Info "Merging into monthly R2 file for $month..."
    try {
        & $PythonExe "$PipelineDir\upload_to_r2.py" `
            --calibrated-dir $CalDir `
            --publish-dir    $PublishDir `
            --bucket         $R2Bucket `
            --endpoint       $R2Endpoint `
            --month          $month
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Log-Error "upload_to_r2.py failed for $month (exit $LASTEXITCODE)"
        } else {
            Log-Info "OK monthly merge for $month"
        }
    } catch {
        Log-Error "upload_to_r2.py error for $month`: $_"
    }
}

Log-Info "Backfill from dailies complete"

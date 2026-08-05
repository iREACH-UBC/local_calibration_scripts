# iREACH LCS Pipeline - Monthly R2 Merge
# Runs nightly at 4am via Task Scheduler (SYSTEM account).
# Downloads existing monthly CSVs from R2, merges in the latest calibrated
# rows, and re-uploads. Keeps monthly files complete without slowing down
# the 15-minute pipeline runs.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ROOT = "C:\ProgramData\iREACH"

$CFG = @{
    PipelineDir   = "$ROOT\pipeline"
    CalibratedDir = "$ROOT\data\calibrated"
    PublishDir    = "$ROOT\data\publish"
    PythonExe     = "C:\ProgramData\Python\bin\python.exe"
    R2Bucket      = "lcs-calibrated-data"
    R2Endpoint    = "https://bfde061b9c815bbce1c08766ebac283d.r2.cloudflarestorage.com"
    LogDir        = "$ROOT\logs"
}

# Ensure log directory exists
if (-not (Test-Path $CFG.LogDir)) { New-Item -ItemType Directory -Path $CFG.LogDir -Force | Out-Null }

$LogFile = "$($CFG.LogDir)\monthly_merge_$(Get-Date -f 'yyyy-MM-dd').log"

function Write-Log {
    param([string]$Level, [string]$Msg)
    $line = "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][$Level] $Msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
function Log-Info  { param([string]$m) Write-Log "INFO " $m }
function Log-Error { param([string]$m) Write-Log "ERROR" $m }

$Month = Get-Date -Format "yyyy-MM"

# Sanity checks — write directly to log file in case Write-Log itself fails
if (-not (Test-Path $CFG.PythonExe)) {
    Add-Content $LogFile "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][ERROR] Python not found: $($CFG.PythonExe)" -Encoding UTF8
    exit 1
}
$UploadScript = "$($CFG.PipelineDir)\upload_to_r2.py"
if (-not (Test-Path $UploadScript)) {
    Add-Content $LogFile "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][ERROR] upload_to_r2.py not found: $UploadScript" -Encoding UTF8
    exit 1
}

Log-Info "Monthly merge starting for $Month"

try {
    $PythonOutput = & $CFG.PythonExe $UploadScript `
        --calibrated-dir $CFG.CalibratedDir `
        --publish-dir    $CFG.PublishDir `
        --bucket         $CFG.R2Bucket `
        --endpoint       $CFG.R2Endpoint `
        --month          $Month 2>&1

    $PythonExitCode = $LASTEXITCODE

    foreach ($Line in $PythonOutput) {
        Write-Log "PY   " "$Line"
    }

    if ($PythonExitCode -ne 0) {
        Log-Error "upload_to_r2.py failed (exit $PythonExitCode)"
        exit 1
    }

    Log-Info "Monthly merge complete"
} catch {
    Log-Error "Monthly merge failed: $_"
    exit 1
}
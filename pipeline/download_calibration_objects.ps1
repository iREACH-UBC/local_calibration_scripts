Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ROOT       = "C:\ProgramData\iREACH"
$CalObjDir  = "$ROOT\calibration_objects"
$R2Endpoint = "https://bfde061b9c815bbce1c08766ebac283d.r2.cloudflarestorage.com"
$LogFile    = "$ROOT\logs\download_cal_objects_$(Get-Date -f 'yyyy-MM-dd').log"
function Log-Info  { param([string]$m) $l="[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][INFO ] $m"; Write-Host $l; Add-Content $LogFile $l -Encoding UTF8 }
function Log-Error { param([string]$m) $l="[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][ERROR] $m"; Write-Host $l; Add-Content $LogFile $l -Encoding UTF8 }
Log-Info "Configuring rclone..."
rclone config create r2 s3 provider Cloudflare "access_key_id" $env:R2_ACCESS_KEY_ID "secret_access_key" $env:R2_SECRET_ACCESS_KEY "endpoint" $R2Endpoint 2>&1 | Out-Null
Log-Info "Downloading calibration objects..."
rclone copy "r2:outdoor-calibrations" $CalObjDir --include "*/Calibration_Models.obj" --progress
$n = (Get-ChildItem "$CalObjDir\*\Calibration_Models.obj" -ErrorAction SilentlyContinue).Count
Log-Info "Done - $n objects downloaded"
if ($n -eq 0) { Log-Error "No objects found - check credentials"; exit 1 }

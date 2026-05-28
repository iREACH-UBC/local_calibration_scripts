# =============================================================================
# install_task.ps1
# Run ONCE as Administrator to register the pipeline as a scheduled task.
# The task runs as SYSTEM every 15 minutes, starting at midnight, every day.
# =============================================================================

#Requires -RunAsAdministrator

$TaskName   = "iREACH_LCS_Pipeline"
$ScriptPath = "C:\ProgramData\iREACH\pipeline\run_pipeline.ps1"

$PSExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$Args  = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File " + $ScriptPath

# Remove existing task if present
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed existing task: $TaskName"
}

# Action
$Action = New-ScheduledTaskAction `
    -Execute  $PSExe `
    -Argument $Args `
    -WorkingDirectory "C:\ProgramData\iREACH\pipeline"

# Trigger: daily at midnight, repeat every 15 minutes
$Trigger = New-ScheduledTaskTrigger -Daily -At "00:00"
$Trigger.Repetition = (New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 15) -Once -At "00:00").Repetition

# Run as SYSTEM
$Principal = New-ScheduledTaskPrincipal `
    -UserId    "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel  Highest

# Settings
$Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit      (New-TimeSpan -Minutes 14) `
    -MultipleInstances       IgnoreNew `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable `
    -WakeToRun:$false

# Register
Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $Action `
    -Trigger     $Trigger `
    -Principal   $Principal `
    -Settings    $Settings `
    -Description "iREACH LCS data pipeline - downloads, calibrates, publishes every 15 min" `
    -Force

Write-Host ""
Write-Host "Task registered successfully." -ForegroundColor Green
Write-Host "It will run as SYSTEM every 15 minutes."
Write-Host ""
Write-Host "To run it immediately:"
Write-Host "    Start-ScheduledTask -TaskName iREACH_LCS_Pipeline"
Write-Host ""
Write-Host "To check last run status:"
Write-Host "    Get-ScheduledTaskInfo -TaskName iREACH_LCS_Pipeline"
Write-Host ""
Write-Host "To uninstall:"
Write-Host "    Unregister-ScheduledTask -TaskName iREACH_LCS_Pipeline -Confirm:false"

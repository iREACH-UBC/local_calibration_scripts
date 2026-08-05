$git = "C:\Program Files\Git\cmd\git.exe"
$log = "C:\ProgramData\iREACH\logs\git_system_push_dryrun.log"

"=== Git SYSTEM push dry-run $(Get-Date) ===" | Out-File $log -Encoding utf8
"Identity: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" | Out-File $log -Append

$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "never"
$env:GCM_GUI_PROMPT = "0"
$env:GIT_TRACE = "1"
$env:GIT_CURL_VERBOSE = "1"

$repos = @(
  "C:\ProgramData\iREACH\output",
  "C:\ProgramData\iREACH\elusive_output"
)

foreach ($repo in $repos) {
    "`n=== $repo ===" | Out-File $log -Append
    & $git -C $repo push --dry-run origin main 2>&1 | Out-File $log -Append
    "Exit code: $LASTEXITCODE" | Out-File $log -Append
}

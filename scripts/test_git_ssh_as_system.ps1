$git = "C:\Program Files\Git\cmd\git.exe"
$log = "C:\ProgramData\iREACH\logs\git_system_ssh_push_dryrun.log"

"=== Git SYSTEM SSH push dry-run $(Get-Date) ===" | Out-File $log -Encoding utf8
"Identity: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" | Out-File $log -Append

$env:GIT_TERMINAL_PROMPT = "0"
$env:GIT_SSH_COMMAND = 'ssh -F C:/ProgramData/iREACH/ssh/config'

$repos = @(
  "C:\ProgramData\iREACH\output",
  "C:\ProgramData\iREACH\elusive_output"
)

foreach ($repo in $repos) {
    "`n=== $repo ===" | Out-File $log -Append
    & $git -C $repo push --dry-run origin main 2>&1 | Out-File $log -Append
    "Exit code: $LASTEXITCODE" | Out-File $log -Append
}

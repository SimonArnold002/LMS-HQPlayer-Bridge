# Install hqrestart on Windows as a scheduled task.
#
#   .\install.ps1              HQPlayer runs as an APP: the webhook runs as you,
#                              at logon, in your desktop session
#   .\install.ps1 -System      HQPlayer runs as a Windows SERVICE: the webhook runs
#                              as SYSTEM at boot (run this from an admin PowerShell)
#   .\install.ps1 -Uninstall   (add -System for the system one)
#
# Needs Python 3.7+ on PATH (python.org installer, "Add to PATH").
param([switch]$System, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$task = 'hqrestart'
if ($System) { $dir = Join-Path $env:ProgramData 'hqrestart' }
else         { $dir = Join-Path $env:LOCALAPPDATA 'hqrestart' }

Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
if ($Uninstall) { "removed task $task (config left in $dir)"; return }

$py = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command python.exe -ErrorAction Stop).Source }

New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'hqrestart.py') (Join-Path $dir 'hqrestart.py') -Force
$cfg = Join-Path $dir 'hqrestart.json'

$action   = New-ScheduledTaskAction -Execute $py -Argument "`"$dir\hqrestart.py`" `"$cfg`"" -WorkingDirectory $dir
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
if ($System) {
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
} else {
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
}
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
Start-ScheduledTask -TaskName $task

$port = 8090
for ($i = 0; $i -lt 20 -and -not (Test-Path $cfg); $i++) { Start-Sleep -Milliseconds 500 }
$token = (Get-Content $cfg -Raw | ConvertFrom-Json).token
New-NetFirewallRule -DisplayName 'hqrestart' -Direction Inbound -Protocol TCP -LocalPort $port `
    -Action Allow -Profile Private -ErrorAction SilentlyContinue | Out-Null
"installed. config: $cfg"
"token:   $token"
"test:    curl -H `"Authorization: Bearer $token`" http://$($env:COMPUTERNAME):$port/status"

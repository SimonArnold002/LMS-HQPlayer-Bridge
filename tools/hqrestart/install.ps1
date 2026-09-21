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
if (-not (Get-NetFirewallRule -DisplayName 'hqrestart' -ErrorAction SilentlyContinue)) {
    # only once: a re-install must not stack duplicate rules
    New-NetFirewallRule -DisplayName 'hqrestart' -Direction Inbound -Protocol TCP -LocalPort $port `
        -Action Allow -Profile Private -ErrorAction SilentlyContinue | Out-Null
}
# Creating the rule needs an admin PowerShell; without it the helper runs but
# LMS may never reach it, and the Restart row simply never appears. Say so.
if (-not (Get-NetFirewallRule -DisplayName 'hqrestart' -ErrorAction SilentlyContinue)) {
    Write-Warning ("No firewall rule for port $port - LMS may not be able to reach the helper. " +
                   "From an ADMIN PowerShell run:`n  New-NetFirewallRule -DisplayName hqrestart " +
                   "-Direction Inbound -Protocol TCP -LocalPort $port -Action Allow -Profile Private")
}
# The token is written by the helper on its first start, so it is read LAST and
# never fatally: with ErrorActionPreference 'Stop' a config that is not there yet
# would otherwise abort the script, losing the firewall rule and every line below
# and leaving a working install looking like a failed one.
$token = $null
for ($i = 0; $i -lt 20 -and -not (Test-Path $cfg); $i++) { Start-Sleep -Milliseconds 500 }
try { $token = (Get-Content $cfg -Raw -ErrorAction Stop | ConvertFrom-Json).token } catch { }

"installed. config: $cfg"
"log:     $(Join-Path $dir 'hqrestart.log')"
if ($token) {
    "token:   $token"
    "test:    curl -H `"Authorization: Bearer $token`" http://$($env:COMPUTERNAME):$port/status"
} else {
    Write-Warning ("The helper has not written its config yet, so there is no token to show. " +
                   "It is generated on first start - read it from $cfg, or check the log above. " +
                   "Check Python 3.7+ is on PATH if the file never appears.")
}

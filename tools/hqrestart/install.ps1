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

$pyw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
$pyc = (Get-Command python.exe  -ErrorAction SilentlyContinue).Source
if (-not $pyw -and -not $pyc) {
    throw "Python not found on PATH. Install Python 3.7+ from python.org with 'Add to PATH' ticked."
}
# 3.7 is needed for ThreadingHTTPServer: an older one fails at IMPORT, before
# the helper can log anything, and the task would be restarted for ever. Ask
# python.exe for the version - pythonw.exe has no console, so it prints nowhere.
if ($pyc) { $ver = (& $pyc -c "import sys; print('%d.%d' % sys.version_info[:2])") }
else      { $ver = (Get-Item $pyw).VersionInfo.ProductVersion }   # e.g. 3.11.5
if ($ver -match '^(\d+)\.(\d+)' -and [version]"$($Matches[1]).$($Matches[2])" -lt [version]'3.7') {
    throw "hqrestart needs Python 3.7 or newer; found $ver."
}
# The helper is run with pythonw where there is one: no console window.
$py = if ($pyw) { $pyw } else { $pyc }

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

# The port the helper actually listens on: a config that sets one must open THAT
# port, or the rule is for 8090 and LMS still cannot reach it, with no warning.
# The config is written on the first start, so wait for it here.
for ($i = 0; $i -lt 20 -and -not (Test-Path $cfg); $i++) { Start-Sleep -Milliseconds 500 }
$conf = $null
try { $conf = Get-Content $cfg -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
$port = if ($conf -and $conf.port) { [int]$conf.port } else { 8090 }
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
$token = if ($conf) { $conf.token } else { $null }

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

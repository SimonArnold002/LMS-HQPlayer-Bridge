# Install hqrestart on Windows as a scheduled task.
#
#   .\install.ps1              HQPlayer runs as an APP: the webhook runs as you,
#                              at logon, in your desktop session
#   .\install.ps1 -System      HQPlayer runs as a Windows SERVICE: the webhook runs
#                              as SYSTEM at boot (run this from an admin PowerShell)
#   .\install.ps1 -Uninstall   (add -System for the system one)
#
#   -Allow <ip>                the Lyrion (LMS) server that may press Restart
#                              without a token. Asked for interactively when it
#                              is not given. Several may be listed, comma-separated.
#
# Needs Python 3.7+ on PATH (python.org installer, "Add to PATH").
param([switch]$System, [switch]$Uninstall, [string]$Allow)
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

# ---------------------------------------------------------------------------
# `allow` - the ONLY way the HQPlayer Bridge's Restart row can work: the Bridge
# holds no token, so the helper has to trust the Lyrion server by address. It
# used to be a hand edit of the JSON, which meant a user installed the helper,
# tapped Restart and got a refusal with nothing to tell them why. It is asked
# for here instead, and written BEFORE the task starts - the helper reads its
# config once, at startup.
#
# Reading and writing that key is done by the HELPER itself (`--allow`), not
# reimplemented here: one rule, one validator, and install.sh calls the same
# one. It also rejects a half-written address like "192.168.1", which .NET's
# IPAddress.Parse would silently turn into 192.0.0.1 on Windows PowerShell.
# ---------------------------------------------------------------------------
$pyForCfg = if ($pyc) { $pyc } else { $py }
$helper = Join-Path $dir 'hqrestart.py'

# Both are wrapped: $ErrorActionPreference is 'Stop' for the whole script, and a
# native command that writes to stderr can surface as a terminating error in some
# hosts. Asking about `allow` must never be able to abort an otherwise good
# install - the worst case here is that it stays unset and the closing line says so.
function Get-Allow {
    try {
        $out = & $pyForCfg $helper --allow $cfg 2>$null
        if ($LASTEXITCODE -ne 0) { return '' }
        return ("$out").Trim()
    } catch { return '' }
}
function Set-Allow([string]$value) {
    try {
        $out = & $pyForCfg $helper --allow $cfg $value
        if ($LASTEXITCODE -ne 0) { return $null }
        return ("$out").Trim()
    } catch { return $null }
}

$current = Get-Allow
if ($PSBoundParameters.ContainsKey('Allow') -and $Allow) {
    $written = Set-Allow $Allow
    if ($null -eq $written) { Write-Warning "-Allow $Allow was not accepted; leaving it unset." }
    else { $current = $written }
} elseif (-not $PSBoundParameters.ContainsKey('Allow')) {
    ''
    'The HQPlayer Bridge plugin adds a Restart HQPlayer row to Lyrion (LMS).'
    'For it to work, this machine has to trust your Lyrion server address.'
    ''
    while ($true) {
        if ($current) { $prompt = "Lyrion server IP address [$current]" }
        else          { $prompt = 'Lyrion server IP address (press return to skip)' }
        # Read-Host THROWS under -NonInteractive, and by here the scheduled task
        # has already been unregistered - so an unguarded prompt would leave a
        # provisioning run with no helper at all. install.sh guards with [ -t 0 ].
        try { $answer = (Read-Host $prompt) } catch { '  (not interactive - skipping)'; break }
        if (-not $answer) { break }
        $written = Set-Allow $answer
        if ($null -ne $written) { $current = $written; break }
        '  try again, or press return to leave it unset.'
    }
    ''
}
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
#
# Wait for THE TOKEN, not for the file. The file now exists before the helper
# ever runs whenever `allow` was answered above, so a Test-Path wait returned
# at once and printed an empty token with a broken curl line beside it.
$conf = $null
for ($i = 0; $i -lt 20; $i++) {
    try { $conf = Get-Content $cfg -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $conf = $null }
    if ($conf -and $conf.token) { break }
    Start-Sleep -Milliseconds 500
}
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
if ($current) {
    "Lyrion:  $current can press Restart HQPlayer without a token"
} else {
    "Lyrion:  not set - the Bridge's Restart row will be refused."
    if ($System) { "         run: .\install.ps1 -System -Allow <your Lyrion server IP>" }
    else          { "         run: .\install.ps1 -Allow <your Lyrion server IP>" }
}
if ($token) {
    "token:   $token"
    "test:    curl -H `"Authorization: Bearer $token`" http://$($env:COMPUTERNAME):$port/status"
} else {
    Write-Warning ("The helper has not written its config yet, so there is no token to show. " +
                   "It is generated on first start - read it from $cfg, or check the log above. " +
                   "Check Python 3.7+ is on PATH if the file never appears.")
}

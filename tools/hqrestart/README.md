# hqrestart

A small webhook, run on the HQPlayer machine, that restarts HQPlayer from anywhere on the LAN.

Why: when the NAA endpoint is power-cycled, hqplayerd often will not use it again until it is
restarted (Signalyst's advice is to start the NAA first, then HQPlayer). HQPlayer's web UI has
**Refresh devices**, but that drops the saved output mode (SDM becomes PCM). A restart reloads the
saved settings. HQPlayer's control API has no restart command, and `:8088/restart` does nothing.

## What it restarts, and how

It finds the running HQPlayer (`hqplayerd`, or HQPlayer 5/6 Desktop), works out how that copy was
started, and restarts it the same way:

| OS | as a service | as an app |
|---|---|---|
| macOS | `launchctl kickstart -k` on its launchd label | SIGTERM, then `open` its `.app` (unless macOS relaunches it first) |
| Linux | `systemctl [--user] restart` on the unit found in `/proc/<pid>/cgroup` | SIGTERM, then rerun its original command line |
| Windows | `Restart-Service` on the service that owns the process | stop it, then start the same `.exe` |

It can also start HQPlayer when it is not running: from `service` or `start_command` if the config
pins one, otherwise from the last launch it saw.

**Only the macOS app row has been run for real.** Every other cell in that table - macOS as a
service, and all of Linux and Windows - is written and covered by automated tests, but has not
been run on a real machine yet. See [Tested](#tested).

## Install

Install it the same way HQPlayer runs. For a system service the webhook needs root / SYSTEM. For
an app, it must run as the logged-in user. Installed the wrong way round, a restart is refused
before anything is stopped, with "runs as another user", and HQPlayer keeps playing.

```
./install.sh                  # macOS/Linux, HQPlayer is an app (or a user service)
sudo ./install.sh --system    # macOS/Linux, HQPlayer is a system service
.\install.ps1                 # Windows, HQPlayer is an app
.\install.ps1 -System         # Windows, HQPlayer is a service (admin PowerShell)
```

The installer prints the token. It is stored in `hqrestart.json` next to the installed script.

For the HQPlayer Bridge's Restart row to work, add the LMS server's IP address to `allow` in
that file (e.g. `"allow": ["192.168.1.234"]`), then run the installer again. Reinstalling
keeps the config.

## Uninstall

```
./install.sh --uninstall                  # macOS/Linux, app
sudo ./install.sh --system --uninstall    # macOS/Linux, system service
.\install.ps1 -Uninstall                  # Windows, app
.\install.ps1 -System -Uninstall          # Windows, service (admin PowerShell)
```

This stops the helper and removes it from startup. The config folder is left in place; delete
it if you won't reinstall. On Windows, also remove the firewall rule from an admin PowerShell:
`Remove-NetFirewallRule -DisplayName hqrestart`.

## What it looks like on the machine

It runs as Python, so on macOS and Windows it mostly shows up under Python's name rather than
its own:

| | macOS | Linux | Windows |
|---|---|---|---|
| started by | a LaunchAgent, `com.hqrestart.webhook` (a LaunchDaemon with `--system`) | a systemd unit, `hqrestart.service` (user, or system with `--system`) | a scheduled task, `hqrestart` (as SYSTEM with `-System`) |
| where to see it | System Settings → General → Login Items & Extensions → *Allow in the Background*, as **python3** | `systemctl --user status hqrestart` (no `--user` for a system install) | Task Scheduler → Task Scheduler Library → **hqrestart** |
| the process | **Python** in Activity Monitor | `python3 …/hqrestart.py` | **pythonw.exe** in Task Manager → Details |

macOS shows a "Background Items Added" notice when it is installed. Switching the item off
in *Allow in the Background* stops the helper; use `--uninstall` instead. On Windows the
installer also adds an inbound firewall rule named **hqrestart**.

Only the macOS column has been checked on a real machine. The Linux and Windows columns are
what the installers set up; neither has been run on a real Linux or Windows machine yet.

## From LMS (HQPlayer Bridge)

The Bridge needs no settings. When its control link to an HQPlayer comes up, it calls
`http://<that HQPlayer>:8090/ping`, which needs no token. If that answers, the HQPlayer gets a
**Restart *name*** row in the Bridge's Apps list, under HQPlayer Live View. The restart itself only works if the LMS
server's address is in `allow`: the Bridge has no token to send.

**Why only a JSON POST gets in without the token.** Anything that can make the LMS
server fetch a URL would otherwise restart HQPlayer as a GET. LMS's own image proxy fetches
any URL a client gives it, and LMS needs no login by default, so any web page on the LAN
could do it. A form POST is refused as well. Browsers won't send a JSON POST to another
site without checking with the server first, and this server doesn't answer that check.
The Bridge sends a JSON POST.

The request must also be addressed to the helper by IP address (or `localhost`, or a name in
`hostnames`). Otherwise a web page could point its own domain at your machine's address
(DNS rebinding) and make the POST look same-origin. That only matters if a browser runs on a
machine in `allow`. The Bridge always connects by IP address.

## Use

```
curl -H 'Authorization: Bearer TOKEN' http://HQHOST:8090/status
curl -X POST -H 'Authorization: Bearer TOKEN' http://HQHOST:8090/restart
http://HQHOST:8090/restart?token=TOKEN        # browser bookmark / phone shortcut
```

The token is never written to the log (`token=***`). `/restart` returns once HQPlayer is back, with the old and new process ids (about 7s on a Mac).
Only one restart runs at a time; a second request gets `409`.

## Config (`hqrestart.json`)

Every key is optional except `token`, which is generated on first run.

| key | default | meaning |
|---|---|---|
| `port` / `listen` | `8090` / `::` | where it listens. `::` serves IPv6 AND IPv4 on one socket, falling back to `0.0.0.0` where IPv6 is off. Keep 8090 for the HQPlayer Bridge to find it |
| `allow` | `[]` | addresses that may restart WITHOUT the token, but only with a JSON POST addressed by IP (see below). Put your LMS server here, e.g. `["192.168.1.234"]`. IPv4 and IPv6 both work, and a v4 address written the ordinary way still matches a client arriving over the IPv6 socket |
| `hostnames` | `[]` | host names, besides an IP address or `localhost`, that the tokenless route may be addressed by |
| `mode` | `auto` | force `app` or `service` |
| `service` | detected | pin the launchd label, systemd unit or Windows service name |
| `user_service` | detected | Linux: `true` for `systemctl --user`. Detected from where HQPlayer runs, even with `service` pinned; set it if HQPlayer is a user unit and may be stopped when you restart it |
| `start_command` | detected | pin how the app is started, as a list, e.g. `["open", "-a", "/Applications/hqplayerd.app"]` |
| `process_names` | per OS | process names to look for |
| `stop_timeout` | `20` | seconds allowed for a clean exit before it is killed |
| `respawn_wait` | `6` | macOS app: seconds to let macOS relaunch it first |
| `start_timeout` | `30` | seconds for the new process to appear |
| `total_timeout` | `90` | the whole restart, every wait included. The Bridge waits 120s, so keep this below that |

## When it refuses and leaves HQPlayer running

For an app, the helper decides how it will start HQPlayer again *before* it stops it, and
checks that the program is still there. If it can't tell (for example the app was deleted
or moved since it was launched, or the helper isn't allowed to see where it runs from),
it uses the last way it saw HQPlayer started, if that still works. Failing that, the
restart fails with "HQPlayer (pid N) was left running" and HQPlayer keeps playing. To fix
it for good, set `start_command`.

The same goes for a copy of HQPlayer the helper cannot stop - one running as administrator
on Windows, say. If it is still there a few seconds after a forced stop, the restart gives
up with "would not stop, so it was left running" rather than starting a second copy.

## Windows notes

`install.ps1` runs the helper with `pythonw`, which has no console. The helper then writes
its log to `hqrestart.log` next to its config. Opening the firewall port needs an admin
PowerShell. Without it the installer warns you, and LMS may not be able to reach the helper.

## Linux notes

Under systemd, a process the helper starts would otherwise stay in the helper's own cgroup.
Stopping the helper would then kill it, and the next restart would mistake it for the helper's
own service. So on Linux an app is relaunched through `systemd-run --scope`, the helper
ignores its own unit when working out how HQPlayer was started, and its unit has
`KillMode=process`. If `systemd-run` can't create a scope (for example, no user session bus),
the app is started without one rather than left stopped.

A relaunched app also gets back its session's display and desktop variables (`DISPLAY`,
`WAYLAND_DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR`, the D-Bus address, `HOME`, the locale, `PULSE_SERVER`),
read from the running process. A helper running as a service has none of them, and HQPlayer
Desktop can't open its window without them. No other variables are copied.

Linux keeps only the first 15 characters of a process name, so `hqplayer6desktop` is looked
for as `hqplayer6deskto`.

If the helper refuses to start - a config file that doesn't parse, or a port it can't bind -
it says so in one line and exits 2, and the systemd unit's `RestartPreventExitStatus=2` leaves
it stopped rather than retrying for ever: `systemctl --user status hqrestart` shows the reason.
A crash still restarts. On macOS and Windows there is no such filter, so it retries (every 10s
under launchd, every minute under Task Scheduler) until the config is fixed.

## Tested

macOS app mode, 2026-09-21: `hqplayerd` Embedded 6.0.2 on macOS 26.6, restarted in 7.1s. The
saved SDM settings came back (`Set dither: 9` / `Set modulator: 18`), and the Bridge and the
Eversolo NAA reconnected. The same again from the HQPlayer Bridge's Restart row (1.0.13): about 7s, and
playback carried on in SDM afterwards. **Not yet run:** any failure path live, macOS service mode, Linux, Windows.
Linux and Windows are covered by a test suite that fakes the OS, and every piece of PowerShell
is checked to parse with `pwsh` - but neither has run on a real Linux or Windows machine.

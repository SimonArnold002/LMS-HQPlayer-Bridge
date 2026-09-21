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

It remembers the last launch it saw, so it can also start HQPlayer when it is not running.

## Install

Install it the same way HQPlayer runs. For a system service the webhook needs root / SYSTEM. For
an app, it must run as the logged-in user.

```
./install.sh                  # macOS/Linux, HQPlayer is an app (or a user service)
sudo ./install.sh --system    # macOS/Linux, HQPlayer is a system service
.\install.ps1                 # Windows, HQPlayer is an app
.\install.ps1 -System         # Windows, HQPlayer is a service (admin PowerShell)
```

The installer prints the token. It is stored in `hqrestart.json` next to the installed script.

## From LMS (HQPlayer Bridge)

The Bridge needs no settings. When its control link to an HQPlayer comes up, it calls
`http://<that HQPlayer>:8090/ping`, which needs no token. If that answers, the HQPlayer gets a
**Restart HQPlayer** row in the Bridge's Apps list. The restart itself only works if the LMS
server's address is in `allow`: the Bridge has no token to send.

**Why only a JSON POST gets in without the token.** Anything that can make the LMS
server fetch a URL would otherwise restart HQPlayer as a GET. LMS's own image proxy fetches
any URL a client gives it, and LMS needs no login by default, so any web page on the LAN
could do it. A form POST is refused as well. Browsers won't send a JSON POST to another
site without checking with the server first, and this server doesn't answer that check.
The Bridge sends a JSON POST.

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
| `port` / `listen` | `8090` / `0.0.0.0` | where it listens. Keep 8090 for the HQPlayer Bridge to find it |
| `allow` | `[]` | addresses that may restart WITHOUT the token, but only with a JSON POST (see below). Put your LMS server here, e.g. `["192.168.1.234"]` |
| `mode` | `auto` | force `app` or `service` |
| `service` | detected | pin the launchd label, systemd unit or Windows service name |
| `user_service` | detected | Linux: `true` for `systemctl --user` |
| `start_command` | detected | pin how the app is started, as a list, e.g. `["open", "-a", "/Applications/hqplayerd.app"]` |
| `process_names` | per OS | process names to look for |
| `stop_timeout` | `20` | seconds allowed for a clean exit before it is killed |
| `respawn_wait` | `6` | macOS app: seconds to let macOS relaunch it first |
| `start_timeout` | `30` | seconds for the new process to appear |
| `total_timeout` | `90` | the whole restart, every wait included. The Bridge waits 120s, so keep this below that |

## Linux notes

Under systemd, a process the helper starts would otherwise stay in the helper's own cgroup.
Stopping the helper would then kill it, and the next restart would mistake it for the helper's
own service. So on Linux an app is relaunched through `systemd-run --scope`, the helper
ignores its own unit when working out how HQPlayer was started, and its unit has
`KillMode=process`.

## Tested

macOS app mode, 2026-09-21: `hqplayerd` Embedded 6.0.2 on macOS 26.6, restarted in 7.1s. The
saved SDM settings came back (`Set dither: 9` / `Set modulator: 18`), and the Bridge and the
Eversolo NAA reconnected. **Not yet run:** macOS service mode, Linux, Windows. The Linux cgroup handling is tested in a harness only.

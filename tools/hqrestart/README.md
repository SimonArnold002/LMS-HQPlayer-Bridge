# hqrestart

A small webhook, run on the HQPlayer machine, that restarts HQPlayer from anywhere on the LAN.

Why: when the NAA endpoint is power-cycled, hqplayerd often will not use it again until it is
restarted (Signalyst's advice is to start the NAA first, then HQPlayer). HQPlayer's web UI has
**Refresh devices**, but that drops the saved output mode (SDM becomes PCM). A restart reloads the
saved settings. HQPlayer's control API has no restart command, and `:8088/restart` does nothing.

## What it restarts, and how

It runs on **macOS and Linux**. Windows is not supported.

It finds the running HQPlayer (`hqplayerd`, or HQPlayer 5/6 Desktop), works out how that copy was
started, and restarts it the same way:

| OS | as a service | as an app |
|---|---|---|
| macOS | `launchctl kickstart -k` on its launchd label | SIGTERM, then `open` its `.app` (unless macOS relaunches it first) |
| Linux | `systemctl [--user] restart` on the unit found in `/proc/<pid>/cgroup` | SIGTERM, then rerun its original command line |

It can also start HQPlayer when it is not running: from `service` or `start_command` if the config
pins one, otherwise from the last launch it saw.

**Only the macOS app row has been run for real.** Every other cell in that table - macOS as a
service, and all of Linux - is written and covered by automated tests, but has not
been run on a real machine yet. See [Tested](#tested).

## Requirements

**Python 3.7 or later** (3.7 for `ThreadingHTTPServer`), standard library only - nothing to
`pip install`. **The installer does not install Python**: if `python3` is missing it exits 1 with
`python3 not found - install Python 3.7 or newer first` and changes nothing.

**macOS: Apple's own prompt, not ours.** macOS ships no Python; `/usr/bin/python3` is a stub
hard-linked to the same binary as `/usr/bin/git` and `/usr/bin/clang`. The first time anything
invokes it - here, the installer's version check - macOS offers to install the **Command Line
Tools**, which is where its Python 3.9 comes from. Accept it, or click *Not Now* and install
Python yourself (python.org installer, or Homebrew) before re-running `./install.sh`. The helper
only needs some `python3` >= 3.7 on `PATH`.

**Linux: nothing is offered and nothing is installed.** Python 3 is already present on
essentially every distribution; if not, install it with the package manager. There is no
equivalent of Apple's prompt, so no toolchain is ever pulled in implicitly.

## Install

Install it the same way HQPlayer runs. For a system service the webhook needs root. For
an app, it must run as the logged-in user. Installed the wrong way round, a restart is refused
before anything is stopped, with "runs as another user", and HQPlayer keeps playing.

```
./install.sh                  # HQPlayer is an app (or a Linux user service)
sudo ./install.sh --system    # HQPlayer is a system service
```

**It asks for your Lyrion server's address**, because that is what makes the Bridge's Restart
row work - the Bridge has no token to send, so this machine has to trust Lyrion by address:

```
The HQPlayer Bridge plugin adds a Restart HQPlayer row to Lyrion (LMS).
For it to work, this machine has to trust your Lyrion server's address.

Lyrion server IP address (press return to skip):
```

Press return to skip it if you only want the token and a bookmark. To answer without being
asked - or to change it later - pass it on the command line and re-run the installer, which
keeps the rest of the config:

```
./install.sh --allow 192.168.1.234
```

It must be an **IP address**, not a host name: it is matched against the address the request
arrives from. Several may be given, comma-separated. Re-running the installer and pressing
return at the prompt keeps whatever is already set, so picking up a new version never drops it.

The installer prints the token, the config path, and whether Lyrion may press Restart. It is
all stored in `hqrestart.json` next to the installed script.

## Uninstall

```
./install.sh --uninstall                  # app
sudo ./install.sh --system --uninstall    # system service
```

This stops the helper and removes it from startup. The config folder is left in place; delete
it if you won't reinstall.

## What it looks like on the machine

It runs as Python, so on macOS it mostly shows up under Python's name rather than its own:

| | macOS | Linux |
|---|---|---|
| started by | a LaunchAgent, `com.hqrestart.webhook` (a LaunchDaemon with `--system`) | a systemd unit, `hqrestart.service` (user, or system with `--system`) |
| where to see it | System Settings → General → Login Items & Extensions → *Allow in the Background*, as **python3** | `systemctl --user status hqrestart` (no `--user` for a system install) |
| the process | **Python** in Activity Monitor | `python3 …/hqrestart.py` |

macOS shows a "Background Items Added" notice when it is installed. Switching the item off
in *Allow in the Background* stops the helper; use `--uninstall` instead.

Only the macOS column has been checked on a real machine. The Linux column is what the
installer sets up; it has not been run on a real Linux machine yet.

## From LMS (HQPlayer Bridge)

The Bridge needs no settings. It calls `http://<that HQPlayer>:8090/ping`, which needs no
token, when its control link to an HQPlayer comes up, and again when you open its Apps list
(at most once a minute per HQPlayer, so a helper installed later shows up on the next open). If
that answers, the HQPlayer gets a **Restart *name*** row in the Bridge's Apps list, under
HQPlayer Live View.

The restart itself only works if the LMS server's address is in `allow` - the Bridge has no
token to send - which is what the installer asks for. If it isn't, the row says
**Restart failed: bad or missing token**, and the helper's log names the address it refused
and the exact command that fixes it:

```
refused a restart from 192.168.1.234: that address is not in "allow". If 192.168.1.234 is your
Lyrion server, run  ./install.sh --allow 192.168.1.234  on this machine (add --system if
HQPlayer runs as a service).
```

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
| `allow` | `[]` | addresses that may restart WITHOUT the token, but only with a JSON POST addressed by IP (see below). **Set by the installer** - it asks, or takes `--allow`. Your Lyrion server, e.g. `["192.168.1.234"]`. IPv4 and IPv6 both work, and a v4 address written the ordinary way still matches a client arriving over the IPv6 socket |
| `hostnames` | `[]` | host names, besides an IP address or `localhost`, that the tokenless route may be addressed by |
| `mode` | `auto` | force `app` or `service` |
| `service` | detected | pin the launchd label or systemd unit |
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

The same goes for a copy of HQPlayer the helper cannot stop. If it is still there a few seconds after a forced stop, the restart gives
up with "would not stop, so it was left running" rather than starting a second copy.

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
A crash still restarts. On macOS there is no such filter, so launchd retries every 10s until
the config is fixed.

## Tested

macOS app mode, 2026-09-21: `hqplayerd` Embedded 6.0.2 on macOS 26.6, restarted in 7.1s. The
saved SDM settings came back (`Set dither: 9` / `Set modulator: 18`), and the Bridge and the
Eversolo NAA reconnected. The same again from the HQPlayer Bridge's Restart row (1.0.13): about 7s, and
playback carried on in SDM afterwards. **Not yet run:** any failure path live, macOS service mode, Linux.
Linux is covered by a test suite that fakes the OS, but has not run on a real Linux machine.

**The installer** is run end to end by the test suite with the service managers replaced by
stubs: a fresh install, a typo in `--allow`, Ctrl-C at the prompt, no Python, a non-interactive
run and an uninstall, each checked to leave the existing helper running where it should. **The
install-time address prompt (2026-09-23) has not yet been run on a real install** - the helper
installed on the test Mac predates it.

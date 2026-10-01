#!/bin/sh
# Install hqrestart as a background service on macOS or Linux.
#
#   ./install.sh            HQPlayer runs as an APP (or a user service):
#                           the webhook runs as you, in your login session
#   sudo ./install.sh --system
#                           HQPlayer runs as a SYSTEM service (LaunchDaemon /
#                           systemd system unit): the webhook runs as root
#   ./install.sh --uninstall   (sudo ... --system --uninstall for the system one)
#
#   --allow <ip>            the Lyrion (LMS) server that may press Restart
#                           without a token. Asked for interactively when it is
#                           not given. Several may be listed, comma-separated.
#
# The script and its config are copied to a fixed place, so the repo checkout
# can move. Everything that asks or can refuse runs BEFORE the old helper is
# stopped, so Ctrl-C or a typo leaves it running. The token is printed at the
# end once the helper's first start has written it; it lives in hqrestart.json.
set -e

SRC="$(cd "$(dirname "$0")" && pwd)/hqrestart.py"
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "python3 not found - install Python 3.7 or newer first" >&2; exit 1; }
# 3.7 for ThreadingHTTPServer. Older pythons (3.6 is still the default on some
# distributions) fail at IMPORT, before the helper can log anything, and the
# service manager then restarts it for ever - so it is refused here instead.
"$PY" - <<'PYEOF' || { echo "hqrestart needs Python 3.7 or newer; $PY is $("$PY" -c 'import platform;print(platform.python_version())' 2>/dev/null)" >&2; exit 1; }
import sys
sys.exit(0 if sys.version_info >= (3, 7) else 1)
PYEOF

SYSTEM=0; UNINSTALL=0; ALLOW=''; ALLOW_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --system)    SYSTEM=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --allow)     shift; [ $# -gt 0 ] || { echo "--allow needs an address" >&2; exit 2; }
                 ALLOW="$1"; ALLOW_GIVEN=1 ;;
    --allow=*)   ALLOW="${1#--allow=}"; ALLOW_GIVEN=1 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
if [ $SYSTEM = 1 ] && [ "$(id -u)" != 0 ]; then echo "--system needs sudo" >&2; exit 1; fi

# ---------------------------------------------------------------------------
# `allow` - read, validate and write it.
#
# This is the ONLY way the HQPlayer Bridge's Restart row can work: the Bridge
# has no token to send, so the helper has to trust the Lyrion server by
# address. It used to be a hand edit of the JSON, which meant a user installed
# the helper, tapped Restart, and got a refusal with nothing to tell them why.
# It is asked for here instead.
# ---------------------------------------------------------------------------
# Reading and writing that key is done by the helper itself, not reimplemented
# here: one rule, one validator. WRITING goes through `--allow`, which refuses
# a host name - `allow` is matched against the address a request arrives from -
# and never rewrites a config that does not parse, because the token lives in
# that file. READING goes through `--get`, like read_key below: the helper's own
# Config and `_coerce`, so what is shown is what the running helper admits. It
# read through `--allow` once, whose raw read has no coercion - a hand-edited
# string `"allow": "192.168.1.234"`, which the helper accepts as one entry,
# read as "not set" and the closing lines said the Restart row would be refused.
# Its errors are silenced here only because a config that does not parse has
# already been refused by the check below, before this is first called.
read_allow() {
  "$PY" "$SRC" --get "$1" allow 2>/dev/null || true
}

write_allow() {
  "$PY" "$SRC" --allow "$1" "$2"
}

OS="$(uname -s)"
LABEL=com.hqrestart.webhook

# Where everything lives, decided before anything is installed so the config
# can be written BEFORE the helper first starts - it reads the file once, at
# startup, so a config written afterwards would not take effect until a restart.
if [ "$OS" = Darwin ]; then
  if [ $SYSTEM = 1 ]; then
    DIR="/Library/Application Support/hqrestart"
    PLIST="/Library/LaunchDaemons/$LABEL.plist"
    DOMAIN=system
    LOGF=/Library/Logs/hqrestart.log
  else
    DIR="$HOME/Library/Application Support/hqrestart"
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    DOMAIN="gui/$(id -u)"
    LOGF="$HOME/Library/Logs/hqrestart.log"
  fi
elif [ "$OS" = Linux ]; then
  if [ $SYSTEM = 1 ]; then
    DIR=/etc/hqrestart
    UNIT=/etc/systemd/system/hqrestart.service
    SC="systemctl"; WANTED=multi-user.target
  else
    DIR="$HOME/.config/hqrestart"
    UNIT="$HOME/.config/systemd/user/hqrestart.service"
    SC="systemctl --user"; WANTED=default.target
  fi
else
  echo "unsupported OS $OS - the helper runs on macOS and Linux only" >&2; exit 1
fi

CONF="$DIR/hqrestart.json"

# ASK FIRST, stop second. Everything that waits on the user, or can be
# refused, happens while the running helper is still up: a prompt sitting
# between the stop and the start left the helper DOWN for anyone who pressed
# Ctrl-C or walked away from it. Writing the config while the old helper runs
# is safe - it reads the file once, at its own startup, and the new one starts
# after this is written.
[ $UNINSTALL = 1 ] || mkdir -p "$DIR"

# A CONFIG THAT DOES NOT PARSE IS REFUSED HERE, while the running helper is
# still up. The running helper parsed it at ITS start - a hand edit since then
# (a trailing comma) is invisible to it - but the new one would exit 2 on its
# first line and stay down (RestartPreventExitStatus=2), and read_allow's
# silence used to make the broken file read as "not set": the old helper was
# stopped and replaced by one that could not start. The helper's own reader
# (`--get`, through Config) decides, so the rule is the one it will apply, and
# its one-line reason is what the user sees. An uninstall does not need it.
if [ $UNINSTALL = 0 ] && [ -e "$CONF" ]; then
  if ! "$PY" "$SRC" --get "$CONF" port >/dev/null; then
    echo "install.sh: nothing was changed and the running helper was left alone." >&2
    exit 1
  fi
fi

CURRENT="$(read_allow "$CONF")"

# Ask, unless --allow said so already or there is no one to ask (piped input,
# a provisioning script). Blank keeps whatever is there, so re-running the
# installer to pick up a new helper version never silently drops the setting.
if [ $UNINSTALL = 1 ]; then
  :                                   # nothing to ask on the way out
elif [ $ALLOW_GIVEN = 0 ] && [ -t 0 ]; then
  echo ""
  echo "The HQPlayer Bridge plugin adds a Restart HQPlayer row to Lyrion (LMS)."
  echo "For it to work, this machine has to trust your Lyrion server's address."
  echo ""
  while true; do
    if [ -n "$CURRENT" ]; then
      printf "Lyrion server IP address [%s]: " "$CURRENT"
    else
      printf "Lyrion server IP address (press return to skip): "
    fi
    ANSWER=''
    read -r ANSWER || ANSWER=''
    [ -n "$ANSWER" ] || break
    if write_allow "$CONF" "$ANSWER" >/dev/null; then
      CURRENT="$(read_allow "$CONF")"
      break
    fi
    echo "  try again, or press return to leave it unset."
  done
  echo ""
elif [ $ALLOW_GIVEN = 1 ] && [ -n "$ALLOW" ]; then
  # Warn and carry on: a typo must not block an upgrade. A refused address
  # changes nothing in the config, so the previous value stands and the
  # closing line reports it.
  if ! write_allow "$CONF" "$ALLOW" >/dev/null; then
    echo "warning: --allow $ALLOW was not accepted; leaving it as it was." >&2
  fi
  CURRENT="$(read_allow "$CONF")"
fi

# NOW stop the running copy - only after everything above has been asked and
# checked - so its file can be replaced, and so an uninstall leaves nothing
# behind. Nothing below this waits on the user.
if [ "$OS" = Darwin ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  if [ $UNINSTALL = 1 ]; then
    rm -f "$PLIST"; echo "removed $PLIST (config left in $DIR)"; exit 0
  fi
else
  $SC disable --now hqrestart.service 2>/dev/null || true
  if [ $UNINSTALL = 1 ]; then
    rm -f "$UNIT"; $SC daemon-reload; echo "removed $UNIT (config left in $DIR)"; exit 0
  fi
fi

mkdir -p "$DIR"
cp "$SRC" "$DIR/hqrestart.py"


if [ "$OS" = Darwin ]; then
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$DIR/hqrestart.py</string>
    <string>$DIR/hqrestart.json</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$LOGF</string>
  <key>StandardOutPath</key><string>$LOGF</string>
</dict>
</plist>
EOF
  launchctl bootstrap "$DOMAIN" "$PLIST"
else
  mkdir -p "$(dirname "$UNIT")"
  cat > "$UNIT" <<EOF
[Unit]
Description=hqrestart - webhook that restarts HQPlayer
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$PY $DIR/hqrestart.py $DIR/hqrestart.json
Restart=always
# stopping or updating the helper must never take a relaunched HQPlayer with it
KillMode=process
RestartSec=3
# The helper exits 2 when it REFUSES to start - a config that does not parse, a
# port it cannot bind - and says why in one line. Without this, Restart=always
# retries that refusal every 3s for ever and buries the line in its own repeats.
# A crash (any other code) still restarts.
RestartPreventExitStatus=2

[Install]
WantedBy=$WANTED
EOF
  $SC daemon-reload
  $SC enable --now hqrestart.service
  [ $SYSTEM = 1 ] || echo "note: for it to run while you are logged out: sudo loginctl enable-linger $(id -un)"
fi

# The token is generated on the helper's FIRST START, so wait for THE TOKEN -
# not for the file, which now exists already whenever `allow` was answered
# above. Waiting on the file printed an empty token and a broken curl line.
#
# Read through the helper (`--get`), not a copy of its rules in here: the copy
# that used to live here read a JSON null token as the text "None" - [ -n
# "None" ] is true, so the wait broke on its first pass and printed a bearer
# token of None - because it disagreed with Config about what a missing value
# is. --get prints exactly what the helper will use: an empty token until it
# has written one, and the port after the helper's own defaults and checks.
# $2 is only the fallback for a --get that could not run at all.
read_key() {
  "$PY" "$SRC" --get "$CONF" "$1" 2>/dev/null || echo "$2"
}

i=0
while [ $i -lt 20 ]; do
  TOKEN="$(read_key token '')"
  [ -n "$TOKEN" ] && break
  sleep 0.5; i=$((i+1))
done
PORT="$(read_key port 8090)"

# `--allow` has to be given the same way the helper was installed, or it writes
# a config in the other location that this install never reads.
SAME="$0"
[ $SYSTEM = 1 ] && SAME="sudo $0 --system"

echo "installed. config: $CONF"
if [ -n "$TOKEN" ]; then
  echo "token:   $TOKEN"
else
  echo "token:   not written yet - it is generated on the first start."
  echo "         look in $CONF, or in the log, and check python3 is 3.7 or newer."
fi
if [ -n "$CURRENT" ]; then
  echo "Lyrion:  $CURRENT can press Restart HQPlayer without a token"
else
  echo "Lyrion:  not set - the Bridge's Restart row will be refused."
  echo "         run: $SAME --allow <your Lyrion server IP>"
fi
[ -n "$TOKEN" ] && echo "test:    curl -H 'Authorization: Bearer $TOKEN' http://$(hostname):$PORT/status"
exit 0

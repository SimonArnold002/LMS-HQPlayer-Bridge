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
# The script and its config are copied to a fixed place, so the repo checkout
# can move. The token is printed at the end; it lives in hqrestart.json.
set -e

SRC="$(cd "$(dirname "$0")" && pwd)/hqrestart.py"
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "python3 not found" >&2; exit 1; }

SYSTEM=0; UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --system) SYSTEM=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
if [ $SYSTEM = 1 ] && [ "$(id -u)" != 0 ]; then echo "--system needs sudo" >&2; exit 1; fi

OS="$(uname -s)"
LABEL=com.hqrestart.webhook

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
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  if [ $UNINSTALL = 1 ]; then
    rm -f "$PLIST"; echo "removed $PLIST (config left in $DIR)"; exit 0
  fi
  mkdir -p "$DIR" "$(dirname "$PLIST")"
  cp "$SRC" "$DIR/hqrestart.py"
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
  $SC disable --now hqrestart.service 2>/dev/null || true
  if [ $UNINSTALL = 1 ]; then
    rm -f "$UNIT"; $SC daemon-reload; echo "removed $UNIT (config left in $DIR)"; exit 0
  fi
  mkdir -p "$DIR" "$(dirname "$UNIT")"
  cp "$SRC" "$DIR/hqrestart.py"
  cat > "$UNIT" <<EOF
[Unit]
Description=hqrestart - webhook that restarts HQPlayer
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$PY $DIR/hqrestart.py $DIR/hqrestart.json
Restart=always
RestartSec=3

[Install]
WantedBy=$WANTED
EOF
  $SC daemon-reload
  $SC enable --now hqrestart.service
  [ $SYSTEM = 1 ] || echo "note: for it to run while you are logged out: sudo loginctl enable-linger $(id -un)"
else
  echo "unsupported OS $OS - on Windows use install.ps1" >&2; exit 1
fi

# The token is generated on first start.
i=0; while [ ! -s "$DIR/hqrestart.json" ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done
TOKEN="$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1]))['token'])" "$DIR/hqrestart.json" 2>/dev/null || true)"
PORT="$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1])).get('port',8090))" "$DIR/hqrestart.json" 2>/dev/null || echo 8090)"
echo "installed. config: $DIR/hqrestart.json"
echo "token:   $TOKEN"
echo "test:    curl -H 'Authorization: Bearer $TOKEN' http://$(hostname):$PORT/status"

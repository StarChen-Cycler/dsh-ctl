#!/bin/sh
# Install (or remove) a launchd LaunchAgent that keeps the DSH fleet server
# running: starts it at login, restarts it if it exits, and logs to
# ~/Library/Logs/dsh-fleet.log.
#
# Usage:
#   sh mac-install-launchd.sh              install + start
#   sh mac-install-launchd.sh --uninstall  stop + remove
#
# Runs as the current user; no sudo needed. Idempotent: re-running replaces the
# existing job.
set -eu

LABEL="dev.dsh.fleet"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/dsh-fleet.log"
FLEET_RUN="$HOME/.dsh/fleet-run.sh"
PORT="${DSH_FLEET_PORT:-17390}"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--uninstall" ]; then
  echo "== unloading $LABEL =="
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "removed $PLIST"
  exit 0
fi

if [ ! -x "$FLEET_RUN" ]; then
  echo "missing executable: $FLEET_RUN" >&2
  exit 1
fi

echo "== stop any hand-started instance (it would fight for the port) =="
pkill -f 'bin.js fleet' 2>/dev/null && sleep 2 || true

echo "== write $PLIST =="
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$FLEET_RUN</string>
  </array>

  <key>WorkingDirectory</key>
  <string>$HOME</string>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <!-- Do not spin: a crash loop restarts at most every 10s. -->
  <key>ThrottleInterval</key>
  <integer>10</integer>

  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
PLIST_EOF

chmod 644 "$PLIST"

echo "== replace existing job =="
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL"

echo "== wait for the control plane =="
i=0
OK=0
while [ "$i" -lt 30 ]; do
  i=$((i + 1))
  sleep 1
  if curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$PORT/ctl/health" 2>/dev/null; then
    OK=1
    echo "listening after ${i}s"
    break
  fi
done

echo "== launchd state =="
launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E '^\s*(state|pid|runs|last exit code) ' | head -6

if [ "$OK" -ne 1 ]; then
  echo "did not come up; last log lines:" >&2
  tail -15 "$LOG" 2>/dev/null >&2 || true
  exit 1
fi

echo "== health =="
curl -s --max-time 5 "http://127.0.0.1:$PORT/ctl/health"
echo
echo "done. log: $LOG"

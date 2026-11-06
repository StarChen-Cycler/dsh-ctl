#!/bin/sh
# Start the fleet profile detached and wait for its control plane to answer.
# Used for a first smoke test; use launchd (see docs/MACOS.md) for production.
set -u

export PNPM_HOME="${PNPM_HOME:-$HOME/.dsh/pnpm-global}"
PORT="${DSH_FLEET_PORT:-17390}"
LOG="${DSH_FLEET_LOG:-$HOME/dsh-fleet.log}"

pkill -f 'bin.js fleet' 2>/dev/null && sleep 1 || true
cd "$HOME" || exit 1
rm -f "$LOG"

nohup sh "$HOME/.dsh/fleet-run.sh" > "$LOG" 2>&1 &
echo "started pid=$!"

i=0
while [ "$i" -lt 25 ]; do
  i=$((i + 1))
  sleep 1
  if curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$PORT/ctl/health" 2>/dev/null; then
    echo "listening after ${i}s"
    break
  fi
done

echo "== log head =="
sed -n '1,3p' "$LOG"

echo "== health =="
curl -s --max-time 5 "http://127.0.0.1:$PORT/ctl/health" || echo "(no response)"
echo

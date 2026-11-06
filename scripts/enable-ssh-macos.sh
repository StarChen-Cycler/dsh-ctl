#!/bin/sh
# Enable Remote Login (SSH) on macOS.
#
# Dry-run by default; pass --apply to execute. Requires sudo.
#
# Note for macOS 13+: toggling Remote Login from a terminal may need Full Disk
# Access for that terminal app. If `systemsetup` reports that it cannot change
# settings, enable it in System Settings > General > Sharing > Remote Login.
#
# Enabling a service is deliberately NOT something the dsh-ctl plugin does.
set -eu

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help) echo "usage: $0 [--apply]"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

echo "macOS Remote Login (SSH) setup plan:"
echo "  1. sudo systemsetup -setremotelogin on"
echo "  2. verify with: systemsetup -getremotelogin"
echo "  3. confirm sshd listens: sudo lsof -nP -iTCP:22 -sTCP:LISTEN"

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "Dry run. Re-run with --apply to execute."
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must run via sudo." >&2
  exit 1
fi

echo "-> enabling Remote Login"
systemsetup -setremotelogin on
echo
echo "current state:"
systemsetup -getremotelogin
echo
echo "Done. Verify from another machine:"
echo "  ssh <user>@<this-host> hostname"

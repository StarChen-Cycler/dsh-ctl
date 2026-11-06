#!/bin/sh
# Enable the SSH server on a Linux host using systemd.
#
# Dry-run by default; pass --apply to execute. Requires root.
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

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl not found. This script targets systemd hosts." >&2
  echo "On other init systems install and enable openssh-server with your package manager." >&2
  exit 1
fi

UNIT=""
for candidate in ssh sshd; do
  if systemctl list-unit-files "${candidate}.service" >/dev/null 2>&1 &&
     systemctl list-unit-files "${candidate}.service" | grep -q "${candidate}.service"; then
    UNIT="$candidate"
    break
  fi
done

if [ -z "$UNIT" ]; then
  echo "No ssh/sshd unit found. Install openssh-server first, e.g.:" >&2
  echo "  Debian/Ubuntu: apt-get install -y openssh-server" >&2
  echo "  Fedora/RHEL:   dnf install -y openssh-server" >&2
  exit 1
fi

echo "Linux SSH setup plan:"
echo "  1. systemctl enable --now ${UNIT}"
echo "  2. systemctl is-active ${UNIT}"
echo "  3. confirm listening: ss -ltnp | grep ':22'"

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "Dry run. Re-run with --apply to execute."
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must run as root." >&2
  exit 1
fi

echo "-> enabling ${UNIT}"
systemctl enable --now "${UNIT}"
echo
systemctl is-active "${UNIT}" || true
echo
echo "Done. Verify from another machine:"
echo "  ssh <user>@<this-host> hostname"

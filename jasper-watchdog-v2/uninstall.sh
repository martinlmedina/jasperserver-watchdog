#!/usr/bin/env bash
# Removes jasper-watchdog-v2's managed artifacts.
#
# Preserves /etc/jasper-watchdog (config) and /var/log/jasper-watchdog
# (forensic incident evidence) by default. Pass --purge to remove those too.
# Works from a git checkout or an extracted tarball; supports DESTDIR for
# staged/test runs.
#
# Usage:
#   sudo ./uninstall.sh
#   sudo ./uninstall.sh --purge
set -euo pipefail

DESTDIR="${DESTDIR:-}"
purge=0
if [[ "${1:-}" == "--purge" ]]; then
  purge=1
elif [[ -n "${1:-}" ]]; then
  echo "ERROR: unknown argument: $1 (only --purge is supported)" >&2
  exit 1
fi

if [[ -z "$DESTDIR" && "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: run as root, or set DESTDIR for a staged uninstall." >&2
  exit 1
fi

# Stop and disable the timer on a real system.
if [[ -z "$DESTDIR" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now jasper-watchdog.timer 2>/dev/null || true
fi

rm -f "$DESTDIR/usr/local/sbin/jasper-watchdog-v2"
rm -f "$DESTDIR/etc/systemd/system/jasper-watchdog.service"
rm -f "$DESTDIR/etc/systemd/system/jasper-watchdog.timer"
rm -f "$DESTDIR/etc/logrotate.d/jasper-watchdog"
rm -f "$DESTDIR/etc/tmpfiles.d/jasper-watchdog.conf"

if [[ -z "$DESTDIR" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
fi

if [[ "$purge" -eq 1 ]]; then
  rm -rf "$DESTDIR/etc/jasper-watchdog"
  rm -rf "$DESTDIR/var/log/jasper-watchdog"
  echo "Removed managed artifacts, config, and incident evidence."
else
  echo "Removed managed artifacts."
  echo "Kept /etc/jasper-watchdog (config) and /var/log/jasper-watchdog (incidents)."
  echo "Re-run with --purge to remove those too."
fi

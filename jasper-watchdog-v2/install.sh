#!/usr/bin/env bash
# Idempotent installer for jasper-watchdog-v2.
#
# Places managed artifacts into system paths, preserves existing config and
# pgpass, and prints a state-aware configuration checklist. Works from a git
# checkout or an extracted tarball; does not depend on git. Does NOT enable the
# timer — that is the operator's explicit go-live step.
#
# Usage:
#   sudo ./install.sh
#   DESTDIR=/tmp/stage bash install.sh   # staged/test install, no root needed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTDIR="${DESTDIR:-}"

# Ownership is only enforced on a real root install. Under DESTDIR (staging or
# tests) we skip chown so the script runs unprivileged.
own=()
if [[ -n "$DESTDIR" ]]; then
  own=()
elif [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  own=(-o root -g root)
else
  echo "ERROR: run as root, or set DESTDIR for a staged install." >&2
  exit 1
fi

etc_dir="$DESTDIR/etc/jasper-watchdog"
sbin_dir="$DESTDIR/usr/local/sbin"
systemd_dir="$DESTDIR/etc/systemd/system"
logrotate_dir="$DESTDIR/etc/logrotate.d"
tmpfiles_dir="$DESTDIR/etc/tmpfiles.d"
log_dir="$DESTDIR/var/log/jasper-watchdog"
incident_dir="$DESTDIR/var/log/jasper-watchdog/incidents"

# Verify every source artifact exists before touching the system.
required_sources=(
  jasper-watchdog-v2.sh
  jasper-watchdog.conf.example
  jasper-watchdog.service
  jasper-watchdog.timer
  logrotate-jasper-watchdog
  tmpfiles-jasper-watchdog.conf
)
for f in "${required_sources[@]}"; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    echo "ERROR: missing source file: $f" >&2
    exit 1
  fi
done

# Owned directories (mode enforced).
install -d -m 0750 "${own[@]}" "$etc_dir"
install -d -m 0750 "${own[@]}" "$log_dir"
install -d -m 0700 "${own[@]}" "$incident_dir"

# Standard system directories: create only when staging (they exist on a real
# host, and we must not alter their mode).
if [[ -n "$DESTDIR" ]]; then
  install -d "$sbin_dir" "$systemd_dir" "$logrotate_dir" "$tmpfiles_dir"
fi

# Managed artifacts — always overwritten.
install -m 0700 "${own[@]}" "$SCRIPT_DIR/jasper-watchdog-v2.sh"         "$sbin_dir/jasper-watchdog-v2"
install -m 0644 "${own[@]}" "$SCRIPT_DIR/jasper-watchdog.service"       "$systemd_dir/jasper-watchdog.service"
install -m 0644 "${own[@]}" "$SCRIPT_DIR/jasper-watchdog.timer"         "$systemd_dir/jasper-watchdog.timer"
install -m 0644 "${own[@]}" "$SCRIPT_DIR/logrotate-jasper-watchdog"     "$logrotate_dir/jasper-watchdog"
install -m 0644 "${own[@]}" "$SCRIPT_DIR/tmpfiles-jasper-watchdog.conf" "$tmpfiles_dir/jasper-watchdog.conf"

# Config: create from the example only if absent; never clobber operator edits.
conf="$etc_dir/jasper-watchdog.conf"
conf_created=0
if [[ -e "$conf" ]]; then
  echo "Preserved existing config: /etc/jasper-watchdog/jasper-watchdog.conf"
else
  install -m 0600 "${own[@]}" "$SCRIPT_DIR/jasper-watchdog.conf.example" "$conf"
  conf_created=1
fi
# Always refresh the example alongside it so operators can diff new options.
install -m 0600 "${own[@]}" "$SCRIPT_DIR/jasper-watchdog.conf.example" "$etc_dir/jasper-watchdog.conf.example"

# Reload systemd only on a real install.
if [[ -z "$DESTDIR" ]]; then
  systemctl daemon-reload
  systemd-tmpfiles --create /etc/tmpfiles.d/jasper-watchdog.conf
fi

# ---- State-aware configuration checklist ----
pgpass="$etc_dir/pgpass"
echo
echo "== Configuration required =="
if [[ "$conf_created" -eq 1 ]]; then
  echo "[!] jasper-watchdog.conf was created from the example. You MUST edit these"
  echo "    required values before enabling:"
  echo "      HEALTH_URL      - endpoint that proves JasperServer is alive"
  echo "      JASPER_SERVICE  - the actual systemd service name"
  echo "      JASPER_LOG_DIR  - the Tomcat/Jasper logs directory"
  echo "    Optional: HEALTH_BODY_MARKER, SLOW_RESPONSE_THRESHOLD_SEC,"
  echo "              ALERT_COMMAND, MAX_AUTORESTARTS, RESTART_WINDOW_SEC"
else
  echo "[ok] Kept existing jasper-watchdog.conf."
  echo "     Review new options in /etc/jasper-watchdog/jasper-watchdog.conf.example"
fi
echo
if [[ ! -e "$pgpass" ]]; then
  echo "[MISSING] /etc/jasper-watchdog/pgpass - create it (format host:port:database:user:password):"
  echo "    sudo sh -c 'umask 077; printf \"127.0.0.1:5432:jasperserver:jasper_watchdog:PASSWORD\\n\" > /etc/jasper-watchdog/pgpass'"
else
  mode="$(stat -c '%a' "$pgpass" 2>/dev/null || echo '')"
  if [[ -n "$mode" && "$mode" != "600" ]]; then
    echo "[warn] /etc/jasper-watchdog/pgpass mode is $mode; expected 600."
  else
    echo "[ok] /etc/jasper-watchdog/pgpass present."
  fi
fi
echo
echo "When configured, go live with:"
echo "    sudo systemctl enable --now jasper-watchdog.timer"

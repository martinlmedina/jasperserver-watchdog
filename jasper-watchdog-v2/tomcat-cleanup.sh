#!/usr/bin/env bash
# tomcat-cleanup.sh -- JasperServer / Tomcat disk hygiene.
#
# Companion to the JasperServer watchdog. Reclaims the junk that a busy
# JasperServer accumulates under apache-tomcat/{temp,logs} WITHOUT stopping the
# stack, so it never fights the watchdog: no ctlscript, no systemctl, no service
# restart. Everything is deleted strictly by age, so files still in use by a
# running Tomcat (in-flight report temp, the active JDBC driver jar, the open
# catalina.out) are never touched.
#
# What it cleans (all tunable below, all age-gated):
#   - JVM heap dumps (*.hprof) -- by far the biggest hog; these are dumped on
#     OutOfMemoryError and can be many GB each. Deleted once older than
#     HPROF_MAX_AGE_DAYS. Each removal is logged with its size because a fresh
#     dump is forensic evidence of an OOM.
#   - catalina.out -- truncated in place (never deleted) once it grows past
#     CATALINA_OUT_MAX_MB, preserving the inode/fd Tomcat is writing to.
#   - Rotated logs (catalina.<date>.log, localhost*, *access*, gc logs) older
#     than LOG_MAX_AGE_DAYS.
#   - Orphaned report temp (file.buff.os.*.tmp, +~JF*.tmp, temp/buffer/*) older
#     than TEMP_MAX_AGE_MIN -- the age guard protects reports running right now.
#   - Stale extracted JDBC driver jars (jdbc-*.jar); the copy belonging to the
#     running Tomcat instance is always kept (see clean_jdbc_jars).
#
# Never touches: catalina.pid, the temp/jasperserver/ app dir, work/, or the
# JDBC jar of the current instance.
#
# Usage:
#   tomcat-cleanup.sh            # clean
#   DRY_RUN=1 tomcat-cleanup.sh  # report what would be removed, delete nothing
#
# Safe to run from cron at any time while Tomcat is up.

set -uo pipefail
umask 077

now_utc() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

log() {
  printf '%s | %s\n' "$(now_utc)" "$*" | tee -a "$LOG_FILE"
}

# Render a byte count as a human-readable size for the summary line.
human() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB PB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    printf (i == 1 ? "%d%s" : "%.1f%s"), b, u[i]
  }'
}

# Delete (or, under DRY_RUN, report) every file produced by a find expression,
# accumulating the reclaimed byte count and item count into the globals. The
# find runs via process substitution -- NOT a pipe -- so the loop stays in the
# current shell and RECLAIMED_BYTES/COUNT survive it.
#   _purge <label> <dir> <find-predicate...>
_purge() {
  local label="$1" dir="$2"
  shift 2
  [[ -d "$dir" ]] || return 0

  local f size
  while IFS= read -r -d '' f; do
    size="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    RECLAIMED_BYTES=$(( ${RECLAIMED_BYTES:-0} + size ))
    COUNT=$(( ${COUNT:-0} + 1 ))
    if [[ "$DRY_RUN" == "1" ]]; then
      log "[$label] DRY_RUN would delete $f ($(human "$size"))"
    elif rm -f "$f"; then
      log "[$label] deleted $f ($(human "$size"))"
    else
      log "[$label] WARN could not delete $f"
    fi
  done < <(find "$dir" "$@" -print0 2>/dev/null)
}

clean_heapdumps() {
  _purge heapdump "$TEMP_DIR" \
    -maxdepth 1 -type f -name '*.hprof' -mmin +"$(( HPROF_MAX_AGE_DAYS * 1440 ))"
}

# Truncate catalina.out in place once it exceeds the threshold. Truncating
# (rather than rm) keeps the inode Tomcat holds open, so the running process
# keeps appending to the same file with no restart and space is reclaimed
# immediately.
clean_catalina_out() {
  local f="$LOG_DIR/catalina.out"
  [[ -f "$f" ]] || return 0

  local size max
  size="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
  max=$(( CATALINA_OUT_MAX_MB * 1024 * 1024 ))
  (( size > max )) || return 0

  if [[ "$DRY_RUN" == "1" ]]; then
    log "[catalina.out] DRY_RUN would truncate $f (currently $(human "$size"))"
    return 0
  fi

  if : > "$f"; then
    RECLAIMED_BYTES=$(( ${RECLAIMED_BYTES:-0} + size ))
    COUNT=$(( ${COUNT:-0} + 1 ))
    log "[catalina.out] truncated $f (was $(human "$size"))"
  else
    log "[catalina.out] WARN could not truncate $f"
  fi
}

clean_old_logs() {
  _purge old-logs "$LOG_DIR" \
    -maxdepth 1 -type f \
    \( -name 'catalina.*.log' \
       -o -name 'localhost.*.log' \
       -o -name 'localhost_access*.txt' \
       -o -name 'localhost_access*.log' \
       -o -name 'host-manager.*.log' \
       -o -name 'manager.*.log' \
       -o -name 'gc.log*' \
       -o -name '*.log.[0-9]*' \) \
    -mmin +"$(( LOG_MAX_AGE_DAYS * 1440 ))"
}

clean_report_temp() {
  _purge report-temp "$TEMP_DIR" \
    -maxdepth 1 -type f \
    \( -name 'file.buff.os.*.tmp' -o -name '+~JF*.tmp' \) \
    -mmin +"$TEMP_MAX_AGE_MIN"

  # temp/buffer/ holds nested per-report buffer files; clean by age, recursively.
  _purge temp-buffer "$TEMP_DIR/buffer" \
    -type f -mmin +"$TEMP_MAX_AGE_MIN"

  # Drop now-empty buffer subdirectories, but keep the buffer/ root itself.
  if [[ "$DRY_RUN" != "1" && -d "$TEMP_DIR/buffer" ]]; then
    find "$TEMP_DIR/buffer" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  fi
}

# JasperServer extracts each configured JDBC driver to temp/jdbc-<id>.jar on
# startup. Old copies from previous JVM instances pile up, but deleting the one
# the live Tomcat has loaded would break database access. We anchor "in use" to
# catalina.pid's mtime (written at startup): any jar as new as, or newer than,
# the pid file belongs to the current instance and is kept. If there is no pid
# file (Tomcat not running, or unusual layout) we fall back to protecting the
# single most recent jar. Everything older than that AND past JDBC_MAX_AGE_MIN
# is removed.
clean_jdbc_jars() {
  [[ -d "$TEMP_DIR" ]] || return 0

  local keep_boundary=0
  if [[ -f "$TEMP_DIR/catalina.pid" ]]; then
    keep_boundary="$(stat -c '%Y' "$TEMP_DIR/catalina.pid" 2>/dev/null || echo 0)"
  fi
  if (( keep_boundary == 0 )); then
    local newest
    newest="$(find "$TEMP_DIR" -maxdepth 1 -type f -name 'jdbc-*.jar' -printf '%T@\n' 2>/dev/null \
                | sort -rn | head -n 1)"
    keep_boundary="${newest%.*}"
    [[ -n "$keep_boundary" ]] || keep_boundary="$(date +%s)"
  fi

  local age_cutoff
  age_cutoff=$(( $(date +%s) - JDBC_MAX_AGE_MIN * 60 ))

  local f mtime size
  while IFS= read -r -d '' f; do
    mtime="$(stat -c '%Y' "$f" 2>/dev/null || echo 0)"
    # Keep the current instance's jar(s) and anything still inside the age window.
    (( mtime >= keep_boundary )) && continue
    (( mtime >= age_cutoff )) && continue
    size="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    RECLAIMED_BYTES=$(( ${RECLAIMED_BYTES:-0} + size ))
    COUNT=$(( ${COUNT:-0} + 1 ))
    if [[ "$DRY_RUN" == "1" ]]; then
      log "[jdbc-jar] DRY_RUN would delete $f ($(human "$size"))"
    elif rm -f "$f"; then
      log "[jdbc-jar] deleted $f ($(human "$size"))"
    else
      log "[jdbc-jar] WARN could not delete $f"
    fi
  done < <(find "$TEMP_DIR" -maxdepth 1 -type f -name 'jdbc-*.jar' -print0 2>/dev/null)
}

main() {
  TOMCAT_DIR="${TOMCAT_DIR:-/opt/jasperreports-server-cp-7.1.0/apache-tomcat}"
  TEMP_DIR="${TEMP_DIR:-$TOMCAT_DIR/temp}"
  LOG_DIR="${LOG_DIR:-$TOMCAT_DIR/logs}"
  HPROF_MAX_AGE_DAYS="${HPROF_MAX_AGE_DAYS:-3}"
  LOG_MAX_AGE_DAYS="${LOG_MAX_AGE_DAYS:-21}"
  TEMP_MAX_AGE_MIN="${TEMP_MAX_AGE_MIN:-720}"
  JDBC_MAX_AGE_MIN="${JDBC_MAX_AGE_MIN:-1440}"
  CATALINA_OUT_MAX_MB="${CATALINA_OUT_MAX_MB:-200}"
  DRY_RUN="${DRY_RUN:-0}"
  LOG_FILE="${LOG_FILE:-/var/log/tomcat-cleanup.log}"
  LOCK_FILE="${LOCK_FILE:-/run/lock/tomcat-cleanup.lock}"

  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true

  # One cleanup at a time; a slow run must not overlap the next cron tick.
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "$(now_utc) | another tomcat-cleanup run holds the lock; exiting" >&2
    exit 0
  fi

  RECLAIMED_BYTES=0
  COUNT=0

  log "=== tomcat-cleanup start (dry_run=$DRY_RUN tomcat=$TOMCAT_DIR) ==="
  if [[ ! -d "$TOMCAT_DIR" ]]; then
    log "ERROR TOMCAT_DIR does not exist: $TOMCAT_DIR"
    exit 1
  fi

  clean_heapdumps
  clean_catalina_out
  clean_old_logs
  clean_report_temp
  clean_jdbc_jars

  log "=== tomcat-cleanup done: ${COUNT} item(s), $(human "$RECLAIMED_BYTES") reclaimed (dry_run=$DRY_RUN) ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

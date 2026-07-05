#!/usr/bin/env bash
# JasperServer watchdog v2
# Captures a forensic snapshot before restarting the JasperServer service.

set -uo pipefail
umask 077

now_utc() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

write_global() {
  printf '%s | %s\n' "$(now_utc)" "$*" >> "$GLOBAL_LOG"
}

mark() {
  local line
  line="$(now_utc) | $*"
  printf '%s\n' "$line" >> "$GLOBAL_LOG"
  if [[ -n "$INCIDENT" ]]; then
    printf '%s\n' "$line" >> "$INCIDENT/incident.log"
  fi
}

expected_http_code() {
  local code="$1"
  [[ " $EXPECTED_HTTP_CODES " == *" $code "* ]]
}

health_probe() {
  local output rc code
  output="$(curl --noproxy '*' --location --silent --show-error \
      --output /dev/null \
      --write-out 'http_code=%{http_code} time_total=%{time_total} err=%{errormsg}' \
      --connect-timeout "$HEALTH_CONNECT_TIMEOUT_SEC" \
      --max-time "$HEALTH_MAX_TIME_SEC" \
      "$HEALTH_URL" 2>&1)"
  rc=$?
  code="$(sed -n 's/.*http_code=\([0-9][0-9][0-9]\).*/\1/p' <<< "$output" | tail -n1)"
  PROBE_RESULT="curl_rc=${rc}; ${output}"

  [[ "$rc" -eq 0 && -n "$code" ]] && expected_http_code "$code"
}

create_incident() {
  INCIDENT_ID="jasper_$(date -u +'%Y%m%dT%H%M%SZ')_pid$$"
  INCIDENT="$INCIDENT_ROOT/$INCIDENT_ID"
  mkdir -p "$INCIDENT"
  chmod 0700 "$INCIDENT"
  : > "$INCIDENT/incident.log"
  chmod 0600 "$INCIDENT/incident.log"
  mark "incident_id=$INCIDENT_ID"
  mark "event=confirmed_health_failure"
  mark "health_url=$HEALTH_URL"
  mark "first_probe=$FIRST_PROBE"
  mark "confirmation_probe=$CONFIRM_PROBE"
}

capture() {
  local filename="$1"
  shift
  local rc
  {
    echo "# started_utc=$(now_utc)"
    "$@"
    rc=$?
    echo "# exit_code=$rc"
    echo "# ended_utc=$(now_utc)"
  } > "$INCIDENT/$filename" 2>&1
  return 0
}

psql_snapshot() {
  local filename="$1"
  local sql="$2"
  local rc
  {
    echo "-- started_utc=$(now_utc)"
    echo "-- statement_timeout=${PG_STATEMENT_TIMEOUT_MS}ms lock_timeout=${PG_LOCK_TIMEOUT_MS}ms"
    PGCONNECT_TIMEOUT="$PG_CONNECT_TIMEOUT_SEC" PGPASSFILE="$PGPASSFILE" \
      timeout --signal=TERM --kill-after=2s "${CAPTURE_TIMEOUT_SEC}s" \
      psql -w -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
      -v ON_ERROR_STOP=1 -P pager=off <<SQL
SET statement_timeout = '${PG_STATEMENT_TIMEOUT_MS}ms';
SET lock_timeout = '${PG_LOCK_TIMEOUT_MS}ms';
${sql}
SQL
    rc=$?
    echo "-- exit_code=$rc"
    echo "-- ended_utc=$(now_utc)"
  } > "$INCIDENT/$filename" 2>&1
  return 0
}

capture_system_snapshot() {
  mark "phase=pre_restart_capture component=operating_system"
  capture os_uptime.txt bash -c 'uptime; echo; cat /proc/loadavg'
  capture os_memory.txt bash -c 'free -m; echo; vmstat 1 2'
  capture os_disk.txt bash -c 'df -hT; echo; df -ih'
  capture os_top_processes.txt bash -c 'ps -eo pid,ppid,user,%cpu,%mem,etime,stat,args --sort=-%cpu | head -n 70; echo; ps -eo pid,ppid,user,%cpu,%mem,etime,stat,args --sort=-%mem | head -n 70'
  capture os_network.txt bash -c 'ss -ltnp; echo; ss -tanp | head -n 250'
  capture service_status_before.txt systemctl status "$JASPER_SERVICE" --no-pager
  capture service_journal_before.txt journalctl -u "$JASPER_SERVICE" --since '-15 minutes' --no-pager
}

capture_jasper_logs() {
  mark "phase=pre_restart_capture component=jasper_logs"
  if [[ ! -d "$JASPER_LOG_DIR" ]]; then
    printf 'JASPER_LOG_DIR does not exist: %s\n' "$JASPER_LOG_DIR" > "$INCIDENT/jasper_logs_note.txt"
    return 0
  fi

  local file base
  shopt -s nullglob
  for file in "$JASPER_LOG_DIR"/catalina.out "$JASPER_LOG_DIR"/*.log "$JASPER_LOG_DIR"/localhost.*; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    capture "log_tail_${base}.txt" tail -n "$TAIL_LINES" "$file"
  done
  shopt -u nullglob
}

capture_thread_dump() {
  mark "phase=pre_restart_capture component=jvm_thread_dump"
  local java_pid
  java_pid="$(pgrep -f 'org.apache.catalina.startup.Bootstrap|jasperreports-server|catalina.base' | head -n1 || true)"

  if [[ -z "$java_pid" ]]; then
    printf 'No Jasper/Tomcat Java PID found.\n' > "$INCIDENT/jvm_thread_dump.txt"
    return 0
  fi

  printf 'java_pid=%s\n' "$java_pid" > "$INCIDENT/jvm_process.txt"
  ps -fp "$java_pid" >> "$INCIDENT/jvm_process.txt" 2>&1 || true

  if command -v jcmd >/dev/null 2>&1; then
    capture jvm_thread_dump.txt timeout --signal=TERM --kill-after=2s "${CAPTURE_TIMEOUT_SEC}s" jcmd "$java_pid" Thread.print -l
  elif command -v jstack >/dev/null 2>&1; then
    capture jvm_thread_dump.txt timeout --signal=TERM --kill-after=2s "${CAPTURE_TIMEOUT_SEC}s" jstack -l "$java_pid"
  else
    printf 'jcmd and jstack are not available; no JVM thread dump could be collected.\n' > "$INCIDENT/jvm_thread_dump.txt"
  fi
}

capture_postgres_snapshot() {
  mark "phase=pre_restart_capture component=postgresql"

  psql_snapshot pg_identity.txt "
SELECT now() AS snapshot_ts,
       version() AS postgresql_version,
       current_database() AS database_name,
       current_user AS monitoring_role,
       pg_is_in_recovery() AS is_replica;
"

  psql_snapshot pg_connection_summary.txt "
SELECT state,
       COALESCE(wait_event_type, '-') AS wait_event_type,
       COALESCE(wait_event, '-') AS wait_event,
       count(*) AS sessions
  FROM pg_stat_activity
 WHERE datname = current_database()
 GROUP BY state, wait_event_type, wait_event
 ORDER BY sessions DESC, state;
"

  psql_snapshot pg_active_sessions.txt "
SELECT a.pid,
       a.usename,
       COALESCE(a.application_name, '-') AS application_name,
       COALESCE(a.client_addr::text, '-') AS client_addr,
       a.state,
       COALESCE(a.wait_event_type, '-') AS wait_event_type,
       COALESCE(a.wait_event, '-') AS wait_event,
       COALESCE(age(now(), a.xact_start)::text, '-') AS transaction_age,
       COALESCE(age(now(), a.query_start)::text, '-') AS query_age,
       regexp_replace(left(COALESCE(a.query, ''), 2000), '''[^'']*''', '''?''', 'g') AS query_redacted
  FROM pg_stat_activity a
 WHERE a.datname = current_database()
   AND a.pid <> pg_backend_pid()
   AND (a.state <> 'idle' OR a.xact_start < now() - interval '2 minutes')
 ORDER BY a.xact_start NULLS LAST, a.query_start NULLS LAST;
"

  psql_snapshot pg_blocking_sessions.txt "
SELECT a.pid AS blocked_pid,
       pg_blocking_pids(a.pid) AS blocking_pids,
       a.usename AS blocked_user,
       COALESCE(a.application_name, '-') AS blocked_application,
       a.state AS blocked_state,
       COALESCE(a.wait_event_type, '-') AS wait_event_type,
       COALESCE(a.wait_event, '-') AS wait_event,
       COALESCE(age(now(), a.query_start)::text, '-') AS blocked_query_age,
       regexp_replace(left(COALESCE(a.query, ''), 1200), '''[^'']*''', '''?''', 'g') AS blocked_query_redacted
  FROM pg_stat_activity a
 WHERE a.datname = current_database()
   AND array_length(pg_blocking_pids(a.pid), 1) IS NOT NULL
 ORDER BY a.query_start;
"

  psql_snapshot pg_locks.txt "
SELECT l.pid,
       a.usename,
       COALESCE(a.application_name, '-') AS application_name,
       l.locktype,
       l.mode,
       l.granted,
       COALESCE(n.nspname || '.' || c.relname, '-') AS relation_name,
       COALESCE(age(now(), a.query_start)::text, '-') AS query_age,
       COALESCE(a.wait_event_type, '-') AS wait_event_type,
       COALESCE(a.wait_event, '-') AS wait_event
  FROM pg_locks l
  LEFT JOIN pg_stat_activity a ON a.pid = l.pid
  LEFT JOIN pg_class c ON c.oid = l.relation
  LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE a.datname = current_database()
 ORDER BY l.granted, a.query_start NULLS LAST, l.pid;
"

  psql_snapshot pg_database_stats.txt "
SELECT d.datname,
       d.numbackends,
       d.xact_commit,
       d.xact_rollback,
       d.blks_read,
       d.blks_hit,
       d.tup_returned,
       d.tup_fetched,
       d.tup_inserted,
       d.tup_updated,
       d.tup_deleted,
       d.temp_files,
       d.temp_bytes,
       d.deadlocks,
       pg_size_pretty(pg_database_size(d.datname)) AS database_size
  FROM pg_stat_database d
 WHERE d.datname = current_database();
"

  psql_snapshot pg_settings.txt "
SELECT name, setting, unit, source
  FROM pg_settings
 WHERE name IN ('max_connections', 'shared_buffers', 'work_mem',
                'maintenance_work_mem', 'statement_timeout',
                'lock_timeout', 'log_min_duration_statement',
                'track_activity_query_size')
 ORDER BY name;
"
}

capture_pre_restart() {
  capture_system_snapshot
  capture_jasper_logs
  capture_thread_dump
  capture_postgres_snapshot
  mark "phase=pre_restart_capture result=completed"
}

restart_service() {
  mark "phase=restart action=systemctl_restart service=$JASPER_SERVICE"
  capture restart_command.txt systemctl restart "$JASPER_SERVICE"
  RESTART_RC="$(tail -n 2 "$INCIDENT/restart_command.txt" | sed -n 's/^# exit_code=//p' | tail -n1)"
  mark "phase=restart result=command_finished exit_code=${RESTART_RC:-unknown}"
}

wait_for_recovery() {
  local deadline now
  deadline=$((SECONDS + RECOVERY_TIMEOUT_SEC))
  : > "$INCIDENT/recovery_checks.log"

  while (( SECONDS < deadline )); do
    if health_probe; then
      RECOVERY_PROBE="$PROBE_RESULT"
      mark "phase=post_restart_health result=recovered probe=$RECOVERY_PROBE"
      printf '%s | RECOVERED | %s\n' "$(now_utc)" "$RECOVERY_PROBE" >> "$INCIDENT/recovery_checks.log"
      return 0
    fi

    printf '%s | NOT_READY | %s\n' "$(now_utc)" "$PROBE_RESULT" >> "$INCIDENT/recovery_checks.log"
    sleep "$RECOVERY_RETRY_SEC"
  done

  RECOVERY_PROBE="$PROBE_RESULT"
  mark "phase=post_restart_health result=not_recovered probe=$RECOVERY_PROBE"
  return 1
}

write_summary() {
  local recovery_state="$1"
  {
    echo "# JasperServer watchdog incident"
    echo
    echo "- **Incident ID:** $INCIDENT_ID"
    echo "- **Detected UTC:** $(now_utc)"
    echo "- **Health URL:** $HEALTH_URL"
    echo "- **First failed probe:** $FIRST_PROBE"
    echo "- **Confirmation probe:** $CONFIRM_PROBE"
    echo "- **Restart command exit code:** ${RESTART_RC:-unknown}"
    echo "- **Recovery state:** $recovery_state"
    echo "- **Last recovery probe:** ${RECOVERY_PROBE:-not_evaluated}"
    echo
    echo "## Evidence captured before restart"
    echo
    echo "- OS health, memory, disk, processes and sockets"
    echo "- Jasper/Tomcat service status, journal and log tails"
    echo "- JVM thread dump when jcmd or jstack was available"
    echo "- PostgreSQL activity, waits, active transactions, blocking sessions, locks and database statistics"
    echo
    echo "All files in this directory are intentionally restricted because they may include operational metadata."
  } > "$INCIDENT/README.md"
  chmod 0600 "$INCIDENT/README.md"
}

main() {
  CONFIG_FILE="${CONFIG_FILE:-/etc/jasper-watchdog/jasper-watchdog.conf}"

  if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "ERROR: configuration file not found or not readable: $CONFIG_FILE" >&2
    exit 2
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  : "${HEALTH_URL:?HEALTH_URL is required}"
  : "${JASPER_SERVICE:?JASPER_SERVICE is required}"
  : "${INCIDENT_ROOT:?INCIDENT_ROOT is required}"
  : "${GLOBAL_LOG:?GLOBAL_LOG is required}"
  : "${PGHOST:?PGHOST is required}"
  : "${PGPORT:?PGPORT is required}"
  : "${PGDATABASE:?PGDATABASE is required}"
  : "${PGUSER:?PGUSER is required}"
  : "${PGPASSFILE:?PGPASSFILE is required}"

  EXPECTED_HTTP_CODES="${EXPECTED_HTTP_CODES:-200}"
  HEALTH_CONNECT_TIMEOUT_SEC="${HEALTH_CONNECT_TIMEOUT_SEC:-3}"
  HEALTH_MAX_TIME_SEC="${HEALTH_MAX_TIME_SEC:-10}"
  CONFIRM_DELAY_SEC="${CONFIRM_DELAY_SEC:-5}"
  CAPTURE_TIMEOUT_SEC="${CAPTURE_TIMEOUT_SEC:-8}"
  PG_CONNECT_TIMEOUT_SEC="${PG_CONNECT_TIMEOUT_SEC:-3}"
  PG_STATEMENT_TIMEOUT_MS="${PG_STATEMENT_TIMEOUT_MS:-3500}"
  PG_LOCK_TIMEOUT_MS="${PG_LOCK_TIMEOUT_MS:-800}"
  RECOVERY_TIMEOUT_SEC="${RECOVERY_TIMEOUT_SEC:-180}"
  RECOVERY_RETRY_SEC="${RECOVERY_RETRY_SEC:-3}"
  TAIL_LINES="${TAIL_LINES:-1200}"
  JASPER_LOG_DIR="${JASPER_LOG_DIR:-/opt/jasperreports-server-cp-7.1.0/apache-tomcat/logs}"

  mkdir -p "$INCIDENT_ROOT" "$(dirname "$GLOBAL_LOG")" /run/lock
  chmod 0700 "$INCIDENT_ROOT"
  touch "$GLOBAL_LOG"
  chmod 0640 "$GLOBAL_LOG"

  # One monitor execution at a time. This also protects against a manual run while
  # the systemd timer is active.
  exec 9>/run/lock/jasper-watchdog.lock
  if ! flock -n 9; then
    exit 0
  fi

  INCIDENT=""
  INCIDENT_ID=""
  INCIDENT_STATUS=""
  FIRST_PROBE=""
  CONFIRM_PROBE=""
  RESTART_RC=""
  RECOVERY_PROBE=""

  # First check. A single miss does not restart the service.
  if health_probe; then
    exit 0
  fi
  FIRST_PROBE="$PROBE_RESULT"
  write_global "event=health_probe_failed phase=first probe=$FIRST_PROBE"

  sleep "$CONFIRM_DELAY_SEC"
  if health_probe; then
    write_global "event=health_probe_recovered_without_restart first_probe=$FIRST_PROBE confirmation_probe=$PROBE_RESULT"
    exit 0
  fi
  CONFIRM_PROBE="$PROBE_RESULT"

  create_incident
  INCIDENT_STATUS="CAPTURING"
  capture_pre_restart
  restart_service

  if wait_for_recovery; then
    INCIDENT_STATUS="RECOVERED"
    write_summary "$INCIDENT_STATUS"
    mark "incident_status=$INCIDENT_STATUS"
    exit 0
  fi

  INCIDENT_STATUS="NOT_RECOVERED"
  write_summary "$INCIDENT_STATUS"
  mark "incident_status=$INCIDENT_STATUS"
  exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

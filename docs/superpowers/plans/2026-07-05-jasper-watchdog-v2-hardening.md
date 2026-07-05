# JasperServer Watchdog v2 Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden `jasper-watchdog-v2` with a restart circuit breaker, content/latency health validation, an extensible alert hook, cron/session evidence capture, and a bats-core test suite, while cleaning up repository hygiene — turning v2 into the single canonical, tested watchdog implementation.

**Architecture:** All behavior changes live in the single script `jasper-watchdog-v2/jasper-watchdog-v2.sh`. It is first refactored so its sequential entry-point logic lives in a `main()` function guarded by `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`, which lets bats tests `source` the file and call individual functions without triggering a real run (no config file, curl, psql, or systemctl required). Each subsequent task adds one function plus its config variables, wires it into `main()`, and adds bats tests using PATH-shadowing fixture scripts to stub `curl`, `crontab`, `ss`, `last`, and `who`.

**Tech Stack:** Bash (`set -uo pipefail`), bats-core for tests, git for version control.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-05-jasper-watchdog-v2-hardening-design.md`.
- `v1` (`jasper-watchdog-v1/`) is not modified — it remains frozen as historical documentation.
- Circuit breaker defaults match v1 exactly: `MAX_AUTORESTARTS=3`, `RESTART_WINDOW_SEC=900`.
- `HEALTH_BODY_MARKER` and `SLOW_RESPONSE_THRESHOLD_SEC` default to unset/empty — when unset, `health_probe()` behaves exactly as it does today (HTTP status code only). This is required for backward compatibility with existing deployments.
- `ALERT_COMMAND` defaults to unset (no-op). No specific alert channel (Slack/email/webhook body) is implemented — only the generic hook.
- `TOMCAT_SHUTDOWN_PORT` defaults to `8005`.
- Evidence capture must always run before the circuit breaker can block a restart — only the `systemctl restart` call itself is gated.
- Git: local `git init` only, no remote is configured or pushed to.
- No metrics/Prometheus/node_exporter export — explicitly out of scope per the spec.
- Every commit message ends with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.

---

### Task 1: Repository hygiene

**Files:**
- Create: `.gitignore` (project root)
- Create: `jasper-watchdog-v2/package.sh`
- Modify: `jasper-watchdog-v2/README.md`
- Delete: `jasper-watchdog-v2.sh` (project root)
- Delete: `jasper-watchdog-v2.tar.gz` (project root)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a git repository at the project root with one initial commit; `jasper-watchdog-v2/package.sh`, an executable script later tasks' README updates can reference.

- [ ] **Step 1: Remove the duplicate root-level copies**

Run from the project root (`c:\Users\marti\projects\JasperServer Watchdog`):

```bash
rm "jasper-watchdog-v2.sh" "jasper-watchdog-v2.tar.gz"
```

Expected: both files are gone. `jasper-watchdog-v2/jasper-watchdog-v2.sh` (the canonical copy) is untouched. Verify with:

```bash
ls jasper-watchdog-v2.sh jasper-watchdog-v2.tar.gz 2>&1
```

Expected output: `No such file or directory` for both.

- [ ] **Step 2: Create `.gitignore`**

```
*.tar.gz
```

- [ ] **Step 3: Create `jasper-watchdog-v2/package.sh`**

```bash
#!/usr/bin/env bash
# Builds a distributable tarball of jasper-watchdog-v2 on demand.
# The tarball itself is not committed to git (see .gitignore).
set -euo pipefail
cd "$(dirname "$0")"

tar -czf ../jasper-watchdog-v2.tar.gz \
  jasper-watchdog-v2.sh \
  jasper-watchdog.conf.example \
  jasper-watchdog.service \
  jasper-watchdog.timer \
  logrotate-jasper-watchdog \
  postgres-watchdog-role.sql \
  tmpfiles-jasper-watchdog.conf \
  README.md

echo "Built ../jasper-watchdog-v2.tar.gz"
```

Note: `tests/` is deliberately not in this list yet — it doesn't exist until Task 2. Task 6 (Step 9) adds it to this list once the test suite exists.

Then make it executable:

```bash
chmod +x jasper-watchdog-v2/package.sh
```

- [ ] **Step 4: Verify `package.sh` works, then clean up the generated artifact**

```bash
bash jasper-watchdog-v2/package.sh
ls jasper-watchdog-v2.tar.gz
rm jasper-watchdog-v2.tar.gz
```

Expected: the `Built ../jasper-watchdog-v2.tar.gz` message, then `ls` shows the file exists, then it's removed again (it's gitignored, but there's no reason to leave it in the working tree).

- [ ] **Step 5: Document `package.sh` in the README**

In `jasper-watchdog-v2/README.md`, find the code block that ends with this line, near the end of the "## 3. Install" section: `sudo install -m 0644 -o root -g root tmpfiles-jasper-watchdog.conf /etc/tmpfiles.d/jasper-watchdog.conf`

Add this new paragraph immediately after that code block's closing fence:

```

To produce a distributable tarball of this directory for copying to the target
server, run `./package.sh` from inside `jasper-watchdog-v2/`.
```

- [ ] **Step 6: Initialize git and make the first commit**

```bash
git init
git add -A
git status
```

Expected: `jasper-watchdog-v2.tar.gz` and the root-level `jasper-watchdog-v2.sh` do NOT appear in the staged files (the tarball is gitignored and never existed at that path; the duplicate script was deleted in Step 1).

```bash
git commit -m "$(cat <<'EOF'
chore: initialize repository, remove duplicate v2 packaging artifacts

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
git log --oneline
```

Expected: one commit, working tree clean afterwards (`git status` shows nothing to commit).

---

### Task 2: Testability refactor + bats test harness

**Files:**
- Modify: `jasper-watchdog-v2/jasper-watchdog-v2.sh` (full rewrite — structural only, no behavior change)
- Create: `jasper-watchdog-v2/tests/README.md`
- Create: `jasper-watchdog-v2/tests/test_expected_http_code.bats`

**Interfaces:**
- Consumes: the existing functions in `jasper-watchdog-v2.sh` (`now_utc`, `write_global`, `mark`, `expected_http_code`, `health_probe`, `create_incident`, `capture`, `psql_snapshot`, `capture_system_snapshot`, `capture_jasper_logs`, `capture_thread_dump`, `capture_postgres_snapshot`, `capture_pre_restart`, `restart_service`, `wait_for_recovery`, `write_summary`) — their bodies are unchanged, only their position in the file and their trigger mechanism change.
- Produces: a `main()` function containing all the sequential entry-point logic (config loading, validation, defaults, lock acquisition, probe/confirm/incident/restart/recovery flow), invoked only via `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` at the end of the file. Later tasks rely on being able to `source jasper-watchdog-v2.sh` in a bats test without it trying to read `/etc/jasper-watchdog/jasper-watchdog.conf` or acquiring the flock.

- [ ] **Step 1: Rewrite `jasper-watchdog-v2/jasper-watchdog-v2.sh`**

Replace the entire file with (function bodies are copied verbatim from the current file; only their order and the wrapping `main()` are new):

```bash
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
```

- [ ] **Step 2: Verify the refactor didn't break standalone execution**

```bash
bash -n jasper-watchdog-v2/jasper-watchdog-v2.sh
CONFIG_FILE=/nonexistent /usr/bin/env bash jasper-watchdog-v2/jasper-watchdog-v2.sh
echo "exit code: $?"
```

Expected: `bash -n` prints nothing (valid syntax). The second command prints `ERROR: configuration file not found or not readable: /nonexistent` to stderr and `exit code: 2` — identical to the pre-refactor behavior.

- [ ] **Step 3: Verify the refactor allows sourcing without side effects**

```bash
bash -c 'source jasper-watchdog-v2/jasper-watchdog-v2.sh; echo "sourced ok"; type expected_http_code >/dev/null && echo "function defined"'
```

Expected: prints `sourced ok` and `function defined`, with no attempt to read `/etc/jasper-watchdog/jasper-watchdog.conf` and no error (this is the mechanism every bats test in later tasks relies on).

- [ ] **Step 4: Create the bats test directory and its README**

Create `jasper-watchdog-v2/tests/README.md`:

```markdown
# jasper-watchdog-v2 tests

Unit tests use [bats-core](https://github.com/bats-core/bats-core).

## Install bats-core

- Debian/Ubuntu: `sudo apt-get install bats`
- macOS (Homebrew): `brew install bats-core`
- Any platform via npm: `npm install -g bats`
- From source: `git clone https://github.com/bats-core/bats-core.git && cd bats-core && sudo ./install.sh /usr/local`

## Run the suite

From `jasper-watchdog-v2/`:

    bats tests/

Each `*.bats` file sources `jasper-watchdog-v2.sh` directly. The script guards its
`main` entry point behind `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`, so sourcing it
only defines functions — no real JasperServer, PostgreSQL, or systemd is touched.
External commands (`curl`, `crontab`, `ss`, `last`, `who`) are stubbed by fixture
scripts under `tests/fixtures/`, which are prepended to `PATH` in each test's
`setup()`.
```

- [ ] **Step 5: Write the first (smoke) test**

Create `jasper-watchdog-v2/tests/test_expected_http_code.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
}

@test "expected_http_code matches a code in the list" {
  EXPECTED_HTTP_CODES="200 302"
  run expected_http_code "200"
  [ "$status" -eq 0 ]
}

@test "expected_http_code rejects a code not in the list" {
  EXPECTED_HTTP_CODES="200 302"
  run expected_http_code "500"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 6: Run the suite**

```bash
bats jasper-watchdog-v2/tests/
```

Expected: `2 tests, 0 failures`. If `bats` is not installed yet, install it per `tests/README.md` before proceeding — every later task depends on this harness working.

- [ ] **Step 7: Commit**

```bash
git add jasper-watchdog-v2/jasper-watchdog-v2.sh jasper-watchdog-v2/tests
git commit -m "$(cat <<'EOF'
refactor: make jasper-watchdog-v2.sh sourceable for testing

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Restart circuit breaker

**Files:**
- Modify: `jasper-watchdog-v2/jasper-watchdog-v2.sh`
- Modify: `jasper-watchdog-v2/jasper-watchdog.conf.example`
- Modify: `jasper-watchdog-v2/README.md`
- Create: `jasper-watchdog-v2/tests/test_circuit_breaker.bats`

**Interfaces:**
- Consumes: `main()`, `mark()`, `write_summary()` from Task 2.
- Produces: `take_restart_slot()` (returns 0 if a restart is allowed and records it, 1 if the breaker is tripped); globals `MAX_AUTORESTARTS`, `RESTART_WINDOW_SEC`, `RESTART_HISTORY_FILE`; `BLOCKED_CIRCUIT_BREAKER` as a possible `INCIDENT_STATUS` value.

- [ ] **Step 1: Write the failing tests**

Create `jasper-watchdog-v2/tests/test_circuit_breaker.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  RESTART_HISTORY_FILE="$(mktemp)"
  MAX_AUTORESTARTS=3
  RESTART_WINDOW_SEC=900
}

teardown() {
  rm -f "$RESTART_HISTORY_FILE"
}

@test "allows restarts up to the configured maximum" {
  run take_restart_slot
  [ "$status" -eq 0 ]
  run take_restart_slot
  [ "$status" -eq 0 ]
  run take_restart_slot
  [ "$status" -eq 0 ]
}

@test "blocks the restart once the maximum is reached within the window" {
  take_restart_slot
  take_restart_slot
  take_restart_slot
  run take_restart_slot
  [ "$status" -eq 1 ]
}

@test "does not count restarts older than the window" {
  local old_timestamp=$(( $(date +%s) - RESTART_WINDOW_SEC - 60 ))
  printf '%s\n' "$old_timestamp" > "$RESTART_HISTORY_FILE"
  take_restart_slot
  take_restart_slot
  run take_restart_slot
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
bats jasper-watchdog-v2/tests/test_circuit_breaker.bats
```

Expected: FAIL — `take_restart_slot: command not found` (function doesn't exist yet).

- [ ] **Step 3: Implement `take_restart_slot()`**

In `jasper-watchdog-v2/jasper-watchdog-v2.sh`, add this function immediately after `create_incident()` (before `capture()`):

```bash
take_restart_slot() {
  local now tmp_file count

  now=$(date +%s)
  tmp_file="$(mktemp "${RESTART_HISTORY_FILE}.XXXXXX")"

  awk -v now="$now" -v window="$RESTART_WINDOW_SEC" \
    '$1 ~ /^[0-9]+$/ && (now - $1) < window { print $1 }' \
    "$RESTART_HISTORY_FILE" > "$tmp_file" 2>/dev/null || true

  count=$(wc -l < "$tmp_file")

  if (( count >= MAX_AUTORESTARTS )); then
    mv "$tmp_file" "$RESTART_HISTORY_FILE"
    return 1
  fi

  printf '%s\n' "$now" >> "$tmp_file"
  mv "$tmp_file" "$RESTART_HISTORY_FILE"
  return 0
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
bats jasper-watchdog-v2/tests/test_circuit_breaker.bats
```

Expected: `3 tests, 0 failures`.

- [ ] **Step 5: Wire the circuit breaker into `main()`**

In `main()`, add the new defaults right after the `JASPER_LOG_DIR` default line:

```bash
  JASPER_LOG_DIR="${JASPER_LOG_DIR:-/opt/jasperreports-server-cp-7.1.0/apache-tomcat/logs}"
  MAX_AUTORESTARTS="${MAX_AUTORESTARTS:-3}"
  RESTART_WINDOW_SEC="${RESTART_WINDOW_SEC:-900}"
  RESTART_HISTORY_FILE="${RESTART_HISTORY_FILE:-$(dirname "$GLOBAL_LOG")/restart-history.log}"
```

Then, right after the `mkdir -p "$INCIDENT_ROOT" ...` / `touch "$GLOBAL_LOG"` block, add:

```bash
  touch "$RESTART_HISTORY_FILE"
```

so the full block reads:

```bash
  mkdir -p "$INCIDENT_ROOT" "$(dirname "$GLOBAL_LOG")" /run/lock
  chmod 0700 "$INCIDENT_ROOT"
  touch "$GLOBAL_LOG"
  chmod 0640 "$GLOBAL_LOG"
  touch "$RESTART_HISTORY_FILE"
```

Finally, replace this block in `main()`:

```bash
  create_incident
  INCIDENT_STATUS="CAPTURING"
  capture_pre_restart
  restart_service
```

with:

```bash
  create_incident
  INCIDENT_STATUS="CAPTURING"
  capture_pre_restart

  if ! take_restart_slot; then
    INCIDENT_STATUS="BLOCKED_CIRCUIT_BREAKER"
    mark "phase=circuit_breaker result=blocked max_autorestarts=$MAX_AUTORESTARTS window_sec=$RESTART_WINDOW_SEC"
    write_summary "$INCIDENT_STATUS"
    mark "incident_status=$INCIDENT_STATUS"
    exit 1
  fi

  restart_service
```

- [ ] **Step 6: Verify the whole suite still passes and the script is still valid**

```bash
bash -n jasper-watchdog-v2/jasper-watchdog-v2.sh
bats jasper-watchdog-v2/tests/
```

Expected: no syntax errors; all tests pass (5 total: 2 from Task 2 + 3 from this task).

- [ ] **Step 7: Add the config variables to `jasper-watchdog.conf.example`**

In `jasper-watchdog-v2/jasper-watchdog.conf.example`, find:

```
JASPER_SERVICE="jasperserver"
```

Replace with:

```
JASPER_SERVICE="jasperserver"

# Restart circuit breaker. Blocks further automatic restarts once the
# maximum is reached inside the time window; evidence is still captured
# even when the breaker blocks the restart. Defaults shown below.
MAX_AUTORESTARTS=3
RESTART_WINDOW_SEC=900
# RESTART_HISTORY_FILE="/var/log/jasper-watchdog/restart-history.log"
```

- [ ] **Step 8: Document the circuit breaker in the README**

At the end of `jasper-watchdog-v2/README.md`, after the last line (`This preserves the evidence needed to determine whether the root cause was Jasper/Tomcat, a blocked or saturated PostgreSQL workload, resource pressure, or the surrounding host.`), add:

```

## 7. Restart circuit breaker

`MAX_AUTORESTARTS` (default 3) and `RESTART_WINDOW_SEC` (default 900) bound how many
automatic restarts the watchdog performs inside a rolling time window. Evidence is
always captured before this check runs. Once the limit is reached, the watchdog marks
the incident `BLOCKED_CIRCUIT_BREAKER`, skips `systemctl restart`, and requires a human
to investigate and restart the service manually. Restart timestamps are tracked in a
state file next to `GLOBAL_LOG` (`restart-history.log` by default, overridable via
`RESTART_HISTORY_FILE`).
```

- [ ] **Step 9: Commit**

```bash
git add jasper-watchdog-v2/jasper-watchdog-v2.sh jasper-watchdog-v2/jasper-watchdog.conf.example jasper-watchdog-v2/README.md jasper-watchdog-v2/tests/test_circuit_breaker.bats
git commit -m "$(cat <<'EOF'
feat: add restart circuit breaker to jasper-watchdog-v2

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Alert hook

**Files:**
- Modify: `jasper-watchdog-v2/jasper-watchdog-v2.sh`
- Modify: `jasper-watchdog-v2/jasper-watchdog.conf.example`
- Modify: `jasper-watchdog-v2/README.md`
- Create: `jasper-watchdog-v2/tests/fixtures/fake-alert-command`
- Create: `jasper-watchdog-v2/tests/fixtures/fake-alert-command-failing`
- Create: `jasper-watchdog-v2/tests/test_notify_human.bats`

**Interfaces:**
- Consumes: `mark()` from Task 2; `create_incident()` and the circuit-breaker/`NOT_RECOVERED` branches in `main()` from Task 2/3.
- Produces: `notify_human(event, message)`; global `ALERT_COMMAND`.

- [ ] **Step 1: Create the fixture scripts**

Create `jasper-watchdog-v2/tests/fixtures/fake-alert-command`:

```bash
#!/usr/bin/env bash
printf 'event=%s message=%s\n' "$1" "$2" >> "$ALERT_LOG"
exit 0
```

Create `jasper-watchdog-v2/tests/fixtures/fake-alert-command-failing`:

```bash
#!/usr/bin/env bash
exit 1
```

Make both executable:

```bash
chmod +x jasper-watchdog-v2/tests/fixtures/fake-alert-command jasper-watchdog-v2/tests/fixtures/fake-alert-command-failing
```

- [ ] **Step 2: Write the failing tests**

Create `jasper-watchdog-v2/tests/test_notify_human.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  GLOBAL_LOG="$(mktemp)"
  INCIDENT=""
  ALERT_LOG="$(mktemp)"
  export ALERT_LOG
  ALERT_COMMAND="$BATS_TEST_DIRNAME/fixtures/fake-alert-command"
}

teardown() {
  rm -f "$GLOBAL_LOG" "$ALERT_LOG"
}

@test "does nothing when ALERT_COMMAND is unset" {
  unset ALERT_COMMAND
  run notify_human "test_event" "test message"
  [ "$status" -eq 0 ]
}

@test "invokes ALERT_COMMAND with event and message" {
  notify_human "incident_created" "hello world"
  run cat "$ALERT_LOG"
  [[ "$output" == *"event=incident_created"* ]]
  [[ "$output" == *"message=hello world"* ]]
}

@test "logs but does not fail when ALERT_COMMAND fails" {
  ALERT_COMMAND="$BATS_TEST_DIRNAME/fixtures/fake-alert-command-failing"
  run notify_human "incident_created" "hello world"
  [ "$status" -eq 0 ]
  run grep -c "alert_command_failed" "$GLOBAL_LOG"
  [ "$output" -eq 1 ]
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
bats jasper-watchdog-v2/tests/test_notify_human.bats
```

Expected: FAIL — `notify_human: command not found`.

- [ ] **Step 4: Implement `notify_human()`**

In `jasper-watchdog-v2/jasper-watchdog-v2.sh`, add this function immediately after `take_restart_slot()`:

```bash
notify_human() {
  local event="$1"
  local message="$2"

  if [[ -z "${ALERT_COMMAND:-}" ]]; then
    return 0
  fi

  if ! "$ALERT_COMMAND" "$event" "$message"; then
    mark "phase=notify_human result=alert_command_failed event=$event command=$ALERT_COMMAND"
  fi

  return 0
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
bats jasper-watchdog-v2/tests/test_notify_human.bats
```

Expected: `3 tests, 0 failures`.

- [ ] **Step 6: Wire `notify_human()` into `main()` at the three call sites**

Add the default in `main()`, right after the `RESTART_HISTORY_FILE` default line:

```bash
  ALERT_COMMAND="${ALERT_COMMAND:-}"
```

In `create_incident()`, add a call after the existing `mark` lines, so the function ends with:

```bash
  mark "confirmation_probe=$CONFIRM_PROBE"
  notify_human "incident_created" "JasperServer watchdog incident $INCIDENT_ID: confirmed health failure. See $INCIDENT"
}
```

In `main()`, in the circuit-breaker-blocked branch from Task 3, add the notify call so it reads:

```bash
  if ! take_restart_slot; then
    INCIDENT_STATUS="BLOCKED_CIRCUIT_BREAKER"
    mark "phase=circuit_breaker result=blocked max_autorestarts=$MAX_AUTORESTARTS window_sec=$RESTART_WINDOW_SEC"
    notify_human "circuit_breaker_tripped" "JasperServer watchdog: circuit breaker blocked automatic restart for incident $INCIDENT_ID after $MAX_AUTORESTARTS restarts in ${RESTART_WINDOW_SEC}s"
    write_summary "$INCIDENT_STATUS"
    mark "incident_status=$INCIDENT_STATUS"
    exit 1
  fi
```

At the end of `main()`, in the `NOT_RECOVERED` branch, add the notify call so it reads:

```bash
  INCIDENT_STATUS="NOT_RECOVERED"
  notify_human "recovery_failed" "JasperServer watchdog: incident $INCIDENT_ID restarted $JASPER_SERVICE but health did not recover within ${RECOVERY_TIMEOUT_SEC}s"
  write_summary "$INCIDENT_STATUS"
  mark "incident_status=$INCIDENT_STATUS"
  exit 1
```

- [ ] **Step 7: Verify the whole suite still passes**

```bash
bash -n jasper-watchdog-v2/jasper-watchdog-v2.sh
bats jasper-watchdog-v2/tests/
```

Expected: no syntax errors; 8 tests total, 0 failures.

- [ ] **Step 8: Add the config variable to `jasper-watchdog.conf.example`**

Append at the end of `jasper-watchdog-v2/jasper-watchdog.conf.example`:

```

# Optional alert hook. Leave unset to disable. When set, this command is
# executed as: "$ALERT_COMMAND" "<event>" "<message>" on incident_created,
# circuit_breaker_tripped, and recovery_failed. Wire it to Slack, email, or
# any paging system.
# ALERT_COMMAND="/usr/local/sbin/jasper-watchdog-notify.sh"
```

- [ ] **Step 9: Document the alert hook in the README**

After the "## 7. Restart circuit breaker" section added in Task 3, add:

```

## 8. Alerting hook

Set `ALERT_COMMAND` in `jasper-watchdog.conf` to the path of an executable. The watchdog
calls it as `"$ALERT_COMMAND" "<event>" "<message>"` on three events: `incident_created`,
`circuit_breaker_tripped`, and `recovery_failed`. Leave it unset to disable alerting; a
failing `ALERT_COMMAND` is logged but never blocks the watchdog. Wire it to Slack,
email, or any paging system outside this script.
```

- [ ] **Step 10: Commit**

```bash
git add jasper-watchdog-v2/jasper-watchdog-v2.sh jasper-watchdog-v2/jasper-watchdog.conf.example jasper-watchdog-v2/README.md jasper-watchdog-v2/tests/test_notify_human.bats jasper-watchdog-v2/tests/fixtures/fake-alert-command jasper-watchdog-v2/tests/fixtures/fake-alert-command-failing
git commit -m "$(cat <<'EOF'
feat: add extensible alert hook to jasper-watchdog-v2

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Content and latency health validation

**Files:**
- Modify: `jasper-watchdog-v2/jasper-watchdog-v2.sh`
- Modify: `jasper-watchdog-v2/jasper-watchdog.conf.example`
- Modify: `jasper-watchdog-v2/README.md`
- Create: `jasper-watchdog-v2/tests/fixtures/curl`
- Create: `jasper-watchdog-v2/tests/test_health_probe.bats`

**Interfaces:**
- Consumes: `expected_http_code()` and the `PROBE_RESULT` global convention from Task 2.
- Produces: a modified `health_probe()` supporting optional `HEALTH_BODY_MARKER` and `SLOW_RESPONSE_THRESHOLD_SEC`; a new `float_gt()` helper.

- [ ] **Step 1: Create the `curl` fixture**

Create `jasper-watchdog-v2/tests/fixtures/curl`:

```bash
#!/usr/bin/env bash
# Fake curl for bats tests: emits controllable canned responses via
# FAKE_CURL_RC, FAKE_CURL_HTTP_CODE, FAKE_CURL_TIME_TOTAL, FAKE_CURL_BODY,
# FAKE_CURL_ERR environment variables.
output_path=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--output" ]]; then
    output_path="${args[$((i + 1))]}"
  fi
done

printf '%s' "${FAKE_CURL_BODY:-}" > "$output_path"
printf 'http_code=%s time_total=%s err=%s' \
  "${FAKE_CURL_HTTP_CODE:-200}" "${FAKE_CURL_TIME_TOTAL:-0.100}" "${FAKE_CURL_ERR:-}"
exit "${FAKE_CURL_RC:-0}"
```

Make it executable:

```bash
chmod +x jasper-watchdog-v2/tests/fixtures/curl
```

- [ ] **Step 2: Write the failing tests**

Create `jasper-watchdog-v2/tests/test_health_probe.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  HEALTH_URL="http://example.invalid/health"
  HEALTH_CONNECT_TIMEOUT_SEC=3
  HEALTH_MAX_TIME_SEC=10
  EXPECTED_HTTP_CODES="200 302"
  HEALTH_BODY_MARKER=""
  SLOW_RESPONSE_THRESHOLD_SEC=""
  export FAKE_CURL_RC=0
  export FAKE_CURL_HTTP_CODE=200
  export FAKE_CURL_TIME_TOTAL=0.100
  export FAKE_CURL_BODY=""
  export FAKE_CURL_ERR=""
}

@test "succeeds on an expected HTTP code with no marker or threshold configured" {
  run health_probe
  [ "$status" -eq 0 ]
}

@test "fails on an unexpected HTTP code" {
  FAKE_CURL_HTTP_CODE=500
  run health_probe
  [ "$status" -eq 1 ]
}

@test "succeeds when the configured body marker is present" {
  HEALTH_BODY_MARKER="MONITOR"
  FAKE_CURL_BODY="...MONITOR..."
  run health_probe
  [ "$status" -eq 0 ]
}

@test "fails when the configured body marker is absent" {
  HEALTH_BODY_MARKER="MONITOR"
  FAKE_CURL_BODY="<html>login</html>"
  run health_probe
  [ "$status" -eq 1 ]
}

@test "fails when the response is slower than the configured threshold" {
  SLOW_RESPONSE_THRESHOLD_SEC="4"
  FAKE_CURL_TIME_TOTAL=7.5
  run health_probe
  [ "$status" -eq 1 ]
}

@test "succeeds when the response is under the configured threshold" {
  SLOW_RESPONSE_THRESHOLD_SEC="4"
  FAKE_CURL_TIME_TOTAL=1.2
  run health_probe
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
bats jasper-watchdog-v2/tests/test_health_probe.bats
```

Expected: the marker and threshold tests FAIL (current `health_probe()` ignores `HEALTH_BODY_MARKER`/`SLOW_RESPONSE_THRESHOLD_SEC`); the plain status-code tests pass already.

- [ ] **Step 4: Implement the enhanced `health_probe()`**

In `jasper-watchdog-v2/jasper-watchdog-v2.sh`, add `float_gt()` immediately before `health_probe()`:

```bash
float_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}
```

Replace the existing `health_probe()` function body with:

```bash
health_probe() {
  local output rc code time_total body_file marker_found

  body_file="/dev/null"
  if [[ -n "${HEALTH_BODY_MARKER:-}" ]]; then
    body_file="$(mktemp)"
  fi

  output="$(curl --noproxy '*' --location --silent --show-error \
      --output "$body_file" \
      --write-out 'http_code=%{http_code} time_total=%{time_total} err=%{errormsg}' \
      --connect-timeout "$HEALTH_CONNECT_TIMEOUT_SEC" \
      --max-time "$HEALTH_MAX_TIME_SEC" \
      "$HEALTH_URL" 2>&1)"
  rc=$?
  code="$(sed -n 's/.*http_code=\([0-9][0-9][0-9]\).*/\1/p' <<< "$output" | tail -n1)"
  time_total="$(sed -n 's/.*time_total=\([0-9.]*\).*/\1/p' <<< "$output" | tail -n1)"
  PROBE_RESULT="curl_rc=${rc}; ${output}"

  if [[ "$rc" -ne 0 || -z "$code" ]] || ! expected_http_code "$code"; then
    [[ "$body_file" != "/dev/null" ]] && rm -f "$body_file"
    return 1
  fi

  if [[ -n "${HEALTH_BODY_MARKER:-}" ]]; then
    marker_found=0
    grep -Fq -- "$HEALTH_BODY_MARKER" "$body_file" && marker_found=1
    rm -f "$body_file"
    if [[ "$marker_found" -ne 1 ]]; then
      PROBE_RESULT="${PROBE_RESULT}; body_marker_missing=${HEALTH_BODY_MARKER}"
      return 1
    fi
  fi

  if [[ -n "${SLOW_RESPONSE_THRESHOLD_SEC:-}" && -n "$time_total" ]] && float_gt "$time_total" "$SLOW_RESPONSE_THRESHOLD_SEC"; then
    PROBE_RESULT="${PROBE_RESULT}; slow_response_threshold_exceeded=${SLOW_RESPONSE_THRESHOLD_SEC}"
    return 1
  fi

  return 0
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
bats jasper-watchdog-v2/tests/test_health_probe.bats
```

Expected: `6 tests, 0 failures`.

- [ ] **Step 6: Wire the new defaults into `main()`**

Add the two new optional defaults right after the `ALERT_COMMAND` default line:

```bash
  HEALTH_BODY_MARKER="${HEALTH_BODY_MARKER:-}"
  SLOW_RESPONSE_THRESHOLD_SEC="${SLOW_RESPONSE_THRESHOLD_SEC:-}"
```

- [ ] **Step 7: Verify the whole suite still passes**

```bash
bash -n jasper-watchdog-v2/jasper-watchdog-v2.sh
bats jasper-watchdog-v2/tests/
```

Expected: no syntax errors; 14 tests total, 0 failures.

- [ ] **Step 8: Add the config variables to `jasper-watchdog.conf.example`**

In `jasper-watchdog-v2/jasper-watchdog.conf.example`, find:

```
EXPECTED_HTTP_CODES="200 302"
```

Replace with:

```
EXPECTED_HTTP_CODES="200 302"

# Optional content and latency validation. Leave both unset to keep
# validating only the HTTP status code (previous behavior).
# HEALTH_BODY_MARKER="MONITOR"
# SLOW_RESPONSE_THRESHOLD_SEC=4
```

- [ ] **Step 9: Document the new health check options in the README**

In `jasper-watchdog-v2/README.md`, find this bullet in "## 3. Install":

```
- `HEALTH_URL`: a JasperServer endpoint that proves the application is alive. Do not leave a mere port check as the only health condition.
```

Replace with:

```
- `HEALTH_URL`: a JasperServer endpoint that proves the application is alive. Do not leave a mere port check as the only health condition. Optionally set `HEALTH_BODY_MARKER` to a string that must appear in the response body, and `SLOW_RESPONSE_THRESHOLD_SEC` to treat a slow-but-200 response as a failure. Both are unset by default, matching the previous status-code-only behavior.
```

- [ ] **Step 10: Commit**

```bash
git add jasper-watchdog-v2/jasper-watchdog-v2.sh jasper-watchdog-v2/jasper-watchdog.conf.example jasper-watchdog-v2/README.md jasper-watchdog-v2/tests/test_health_probe.bats jasper-watchdog-v2/tests/fixtures/curl
git commit -m "$(cat <<'EOF'
feat: validate response content and latency in health_probe

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Cron and session evidence capture

**Files:**
- Modify: `jasper-watchdog-v2/jasper-watchdog-v2.sh`
- Modify: `jasper-watchdog-v2/jasper-watchdog.conf.example`
- Modify: `jasper-watchdog-v2/README.md`
- Create: `jasper-watchdog-v2/tests/fixtures/crontab`
- Create: `jasper-watchdog-v2/tests/fixtures/ss`
- Create: `jasper-watchdog-v2/tests/fixtures/last`
- Create: `jasper-watchdog-v2/tests/fixtures/who`
- Create: `jasper-watchdog-v2/tests/test_capture_cron_and_sessions.bats`

**Interfaces:**
- Consumes: `capture()`, `mark()`, `capture_pre_restart()` from Task 2.
- Produces: `capture_cron_and_sessions()` wired into `capture_pre_restart()`; global `TOMCAT_SHUTDOWN_PORT`; incident evidence file `cron_and_sessions.txt`.

- [ ] **Step 1: Create the fixture scripts**

Create `jasper-watchdog-v2/tests/fixtures/crontab`:

```bash
#!/usr/bin/env bash
echo "0 13 * * * /home/opc/script/limpiar_tomcat.sh"
```

Create `jasper-watchdog-v2/tests/fixtures/ss`:

```bash
#!/usr/bin/env bash
echo 'LISTEN 0 100 127.0.0.1:8005 0.0.0.0:* users:(("java",pid=123,fd=45))'
```

Create `jasper-watchdog-v2/tests/fixtures/last`:

```bash
#!/usr/bin/env bash
echo "opc pts/0 10.0.0.5 Sun Jul 5 10:00 still logged in"
```

Create `jasper-watchdog-v2/tests/fixtures/who`:

```bash
#!/usr/bin/env bash
echo "opc pts/0 2026-07-05 10:00"
```

Make them all executable:

```bash
chmod +x jasper-watchdog-v2/tests/fixtures/crontab jasper-watchdog-v2/tests/fixtures/ss jasper-watchdog-v2/tests/fixtures/last jasper-watchdog-v2/tests/fixtures/who
```

- [ ] **Step 2: Write the failing test**

Create `jasper-watchdog-v2/tests/test_capture_cron_and_sessions.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  INCIDENT="$(mktemp -d)"
  GLOBAL_LOG="$(mktemp)"
  TOMCAT_SHUTDOWN_PORT=8005
}

teardown() {
  rm -rf "$INCIDENT"
  rm -f "$GLOBAL_LOG"
}

@test "writes cron_and_sessions.txt with all evidence sections" {
  capture_cron_and_sessions
  [ -f "$INCIDENT/cron_and_sessions.txt" ]
  run cat "$INCIDENT/cron_and_sessions.txt"
  [[ "$output" == *"crontab -l (root)"* ]]
  [[ "$output" == *"other user crontabs"* ]]
  [[ "$output" == *"listening sockets on shutdown-related ports"* ]]
  [[ "$output" == *"last 20 logins"* ]]
  [[ "$output" == *"who is currently logged in"* ]]
  [[ "$output" == *"limpiar_tomcat.sh"* ]]
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
bats jasper-watchdog-v2/tests/test_capture_cron_and_sessions.bats
```

Expected: FAIL — `capture_cron_and_sessions: command not found`.

- [ ] **Step 4: Implement `capture_cron_and_sessions()`**

In `jasper-watchdog-v2/jasper-watchdog-v2.sh`, add this function immediately after `capture_thread_dump()` (before `capture_postgres_snapshot()`):

```bash
capture_cron_and_sessions() {
  mark "phase=pre_restart_capture component=cron_and_sessions"
  capture cron_and_sessions.txt bash -c '
    echo "== crontab -l (root) =="
    crontab -l -u root 2>&1 || echo "no crontab for root"
    echo
    echo "== other user crontabs (/var/spool/cron) =="
    if [[ -d /var/spool/cron ]]; then
      for spool_file in /var/spool/cron/crontabs/* /var/spool/cron/*; do
        [[ -f "$spool_file" ]] || continue
        echo "--- $spool_file ---"
        cat "$spool_file" 2>&1
      done
    else
      echo "/var/spool/cron not found"
    fi
    echo
    echo "== listening sockets on shutdown-related ports =="
    ss -tlnp 2>&1 | grep -E ":(${TOMCAT_SHUTDOWN_PORT})\b" || echo "no listener found on port ${TOMCAT_SHUTDOWN_PORT}"
    echo
    echo "== last 20 logins =="
    last -n 20 2>&1 || echo "last command unavailable"
    echo
    echo "== who is currently logged in =="
    who 2>&1 || echo "who command unavailable"
  '
}
```

Then wire it into `capture_pre_restart()`, replacing:

```bash
capture_pre_restart() {
  capture_system_snapshot
  capture_jasper_logs
  capture_thread_dump
  capture_postgres_snapshot
  mark "phase=pre_restart_capture result=completed"
}
```

with:

```bash
capture_pre_restart() {
  capture_system_snapshot
  capture_jasper_logs
  capture_thread_dump
  capture_cron_and_sessions
  capture_postgres_snapshot
  mark "phase=pre_restart_capture result=completed"
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
bats jasper-watchdog-v2/tests/test_capture_cron_and_sessions.bats
```

Expected: `1 test, 0 failures`.

- [ ] **Step 6: Wire the new default into `main()`**

Add the new default right after the `SLOW_RESPONSE_THRESHOLD_SEC` default line:

```bash
  TOMCAT_SHUTDOWN_PORT="${TOMCAT_SHUTDOWN_PORT:-8005}"
```

- [ ] **Step 7: Verify the whole suite still passes**

```bash
bash -n jasper-watchdog-v2/jasper-watchdog-v2.sh
bats jasper-watchdog-v2/tests/
```

Expected: no syntax errors; 15 tests total, 0 failures.

- [ ] **Step 8: Add the config variable to `jasper-watchdog.conf.example`**

In `jasper-watchdog-v2/jasper-watchdog.conf.example`, find:

```
JASPER_LOG_DIR="/opt/jasperreports-server-cp-7.1.0/apache-tomcat/logs"
```

Replace with:

```
JASPER_LOG_DIR="/opt/jasperreports-server-cp-7.1.0/apache-tomcat/logs"

# Tomcat's shutdown port, used to capture who is listening on it as part of
# the pre-restart evidence (helps confirm whether a shutdown was triggered
# locally, e.g. by a cron job).
TOMCAT_SHUTDOWN_PORT=8005
```

- [ ] **Step 9: Update the incident tree diagram, add `tests/` to `package.sh`, and verify**

In `jasper-watchdog-v2/README.md`, find the incident directory tree near the top:

```
    jvm_thread_dump.txt
    pg_*.txt
    restart_command.txt
```

Replace with:

```
    jvm_thread_dump.txt
    cron_and_sessions.txt
    pg_*.txt
    restart_command.txt
```

Now that `jasper-watchdog-v2/tests/` exists (created in Task 2), add it to the packaging list. In `jasper-watchdog-v2/package.sh`, find:

```
  tmpfiles-jasper-watchdog.conf \
  README.md
```

Replace with:

```
  tmpfiles-jasper-watchdog.conf \
  README.md \
  tests
```

Then verify:

```bash
bash jasper-watchdog-v2/package.sh
tar -tzf jasper-watchdog-v2.tar.gz | grep '^tests/' | head -5
rm jasper-watchdog-v2.tar.gz
```

Expected: the tarball lists files under `tests/`, confirming the packaging script includes the test suite; then the generated tarball is removed again.

- [ ] **Step 10: Commit**

```bash
git add jasper-watchdog-v2/jasper-watchdog-v2.sh jasper-watchdog-v2/jasper-watchdog.conf.example jasper-watchdog-v2/README.md jasper-watchdog-v2/package.sh jasper-watchdog-v2/tests/test_capture_cron_and_sessions.bats jasper-watchdog-v2/tests/fixtures/crontab jasper-watchdog-v2/tests/fixtures/ss jasper-watchdog-v2/tests/fixtures/last jasper-watchdog-v2/tests/fixtures/who
git commit -m "$(cat <<'EOF'
feat: capture cron jobs and session evidence before restart

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

# Component-Aware Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the watchdog's blind (and non-functional, since no systemd unit backs JasperServer) `systemctl restart` with a component-aware recovery sequence built on `ctlscript.sh` and `pg_isready`, matching the design in [docs/2026-07-05-jasper-watchdog-v2-component-recovery-design.md](../../2026-07-05-jasper-watchdog-v2-component-recovery-design.md).

**Architecture:** A new `diagnose()` function parses per-component state (`postgresql`/`tomcat`) from `ctlscript.sh status` plus a real `pg_isready` connectivity check. `recover_postgres()`/`recover_tomcat()` apply the minimal correct action per component (start if down, always restart Tomcat if it's up but unhealthy — we only reach recovery after a confirmed health failure). `run_recovery()` orchestrates: surgical recovery → wait for HTTP health → escalate to `ctlscript.sh restart` (whole stack) if `ESCALATE_TO_FULL_RESTART=1` and still unhealthy. All new behavior is bats-tested against fake `ctlscript`/`pg_isready` fixtures that log invocations for order/argument assertions, following the existing fixture pattern in `tests/fixtures/`.

**Tech Stack:** Bash (`set -uo pipefail`), bats-core for tests, `timeout`/`flock` for process control — all already in use in this codebase.

## Global Constraints

- No systemd unit exists for JasperServer on the production host; it is controlled exclusively via `/opt/jasperreports-server-cp-7.1.0/ctlscript.sh`. Do not reintroduce `systemctl`/`journalctl` calls against `$JASPER_SERVICE` anywhere in the recovery or capture paths.
- Default paths/values (must match production): `JASPER_HOME=/opt/jasperreports-server-cp-7.1.0`, `CTLSCRIPT=$JASPER_HOME/ctlscript.sh`, `PG_ISREADY_BIN=$JASPER_HOME/postgresql/bin/pg_isready`, `PG_COMPONENT=postgresql`, `TOMCAT_COMPONENT=tomcat`, `CTL_ACTION_TIMEOUT_SEC=120`, `PG_READY_TIMEOUT_SEC=60`, `PG_READY_RETRY_SEC=3`, `ESCALATE_TO_FULL_RESTART=1`.
- `HEALTH_BODY_MARKER="MONITOR"` and `SLOW_RESPONSE_THRESHOLD_SEC=4` must become active defaults in `jasper-watchdog.conf.example` (previously shipped commented-out) — required to detect the "200 but slow/hung" failure mode this project targets.
- `recover_tomcat()` always acts: start if the process is down, `restart` if it is up (a running Tomcat is unhealthy by definition once we reach recovery, whether from a broken JDBC pool after a DB outage or from being slow/hung on its own).
- Every `ctlscript.sh` invocation is wrapped in `timeout --signal=TERM --kill-after=2s "${CTL_ACTION_TIMEOUT_SEC}s"`, matching the existing pattern in `psql_snapshot()`.
- An unparseable component status line is treated as **down** (fail-safe: prefer attempting a start).
- The restart circuit breaker (`take_restart_slot`) is consulted exactly once per incident, before any recovery action — this is already guaranteed structurally by `main()` calling it once, and recovery functions must never call it.
- Follow the existing fixture pattern: fake executables under `tests/fixtures/`, controlled via exported environment variables, invocations logged to a file the test inspects (see `tests/fixtures/curl`, `tests/fixtures/fake-alert-command`).
- Run tests from `jasper-watchdog-v2/` with `bats tests/`. `bats` is available in this environment (Git Bash on Windows, confirmed via `bats --version` → 1.13.0). Note: `test_install.bats`/`test_uninstall.bats` are already failing in this shell due to Windows `chmod`/permission semantics unrelated to this work — ignore their pre-existing failures and focus on the new/modified test files.

---

## Reference: current file locations

- Script under test: `jasper-watchdog-v2/jasper-watchdog-v2.sh`
- Config template: `jasper-watchdog-v2/jasper-watchdog.conf.example`
- Installer: `jasper-watchdog-v2/install.sh`
- Docs: `jasper-watchdog-v2/README.md`
- Tests: `jasper-watchdog-v2/tests/*.bats`
- Fixtures: `jasper-watchdog-v2/tests/fixtures/*`

All commands below assume the working directory is `jasper-watchdog-v2/` unless stated otherwise.

---

### Task 1: Fake `ctlscript` and `pg_isready` test fixtures

**Files:**
- Create: `jasper-watchdog-v2/tests/fixtures/ctlscript`
- Create: `jasper-watchdog-v2/tests/fixtures/pg_isready`

**Interfaces:**
- Produces: an executable `tests/fixtures/ctlscript` that, when `CTLSCRIPT_LOG` is exported, appends one line per invocation (`"$*"`, e.g. `status`, `start postgresql`, `restart tomcat`, `restart`) to that file, then on `status` prints two lines shaped like `tomcat already running` / `postgresql not running` controlled by `FAKE_TOMCAT_STATUS`/`FAKE_PG_STATUS` (`running`, `stopped`, or anything else for an unparseable line), and exits with `FAKE_CTLSCRIPT_RC` (default `0`).
- Produces: an executable `tests/fixtures/pg_isready` that exits with `FAKE_PG_ISREADY_RC` (default `0`).

- [ ] **Step 1: Create the fake `ctlscript` fixture**

```bash
cat > tests/fixtures/ctlscript <<'EOF'
#!/usr/bin/env bash
# Fake ctlscript.sh for bats tests. Logs every invocation (one line per
# call, space-joined arguments) to CTLSCRIPT_LOG when set, and emits a
# controllable `status` output via FAKE_TOMCAT_STATUS/FAKE_PG_STATUS
# ("running", "stopped", or anything else to simulate an unparseable
# line). Exit code controlled via FAKE_CTLSCRIPT_RC.
if [[ -n "${CTLSCRIPT_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$CTLSCRIPT_LOG"
fi

if [[ "${1:-}" == "status" ]]; then
  case "${FAKE_TOMCAT_STATUS:-running}" in
    running) echo "tomcat already running" ;;
    stopped) echo "tomcat not running" ;;
    *) echo "tomcat: unable to determine status" ;;
  esac
  case "${FAKE_PG_STATUS:-running}" in
    running) echo "postgresql already running" ;;
    stopped) echo "postgresql not running" ;;
    *) echo "postgresql: unable to determine status" ;;
  esac
fi

exit "${FAKE_CTLSCRIPT_RC:-0}"
EOF
chmod +x tests/fixtures/ctlscript
```

- [ ] **Step 2: Create the fake `pg_isready` fixture**

```bash
cat > tests/fixtures/pg_isready <<'EOF'
#!/usr/bin/env bash
# Fake pg_isready for bats tests. Controlled via FAKE_PG_ISREADY_RC:
# 0 = accepting connections (default), non-zero = not ready.
exit "${FAKE_PG_ISREADY_RC:-0}"
EOF
chmod +x tests/fixtures/pg_isready
```

- [ ] **Step 3: Verify both fixtures behave as expected**

Run: `CTLSCRIPT_LOG=$(mktemp); FAKE_PG_STATUS=stopped ./tests/fixtures/ctlscript status; cat "$CTLSCRIPT_LOG"; ./tests/fixtures/pg_isready; echo "pg_isready rc=$?"`
Expected output:
```
tomcat already running
postgresql not running
status
pg_isready rc=0
```

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/ctlscript tests/fixtures/pg_isready
git commit -m "$(cat <<'EOF'
test: add fake ctlscript and pg_isready fixtures

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Diagnose per-component health (`diagnose`, `validate_recovery_tools`)

**Files:**
- Test: Create `jasper-watchdog-v2/tests/test_diagnose.bats`
- Modify: `jasper-watchdog-v2/jasper-watchdog-v2.sh:355-360` (replace `restart_service()`), `jasper-watchdog-v2/jasper-watchdog-v2.sh:421` (remove `JASPER_SERVICE` requirement), `jasper-watchdog-v2/jasper-watchdog-v2.sh:448` (append new config defaults)

**Interfaces:**
- Consumes: `mark()` (existing, `jasper-watchdog-v2.sh:14`), `now_utc()` (existing).
- Produces: `validate_recovery_tools()` — returns `0` if `$CTLSCRIPT` and `$PG_ISREADY_BIN` are both executable files, `1` otherwise (marks the reason via `mark`). `diagnose()` — sets globals `PG_PROC_UP`, `TOMCAT_PROC_UP`, `PG_ACCEPTING` (each `0` or `1`) and writes the raw `ctlscript status` output to `"$INCIDENT/recovery_status.txt"`. Later tasks (3-5) read these three globals and call both functions.
- Produces new config defaults consumed by later tasks: `JASPER_HOME`, `CTLSCRIPT`, `PG_ISREADY_BIN`, `PG_COMPONENT`, `TOMCAT_COMPONENT`, `CTL_ACTION_TIMEOUT_SEC`.

- [ ] **Step 1: Write the failing test file**

```bash
cat > tests/test_diagnose.bats <<'EOF'
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  CTLSCRIPT="$BATS_TEST_DIRNAME/fixtures/ctlscript"
  PG_ISREADY_BIN="$BATS_TEST_DIRNAME/fixtures/pg_isready"
  CTL_ACTION_TIMEOUT_SEC=5
  PGHOST="127.0.0.1"
  PGPORT="5432"
  PG_CONNECT_TIMEOUT_SEC=3
  PG_COMPONENT="postgresql"
  TOMCAT_COMPONENT="tomcat"
  INCIDENT="$(mktemp -d)"
  GLOBAL_LOG="$(mktemp)"
  FAKE_TOMCAT_STATUS="running"
  FAKE_PG_STATUS="running"
  FAKE_PG_ISREADY_RC=0
  export FAKE_TOMCAT_STATUS FAKE_PG_STATUS FAKE_PG_ISREADY_RC
}

teardown() {
  rm -rf "$INCIDENT"
  rm -f "$GLOBAL_LOG"
}

@test "reports both components up and postgres accepting connections" {
  diagnose
  [ "$PG_PROC_UP" -eq 1 ]
  [ "$TOMCAT_PROC_UP" -eq 1 ]
  [ "$PG_ACCEPTING" -eq 1 ]
}

@test "detects postgres process down while tomcat stays up" {
  FAKE_PG_STATUS="stopped"
  diagnose
  [ "$PG_PROC_UP" -eq 0 ]
  [ "$TOMCAT_PROC_UP" -eq 1 ]
}

@test "detects tomcat process down" {
  FAKE_TOMCAT_STATUS="stopped"
  diagnose
  [ "$TOMCAT_PROC_UP" -eq 0 ]
}

@test "marks postgres unhealthy when the process is up but not accepting connections" {
  FAKE_PG_ISREADY_RC=1
  diagnose
  [ "$PG_PROC_UP" -eq 1 ]
  [ "$PG_ACCEPTING" -eq 0 ]
}

@test "treats an unparseable postgres status line as down" {
  FAKE_PG_STATUS="unknown"
  diagnose
  [ "$PG_PROC_UP" -eq 0 ]
}

@test "writes the raw ctlscript status output to the incident directory" {
  diagnose
  run cat "$INCIDENT/recovery_status.txt"
  [[ "$output" == *"tomcat already running"* ]]
  [[ "$output" == *"postgresql already running"* ]]
}

@test "validate_recovery_tools fails when ctlscript is missing" {
  CTLSCRIPT="$BATS_TEST_DIRNAME/fixtures/does-not-exist"
  run validate_recovery_tools
  [ "$status" -eq 1 ]
}

@test "validate_recovery_tools fails when pg_isready is missing" {
  PG_ISREADY_BIN="$BATS_TEST_DIRNAME/fixtures/does-not-exist"
  run validate_recovery_tools
  [ "$status" -eq 1 ]
}

@test "validate_recovery_tools succeeds when both binaries are executable" {
  run validate_recovery_tools
  [ "$status" -eq 0 ]
}
EOF
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/test_diagnose.bats`
Expected: every test fails with an error like `diagnose: command not found` or `validate_recovery_tools: command not found`, since neither function exists yet.

- [ ] **Step 3: Remove the old `restart_service()` and add the new functions**

In `jasper-watchdog-v2.sh`, replace this block (lines 355-360):

```bash
restart_service() {
  mark "phase=restart action=systemctl_restart service=$JASPER_SERVICE"
  capture restart_command.txt systemctl restart "$JASPER_SERVICE"
  RESTART_RC="$(tail -n 2 "$INCIDENT/restart_command.txt" | sed -n 's/^# exit_code=//p' | tail -n1)"
  mark "phase=restart result=command_finished exit_code=${RESTART_RC:-unknown}"
}
```

with:

```bash
validate_recovery_tools() {
  if [[ ! -x "$CTLSCRIPT" ]]; then
    mark "phase=recovery result=ctlscript_missing path=$CTLSCRIPT"
    return 1
  fi
  if [[ ! -x "$PG_ISREADY_BIN" ]]; then
    mark "phase=recovery result=pg_isready_missing path=$PG_ISREADY_BIN"
    return 1
  fi
  return 0
}

diagnose() {
  local status_output

  status_output="$(timeout --signal=TERM --kill-after=2s "${CTL_ACTION_TIMEOUT_SEC}s" "$CTLSCRIPT" status 2>&1)"
  printf '%s\n' "$status_output" > "$INCIDENT/recovery_status.txt"

  PG_PROC_UP=0
  TOMCAT_PROC_UP=0
  grep -Eq "^${PG_COMPONENT} already running" <<< "$status_output" && PG_PROC_UP=1
  grep -Eq "^${TOMCAT_COMPONENT} already running" <<< "$status_output" && TOMCAT_PROC_UP=1

  PG_ACCEPTING=0
  if PGCONNECT_TIMEOUT="$PG_CONNECT_TIMEOUT_SEC" "$PG_ISREADY_BIN" -h "$PGHOST" -p "$PGPORT" >/dev/null 2>&1; then
    PG_ACCEPTING=1
  fi

  mark "phase=diagnose pg_proc_up=$PG_PROC_UP pg_accepting=$PG_ACCEPTING tomcat_proc_up=$TOMCAT_PROC_UP"
}
```

Remove the now-unneeded required var at line 421:

```bash
  : "${JASPER_SERVICE:?JASPER_SERVICE is required}"
```

(delete this line entirely — the line above it, `: "${HEALTH_URL:?HEALTH_URL is required}"`, and below it, `: "${INCIDENT_ROOT:?INCIDENT_ROOT is required}"`, stay unchanged).

Append these new config defaults right after the existing `TOMCAT_SHUTDOWN_PORT="${TOMCAT_SHUTDOWN_PORT:-8005}"` line (line 448):

```bash
  JASPER_HOME="${JASPER_HOME:-/opt/jasperreports-server-cp-7.1.0}"
  CTLSCRIPT="${CTLSCRIPT:-$JASPER_HOME/ctlscript.sh}"
  PG_ISREADY_BIN="${PG_ISREADY_BIN:-$JASPER_HOME/postgresql/bin/pg_isready}"
  PG_COMPONENT="${PG_COMPONENT:-postgresql}"
  TOMCAT_COMPONENT="${TOMCAT_COMPONENT:-tomcat}"
  CTL_ACTION_TIMEOUT_SEC="${CTL_ACTION_TIMEOUT_SEC:-120}"
  PG_READY_TIMEOUT_SEC="${PG_READY_TIMEOUT_SEC:-60}"
  PG_READY_RETRY_SEC="${PG_READY_RETRY_SEC:-3}"
  ESCALATE_TO_FULL_RESTART="${ESCALATE_TO_FULL_RESTART:-1}"
```

(Adding all recovery-related defaults now, even though `PG_READY_*`/`ESCALATE_TO_FULL_RESTART` are only consumed starting Task 3/4, keeps this single block edit self-contained and avoids re-touching the same region three more times.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/test_diagnose.bats`
Expected: `9 tests, 0 failures`

- [ ] **Step 5: Run the full suite to confirm nothing else broke**

Run: `bats tests/test_circuit_breaker.bats tests/test_expected_http_code.bats tests/test_health_probe.bats tests/test_notify_human.bats tests/test_capture_cron_and_sessions.bats tests/test_diagnose.bats`
Expected: all pass (`restart_service` is no longer referenced by any of these files, and `main()` isn't invoked by tests, so removing it does not break sourcing).

- [ ] **Step 6: Commit**

```bash
git add jasper-watchdog-v2.sh tests/test_diagnose.bats
git commit -m "$(cat <<'EOF'
feat: diagnose postgresql/tomcat health via ctlscript and pg_isready

Replaces the removed systemctl-based restart_service() with the first
piece of component-aware recovery: parsing ctlscript.sh status output
and checking real PostgreSQL connectivity via pg_isready.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Recover the unhealthy component (`recover_postgres`, `recover_tomcat`, `recover_components`)

**Files:**
- Create: `jasper-watchdog-v2/tests/test_component_recovery.bats`
- Modify: `jasper-watchdog-v2/jasper-watchdog-v2.sh` (insert new functions after `diagnose()`, before `wait_for_recovery()`)

**Interfaces:**
- Consumes: `PG_PROC_UP`, `TOMCAT_PROC_UP`, `PG_ACCEPTING` and `diagnose()`/`validate_recovery_tools()` (Task 2); `mark()`, `capture()`, `notify_human()` (existing).
- Produces: `ctl_action(filename, args...)` — thin wrapper running `"$CTLSCRIPT" args...` under `timeout`/`capture`. `recover_postgres()` / `recover_tomcat()` — apply the matrix from the design doc, appending a tag (`postgres_start `, `tomcat_start `, `tomcat_restart `) to the global `RECOVERY_ACTIONS` string. `recover_components()` — validates tools, calls `diagnose`, then both `recover_*` functions in order; returns `1` (without touching anything) if `validate_recovery_tools` fails, `0` otherwise. Task 4 calls `recover_components()`.

- [ ] **Step 1: Write the failing test file**

```bash
cat > tests/test_component_recovery.bats <<'EOF'
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  CTLSCRIPT="$BATS_TEST_DIRNAME/fixtures/ctlscript"
  PG_ISREADY_BIN="$BATS_TEST_DIRNAME/fixtures/pg_isready"
  CTL_ACTION_TIMEOUT_SEC=5
  PG_READY_TIMEOUT_SEC=2
  PG_READY_RETRY_SEC=1
  PGHOST="127.0.0.1"
  PGPORT="5432"
  PG_CONNECT_TIMEOUT_SEC=3
  PG_COMPONENT="postgresql"
  TOMCAT_COMPONENT="tomcat"
  INCIDENT="$(mktemp -d)"
  GLOBAL_LOG="$(mktemp)"
  INCIDENT_ID="test_incident"
  ALERT_LOG="$(mktemp)"
  ALERT_COMMAND="$BATS_TEST_DIRNAME/fixtures/fake-alert-command"
  export ALERT_LOG
  CTLSCRIPT_LOG="$(mktemp)"
  export CTLSCRIPT_LOG
  FAKE_TOMCAT_STATUS="running"
  FAKE_PG_STATUS="running"
  FAKE_PG_ISREADY_RC=0
  FAKE_CTLSCRIPT_RC=0
  export FAKE_TOMCAT_STATUS FAKE_PG_STATUS FAKE_PG_ISREADY_RC FAKE_CTLSCRIPT_RC
}

teardown() {
  rm -rf "$INCIDENT"
  rm -f "$GLOBAL_LOG" "$ALERT_LOG" "$CTLSCRIPT_LOG"
}

@test "postgres down, tomcat up: starts postgres, waits for ready, then restarts tomcat" {
  FAKE_PG_STATUS="stopped"
  recover_components
  run cat "$CTLSCRIPT_LOG"
  [ "${lines[0]}" == "status" ]
  [ "${lines[1]}" == "start postgresql" ]
  [ "${lines[2]}" == "restart tomcat" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "postgres up, tomcat down: starts tomcat only, postgres untouched" {
  FAKE_TOMCAT_STATUS="stopped"
  recover_components
  run cat "$CTLSCRIPT_LOG"
  [ "${lines[0]}" == "status" ]
  [ "${lines[1]}" == "start tomcat" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "both components down: starts postgres then tomcat" {
  FAKE_PG_STATUS="stopped"
  FAKE_TOMCAT_STATUS="stopped"
  recover_components
  run cat "$CTLSCRIPT_LOG"
  [ "${lines[0]}" == "status" ]
  [ "${lines[1]}" == "start postgresql" ]
  [ "${lines[2]}" == "start tomcat" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "both up but the probe confirmed a failure: restarts tomcat only, postgres untouched" {
  recover_components
  run cat "$CTLSCRIPT_LOG"
  [ "${lines[0]}" == "status" ]
  [ "${lines[1]}" == "restart tomcat" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "pg_isready timeout still proceeds to recycle tomcat" {
  FAKE_PG_STATUS="stopped"
  FAKE_PG_ISREADY_RC=1
  recover_components
  run cat "$CTLSCRIPT_LOG"
  [ "${lines[2]}" == "restart tomcat" ]
  run grep -c "pg_ready_timeout" "$GLOBAL_LOG"
  [ "$output" -eq 1 ]
}

@test "records the recovery actions taken" {
  FAKE_PG_STATUS="stopped"
  recover_components
  [[ "$RECOVERY_ACTIONS" == *"postgres_start"* ]]
  [[ "$RECOVERY_ACTIONS" == *"tomcat_restart"* ]]
}

@test "missing ctlscript aborts recovery without invoking anything and alerts" {
  CTLSCRIPT="$BATS_TEST_DIRNAME/fixtures/does-not-exist"
  run recover_components
  [ "$status" -eq 1 ]
  [ ! -s "$CTLSCRIPT_LOG" ]
  run cat "$ALERT_LOG"
  [[ "$output" == *"event=recovery_failed"* ]]
}
EOF
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/test_component_recovery.bats`
Expected: every test fails with `recover_components: command not found`.

- [ ] **Step 3: Implement `ctl_action`, `recover_postgres`, `recover_tomcat`, `recover_components`**

In `jasper-watchdog-v2.sh`, insert this block immediately after the `diagnose()` function (which now ends right before `wait_for_recovery() {`):

```bash
ctl_action() {
  local filename="$1"
  shift
  capture "$filename" timeout --signal=TERM --kill-after=2s "${CTL_ACTION_TIMEOUT_SEC}s" "$CTLSCRIPT" "$@"
}

wait_pg_ready() {
  local deadline
  deadline=$((SECONDS + PG_READY_TIMEOUT_SEC))

  while (( SECONDS < deadline )); do
    if PGCONNECT_TIMEOUT="$PG_CONNECT_TIMEOUT_SEC" "$PG_ISREADY_BIN" -h "$PGHOST" -p "$PGPORT" >/dev/null 2>&1; then
      mark "phase=recovery component=postgresql result=pg_ready"
      return 0
    fi
    sleep "$PG_READY_RETRY_SEC"
  done

  mark "phase=recovery component=postgresql result=pg_ready_timeout timeout_sec=$PG_READY_TIMEOUT_SEC"
  return 1
}

recover_postgres() {
  if (( PG_PROC_UP == 1 && PG_ACCEPTING == 1 )); then
    return 0
  fi

  mark "phase=recovery component=postgresql action=start"
  ctl_action recovery_postgres_start.txt start "$PG_COMPONENT"
  RECOVERY_ACTIONS="${RECOVERY_ACTIONS}postgres_start "

  if wait_pg_ready; then
    PG_ACCEPTING=1
  fi
}

recover_tomcat() {
  if (( TOMCAT_PROC_UP == 0 )); then
    mark "phase=recovery component=tomcat action=start"
    ctl_action recovery_tomcat_start.txt start "$TOMCAT_COMPONENT"
    RECOVERY_ACTIONS="${RECOVERY_ACTIONS}tomcat_start "
  else
    mark "phase=recovery component=tomcat action=restart"
    ctl_action recovery_tomcat_restart.txt restart "$TOMCAT_COMPONENT"
    RECOVERY_ACTIONS="${RECOVERY_ACTIONS}tomcat_restart "
  fi
}

recover_components() {
  RECOVERY_ACTIONS=""

  if ! validate_recovery_tools; then
    notify_human "recovery_failed" "JasperServer watchdog: incident $INCIDENT_ID cannot run recovery, ctlscript or pg_isready missing or not executable"
    return 1
  fi

  diagnose
  recover_postgres
  recover_tomcat
  return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/test_component_recovery.bats`
Expected: `7 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add jasper-watchdog-v2.sh tests/test_component_recovery.bats
git commit -m "$(cat <<'EOF'
feat: recover the unhealthy component via ctlscript

Adds recover_postgres()/recover_tomcat()/recover_components(): starts
whichever component ctlscript reports down, waits for pg_isready after
starting PostgreSQL, and always recycles a running-but-unhealthy Tomcat
(the only way recovery is reached is a confirmed health failure).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Escalate to a full-stack restart (`full_restart`, `run_recovery`)

**Files:**
- Modify: `jasper-watchdog-v2/jasper-watchdog-v2.sh` (insert after `recover_components()`, before `wait_for_recovery()`)
- Modify: `jasper-watchdog-v2/tests/test_component_recovery.bats` (append escalation tests)

**Interfaces:**
- Consumes: `recover_components()` (Task 3), `wait_for_recovery()` (existing, `jasper-watchdog-v2.sh:362-382`), `ESCALATE_TO_FULL_RESTART` (config default from Task 2).
- Produces: `full_restart()` — runs `ctlscript.sh restart` (no component argument) and appends `full_restart ` to `RECOVERY_ACTIONS`. `run_recovery()` — the single entry point Task 5's `main()` calls: returns `0` on recovered health, `1` otherwise, handling the surgical-then-escalate sequence internally.

- [ ] **Step 1: Append the failing escalation tests**

Run this to append the three new `@test` blocks after the last one already in the file:

```bash
cat >> tests/test_component_recovery.bats <<'EOF'

@test "escalates to a full restart when the surgical recovery never restores health" {
  RECOVERY_TIMEOUT_SEC=1
  RECOVERY_RETRY_SEC=1
  ESCALATE_TO_FULL_RESTART=1
  PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  HEALTH_URL="http://example.invalid/health"
  HEALTH_CONNECT_TIMEOUT_SEC=3
  HEALTH_MAX_TIME_SEC=10
  EXPECTED_HTTP_CODES="200"
  HEALTH_BODY_MARKER=""
  SLOW_RESPONSE_THRESHOLD_SEC=""
  export FAKE_CURL_RC=0 FAKE_CURL_HTTP_CODE=500 FAKE_CURL_TIME_TOTAL=0.1 FAKE_CURL_BODY="" FAKE_CURL_ERR=""

  run run_recovery
  [ "$status" -eq 1 ]
  run grep -c "^restart$" "$CTLSCRIPT_LOG"
  [ "$output" -eq 1 ]
}

@test "does not escalate to a full restart when escalation is disabled" {
  RECOVERY_TIMEOUT_SEC=1
  RECOVERY_RETRY_SEC=1
  ESCALATE_TO_FULL_RESTART=0
  PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  HEALTH_URL="http://example.invalid/health"
  HEALTH_CONNECT_TIMEOUT_SEC=3
  HEALTH_MAX_TIME_SEC=10
  EXPECTED_HTTP_CODES="200"
  HEALTH_BODY_MARKER=""
  SLOW_RESPONSE_THRESHOLD_SEC=""
  export FAKE_CURL_RC=0 FAKE_CURL_HTTP_CODE=500 FAKE_CURL_TIME_TOTAL=0.1 FAKE_CURL_BODY="" FAKE_CURL_ERR=""

  run run_recovery
  [ "$status" -eq 1 ]
  run grep -c "^restart$" "$CTLSCRIPT_LOG"
  [ "$output" -eq 0 ]
}

@test "does not escalate when the surgical recovery already restored health" {
  RECOVERY_TIMEOUT_SEC=5
  RECOVERY_RETRY_SEC=1
  ESCALATE_TO_FULL_RESTART=1
  PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  HEALTH_URL="http://example.invalid/health"
  HEALTH_CONNECT_TIMEOUT_SEC=3
  HEALTH_MAX_TIME_SEC=10
  EXPECTED_HTTP_CODES="200"
  HEALTH_BODY_MARKER=""
  SLOW_RESPONSE_THRESHOLD_SEC=""
  export FAKE_CURL_RC=0 FAKE_CURL_HTTP_CODE=200 FAKE_CURL_TIME_TOTAL=0.1 FAKE_CURL_BODY="" FAKE_CURL_ERR=""

  run run_recovery
  [ "$status" -eq 0 ]
  run grep -c "^restart$" "$CTLSCRIPT_LOG"
  [ "$output" -eq 0 ]
}
EOF
```

- [ ] **Step 2: Run the test to verify the new cases fail**

Run: `bats tests/test_component_recovery.bats`
Expected: the 7 tests from Task 3 still pass; the 3 new tests fail with `run_recovery: command not found`.

- [ ] **Step 3: Implement `full_restart` and `run_recovery`**

In `jasper-watchdog-v2.sh`, insert this block immediately after `recover_components()` (still before `wait_for_recovery() {`):

```bash
full_restart() {
  mark "phase=recovery action=full_restart"
  ctl_action recovery_full_restart.txt restart
  RECOVERY_ACTIONS="${RECOVERY_ACTIONS}full_restart "
}

run_recovery() {
  if ! recover_components; then
    return 1
  fi

  if wait_for_recovery; then
    return 0
  fi

  if [[ "$ESCALATE_TO_FULL_RESTART" -eq 1 ]]; then
    full_restart
    if wait_for_recovery; then
      return 0
    fi
  fi

  return 1
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/test_component_recovery.bats`
Expected: `10 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add jasper-watchdog-v2.sh tests/test_component_recovery.bats
git commit -m "$(cat <<'EOF'
feat: escalate to a full-stack restart when surgical recovery fails

run_recovery() is the new single entry point: component-level recovery,
wait for HTTP health, then ctlscript.sh restart (whole stack) as a last
resort when ESCALATE_TO_FULL_RESTART=1 and health still hasn't returned.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire recovery into `main()`, evidence capture, and the incident summary

**Files:**
- Create: `jasper-watchdog-v2/tests/test_write_summary.bats`
- Create: `jasper-watchdog-v2/tests/test_capture_service_status.bats`
- Modify: `jasper-watchdog-v2/jasper-watchdog-v2.sh:169-170` (`capture_system_snapshot`), `jasper-watchdog-v2/jasper-watchdog-v2.sh:394` (`write_summary`), `jasper-watchdog-v2/jasper-watchdog-v2.sh:463-469` (global var init in `main()`), `jasper-watchdog-v2/jasper-watchdog-v2.sh:489-511` (`main()` recovery flow)

**Interfaces:**
- Consumes: `run_recovery()` (Task 4), `RECOVERY_ACTIONS` (Task 3).
- Produces: no new functions; this task only rewires existing ones. After this task, `restart_service`/`JASPER_SERVICE`/`RESTART_RC` no longer exist anywhere in the script.

- [ ] **Step 1: Write the failing `write_summary` test**

```bash
cat > tests/test_write_summary.bats <<'EOF'
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  INCIDENT="$(mktemp -d)"
  INCIDENT_ID="jasper_20260705T000000Z_pid1"
  HEALTH_URL="http://127.0.0.1:8080/jasperserver/login.html"
  FIRST_PROBE="curl_rc=0; http_code=500"
  CONFIRM_PROBE="curl_rc=0; http_code=500"
  RECOVERY_PROBE="curl_rc=0; http_code=200"
}

teardown() {
  rm -rf "$INCIDENT"
}

@test "includes the recovery actions taken in the incident summary" {
  RECOVERY_ACTIONS="postgres_start tomcat_restart "
  write_summary "RECOVERED"
  run cat "$INCIDENT/README.md"
  [[ "$output" == *"Recovery actions taken:** postgres_start tomcat_restart"* ]]
}

@test "shows none when no recovery actions were recorded" {
  RECOVERY_ACTIONS=""
  write_summary "BLOCKED_CIRCUIT_BREAKER"
  run cat "$INCIDENT/README.md"
  [[ "$output" == *"Recovery actions taken:** none"* ]]
}
EOF
```

- [ ] **Step 2: Write the failing `capture_system_snapshot` test**

```bash
cat > tests/test_capture_service_status.bats <<'EOF'
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  CTLSCRIPT="$BATS_TEST_DIRNAME/fixtures/ctlscript"
  CTL_ACTION_TIMEOUT_SEC=5
  INCIDENT="$(mktemp -d)"
  GLOBAL_LOG="$(mktemp)"
  JASPER_LOG_DIR="$(mktemp -d)"
  TAIL_LINES=10
  CTLSCRIPT_LOG="$(mktemp)"
  export CTLSCRIPT_LOG
  FAKE_TOMCAT_STATUS="running"
  FAKE_PG_STATUS="running"
  export FAKE_TOMCAT_STATUS FAKE_PG_STATUS
}

teardown() {
  rm -rf "$INCIDENT" "$JASPER_LOG_DIR"
  rm -f "$GLOBAL_LOG" "$CTLSCRIPT_LOG"
}

@test "captures ctlscript status instead of systemctl/journalctl" {
  capture_system_snapshot
  [ -f "$INCIDENT/service_status_before.txt" ]
  run cat "$INCIDENT/service_status_before.txt"
  [[ "$output" == *"tomcat already running"* ]]
  [[ "$output" == *"postgresql already running"* ]]
  [ ! -f "$INCIDENT/service_journal_before.txt" ]
  run cat "$CTLSCRIPT_LOG"
  [ "$output" == "status" ]
}
EOF
```

- [ ] **Step 3: Run both new test files to verify they fail**

Run: `bats tests/test_write_summary.bats tests/test_capture_service_status.bats`
Expected: `test_write_summary.bats` fails both assertions (current text is `Restart command exit code:** unknown`, not `Recovery actions taken:`). `test_capture_service_status.bats` fails with `JASPER_SERVICE: unbound variable` (the current `capture_system_snapshot` still requires it) — this confirms the current behavior is broken exactly as expected.

- [ ] **Step 4: Update `capture_system_snapshot`**

Replace (lines 169-170):

```bash
  capture service_status_before.txt systemctl status "$JASPER_SERVICE" --no-pager
  capture service_journal_before.txt journalctl -u "$JASPER_SERVICE" --since '-15 minutes' --no-pager
```

with:

```bash
  capture service_status_before.txt timeout --signal=TERM --kill-after=2s "${CTL_ACTION_TIMEOUT_SEC}s" "$CTLSCRIPT" status
```

- [ ] **Step 5: Update `write_summary`**

Replace (line 394):

```bash
    echo "- **Restart command exit code:** ${RESTART_RC:-unknown}"
```

with:

```bash
    echo "- **Recovery actions taken:** ${RECOVERY_ACTIONS:-none}"
```

- [ ] **Step 6: Update `main()`'s global var init**

Replace (lines 463-469):

```bash
  INCIDENT=""
  INCIDENT_ID=""
  INCIDENT_STATUS=""
  FIRST_PROBE=""
  CONFIRM_PROBE=""
  RESTART_RC=""
  RECOVERY_PROBE=""
```

with:

```bash
  INCIDENT=""
  INCIDENT_ID=""
  INCIDENT_STATUS=""
  FIRST_PROBE=""
  CONFIRM_PROBE=""
  RECOVERY_PROBE=""
  RECOVERY_ACTIONS=""
  PG_PROC_UP=0
  TOMCAT_PROC_UP=0
  PG_ACCEPTING=0
```

- [ ] **Step 7: Rewire `main()`'s recovery flow**

Replace (lines 489-511, from `restart_service` through the final `exit 1`):

```bash
  restart_service

  if wait_for_recovery; then
    INCIDENT_STATUS="RECOVERED"
    write_summary "$INCIDENT_STATUS"
    mark "incident_status=$INCIDENT_STATUS"
    exit 0
  fi

  INCIDENT_STATUS="NOT_RECOVERED"
  notify_human "recovery_failed" "JasperServer watchdog: incident $INCIDENT_ID restarted $JASPER_SERVICE but health did not recover within ${RECOVERY_TIMEOUT_SEC}s"
  write_summary "$INCIDENT_STATUS"
  mark "incident_status=$INCIDENT_STATUS"
  exit 1
}
```

with:

```bash
  if run_recovery; then
    INCIDENT_STATUS="RECOVERED"
    write_summary "$INCIDENT_STATUS"
    mark "incident_status=$INCIDENT_STATUS"
    exit 0
  fi

  INCIDENT_STATUS="NOT_RECOVERED"
  notify_human "recovery_failed" "JasperServer watchdog: incident $INCIDENT_ID recovery actions (${RECOVERY_ACTIONS:-none}) did not restore health within ${RECOVERY_TIMEOUT_SEC}s"
  write_summary "$INCIDENT_STATUS"
  mark "incident_status=$INCIDENT_STATUS"
  exit 1
}
```

- [ ] **Step 8: Run the new tests to verify they pass**

Run: `bats tests/test_write_summary.bats tests/test_capture_service_status.bats`
Expected: `4 tests, 0 failures`

- [ ] **Step 9: Run the entire script-level suite to confirm no regressions**

Run: `bash -n jasper-watchdog-v2.sh && bats tests/test_circuit_breaker.bats tests/test_expected_http_code.bats tests/test_health_probe.bats tests/test_notify_human.bats tests/test_capture_cron_and_sessions.bats tests/test_diagnose.bats tests/test_component_recovery.bats tests/test_write_summary.bats tests/test_capture_service_status.bats`
Expected: `bash -n` prints nothing (valid syntax); all bats tests pass.

- [ ] **Step 10: Confirm no dangling references remain**

Run: `grep -n "JASPER_SERVICE\|restart_service\|RESTART_RC\|journalctl" jasper-watchdog-v2.sh`
Expected: no output (all four are fully removed).

- [ ] **Step 11: Commit**

```bash
git add jasper-watchdog-v2.sh tests/test_write_summary.bats tests/test_capture_service_status.bats
git commit -m "$(cat <<'EOF'
feat: wire component-aware recovery into main()

main() now calls run_recovery() instead of the removed systemctl-based
restart_service(). Pre-restart evidence capture and the incident summary
both switch from systemctl/journalctl and a restart exit code to
ctlscript.sh status and the list of recovery actions actually taken.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Update configuration template, installer checklist, and README

**Files:**
- Modify: `jasper-watchdog-v2/jasper-watchdog.conf.example`
- Modify: `jasper-watchdog-v2/install.sh:96-101`
- Modify: `jasper-watchdog-v2/README.md`

**Interfaces:** None (documentation/config only — no new script functions).

- [ ] **Step 1: Enable content/latency validation by default in the config template**

In `jasper-watchdog.conf.example`, replace:

```
# Optional content and latency validation. Leave both unset to keep
# validating only the HTTP status code (previous behavior).
# HEALTH_BODY_MARKER="MONITOR"
# SLOW_RESPONSE_THRESHOLD_SEC=4
JASPER_SERVICE="jasperserver"
```

with:

```
# Content and latency validation. Enabled by default to match the
# production JasperServer CP 7.1.0 health check: the login page must
# contain "MONITOR" and respond in under 4 seconds. A 200 response that
# is slow or missing the marker is treated as a failure. Comment both
# out to validate only the HTTP status code.
HEALTH_BODY_MARKER="MONITOR"
SLOW_RESPONSE_THRESHOLD_SEC=4

# JasperServer is controlled through ctlscript.sh (no systemd unit backs
# it on this host). Recovery diagnoses postgresql and tomcat separately
# via "ctlscript.sh status" and pg_isready, then starts/restarts only the
# unhealthy component before falling back to a full-stack restart.
JASPER_HOME="/opt/jasperreports-server-cp-7.1.0"
CTLSCRIPT="$JASPER_HOME/ctlscript.sh"
PG_ISREADY_BIN="$JASPER_HOME/postgresql/bin/pg_isready"
PG_COMPONENT="postgresql"
TOMCAT_COMPONENT="tomcat"
CTL_ACTION_TIMEOUT_SEC=120
PG_READY_TIMEOUT_SEC=60
PG_READY_RETRY_SEC=3
# Set to 0 to only alert (never touch the stack again) when the
# component-level recovery does not restore HTTP health.
ESCALATE_TO_FULL_RESTART=1
```

- [ ] **Step 2: Update the installer's configuration checklist**

In `install.sh`, replace (lines 96-101):

```bash
  echo "      HEALTH_URL      - endpoint that proves JasperServer is alive"
  echo "      JASPER_SERVICE  - the actual systemd service name"
  echo "      JASPER_LOG_DIR  - the Tomcat/Jasper logs directory"
  echo "      PGHOST/PGPORT/PGDATABASE/PGUSER - the monitoring DB connection"
  echo "    Optional: HEALTH_BODY_MARKER, SLOW_RESPONSE_THRESHOLD_SEC,"
  echo "              ALERT_COMMAND, MAX_AUTORESTARTS, RESTART_WINDOW_SEC"
```

with:

```bash
  echo "      HEALTH_URL      - endpoint that proves JasperServer is alive"
  echo "      JASPER_HOME     - install path used to derive CTLSCRIPT/PG_ISREADY_BIN"
  echo "      JASPER_LOG_DIR  - the Tomcat/Jasper logs directory"
  echo "      PGHOST/PGPORT/PGDATABASE/PGUSER - the monitoring DB connection"
  echo "    Optional: HEALTH_BODY_MARKER, SLOW_RESPONSE_THRESHOLD_SEC,"
  echo "              ALERT_COMMAND, MAX_AUTORESTARTS, RESTART_WINDOW_SEC,"
  echo "              ESCALATE_TO_FULL_RESTART"
```

- [ ] **Step 3: Update the README's opening description**

Replace (line 3):

```
This version does not restart JasperServer on a single failed response. It runs every **15 seconds**, repeats a failed application-health probe after **5 seconds**, and only if the failure is confirmed it creates an incident folder, captures evidence, and then executes `systemctl restart jasperserver`.
```

with:

```
This version does not restart JasperServer on a single failed response. It runs every **15 seconds**, repeats a failed application-health probe after **5 seconds**, and only if the failure is confirmed it creates an incident folder, captures evidence, then diagnoses which component (`postgresql`, `tomcat`, or both) is unhealthy via `ctlscript.sh status` and `pg_isready`, and applies the minimal correct recovery — starting a stopped component or recycling a running-but-unhealthy Tomcat — before escalating to a full `ctlscript.sh restart` if that isn't enough.
```

- [ ] **Step 4: Update the incident file tree**

Replace (lines 7-20):

```
```text
/var/log/jasper-watchdog/incidents/
  jasper_YYYYMMDDTHHMMSSZ_pidNNNN/
    README.md
    incident.log
    os_*.txt
    service_*.txt
    log_tail_*.txt
    jvm_thread_dump.txt
    cron_and_sessions.txt
    pg_*.txt
    restart_command.txt
    recovery_checks.log
```
```

with:

```
```text
/var/log/jasper-watchdog/incidents/
  jasper_YYYYMMDDTHHMMSSZ_pidNNNN/
    README.md
    incident.log
    os_*.txt
    service_status_before.txt
    log_tail_*.txt
    jvm_thread_dump.txt
    cron_and_sessions.txt
    pg_*.txt
    recovery_status.txt
    recovery_postgres_start.txt
    recovery_tomcat_start.txt
    recovery_tomcat_restart.txt
    recovery_full_restart.txt
    recovery_checks.log
```
```

(the last four `recovery_*` files are only produced when that specific action was actually taken)

- [ ] **Step 5: Update prerequisites**

Replace (line 24):

```
- `curl`, `psql`, `systemctl`, `journalctl`, `timeout`, `flock`, `ss`.
```

with:

```
- `curl`, `psql`, `timeout`, `flock`, `ss`, `pg_isready` (shipped with JasperServer's bundled PostgreSQL).
- Read/execute access to `ctlscript.sh` in the JasperServer install directory — this watchdog controls JasperServer through it, not through a systemd unit.
- `systemctl` is still required to run the watchdog's own timer/service (see Install, step 3.4), independent of how JasperServer itself is managed.
```

- [ ] **Step 6: Update the Configure section**

Replace (lines 86-91):

```
Edit `/etc/jasper-watchdog/jasper-watchdog.conf` and validate these values
against the server:

- `HEALTH_URL`: a JasperServer endpoint that proves the application is alive. Do not leave a mere port check as the only health condition. Optionally set `HEALTH_BODY_MARKER` to a string that must appear in the response body, and `SLOW_RESPONSE_THRESHOLD_SEC` to treat a slow-but-200 response as a failure. Both are unset by default.
- `JASPER_SERVICE`: the actual systemd service name.
- `JASPER_LOG_DIR`: the Tomcat/Jasper logs directory.
```

with:

```
Edit `/etc/jasper-watchdog/jasper-watchdog.conf` and validate these values
against the server:

- `HEALTH_URL`: a JasperServer endpoint that proves the application is alive. Do not leave a mere port check as the only health condition. `HEALTH_BODY_MARKER` and `SLOW_RESPONSE_THRESHOLD_SEC` ship enabled by default (`"MONITOR"` / `4` seconds) so a slow-but-200 response is treated as a failure; comment both out to validate only the HTTP status code.
- `JASPER_HOME`/`CTLSCRIPT`/`PG_ISREADY_BIN`: confirm these match the actual JasperServer install path on this server.
- `JASPER_LOG_DIR`: the Tomcat/Jasper logs directory.
```

- [ ] **Step 7: Update the operational rule section**

Replace (lines 155-164):

```
## 6. Operational rule

Do not cancel PostgreSQL backends, kill JVM threads, or reboot the VM from this watchdog. Its responsibility is strictly:

1. confirm an application health failure;
2. preserve forensic evidence;
3. restart JasperServer;
4. record whether health recovered.

This preserves the evidence needed to determine whether the root cause was Jasper/Tomcat, a blocked or saturated PostgreSQL workload, resource pressure, or the surrounding host.
```

with:

```
## 6. Operational rule

Do not cancel PostgreSQL backends, kill JVM threads, or reboot the VM from this watchdog. Its responsibility is strictly:

1. confirm an application health failure;
2. preserve forensic evidence;
3. diagnose and recover the unhealthy component(s) — starting whichever of `postgresql`/`tomcat` is down, always recycling a running-but-unhealthy Tomcat, escalating to a full `ctlscript.sh restart` only if that doesn't restore health and `ESCALATE_TO_FULL_RESTART=1`;
4. record whether health recovered and which recovery actions were taken.

This preserves the evidence needed to determine whether the root cause was Jasper/Tomcat, a blocked or saturated PostgreSQL workload, resource pressure, or the surrounding host.
```

- [ ] **Step 8: Add a component-aware recovery section**

Append this new section at the end of the file, after the existing "## 8. Alerting hook" section:

```markdown

## 9. Component-aware recovery

On a confirmed health failure, the watchdog runs `ctlscript.sh status` and `pg_isready` to decide what actually needs fixing, instead of restarting the whole stack:

| Detected state | PostgreSQL action | Tomcat action |
|---|---|---|
| postgres down, tomcat up | start, wait for `pg_isready` | restart |
| postgres up, tomcat down | — | start |
| both down | start, wait for `pg_isready` | start |
| both up (slow response, wrong content, or non-200) | — | restart |

If `pg_isready` never returns healthy within `PG_READY_TIMEOUT_SEC` (default 60s), the watchdog proceeds to recycle Tomcat anyway and records `pg_ready_timeout` in the log — waiting forever is worse than trying.

If the recovery above does not restore `HEALTH_URL` within `RECOVERY_TIMEOUT_SEC`, and `ESCALATE_TO_FULL_RESTART=1` (the default), the watchdog falls back to `ctlscript.sh restart` (the whole stack) before giving up and calling `notify_human("recovery_failed", ...)`. Set `ESCALATE_TO_FULL_RESTART=0` to skip that fallback and only alert.
```

- [ ] **Step 9: Run the full test suite one more time**

Run: `bash -n jasper-watchdog-v2.sh install.sh uninstall.sh && bats tests/`
Expected: `bash -n` prints nothing for all three files. In the bats output, every test file except `test_install.bats`/`test_uninstall.bats` passes (those two already fail in this Windows Git Bash shell on `chmod`/permission semantics unrelated to this change — confirmed as a pre-existing condition before this plan started).

- [ ] **Step 10: Commit**

```bash
git add jasper-watchdog.conf.example install.sh README.md
git commit -m "$(cat <<'EOF'
docs: document component-aware recovery and its configuration

Updates the config template, installer checklist, and README to reflect
ctlscript.sh-based recovery instead of the removed systemctl restart,
and enables HEALTH_BODY_MARKER/SLOW_RESPONSE_THRESHOLD_SEC by default.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Post-plan sanity check (manual, no commit)

After Task 6, re-read `main()` end to end and confirm the circuit breaker (`take_restart_slot`) is called exactly once, before `run_recovery()`, and that no function inside `run_recovery()`'s call graph (`recover_components`, `recover_postgres`, `recover_tomcat`, `full_restart`, `wait_for_recovery`) calls it again. This is a structural invariant, not something a bats test can cheaply verify (`main()` isn't unit-tested in this codebase — it requires a real config file, `flock`, and process exit codes), so confirm it by reading the code.

# JasperServer Watchdog v2 — Component-Aware Recovery Design

**Date:** 2026-07-05
**Status:** Approved

## Context

v2 detects a confirmed health failure and then attempts recovery with a single blind
`systemctl restart "$JASPER_SERVICE"` (`restart_service()`, lines 355-360 of
`jasper-watchdog-v2.sh`). Investigation of the production host
(`inst-ufzn0-jasperserver-intdb5-pool`, JasperServer CP 7.1.0) revealed two problems:

1. **The restart never worked.** There is no systemd unit for JasperServer. The stack is
   managed by `/opt/jasperreports-server-cp-7.1.0/ctlscript.sh` (wrapped by
   `/etc/init.d/inicio.sh`), and operators start/stop Tomcat by hand from the Jasper `bin`.
   `systemctl restart jasperserver` fails silently — the unit does not exist.

2. **A whole-stack restart is the wrong tool for the observed failure modes.** Two real
   incidents were captured:

   - **PostgreSQL down, Tomcat up → HTTP 404.** `ctlscript.sh status` showed `tomcat
     already running` / `postgresql not running`. The correct manual fix was: start
     postgresql, wait until it accepts connections (`pg_isready`), then restart Tomcat so
     its JDBC pool reconnects. Bouncing the whole stack would needlessly restart the DB it
     just started.

   - **Both up, HTTP 200 but slow/hung.** The endpoint returned 200 with the `MONITOR`
     body marker but took 10-11s. The correct fix was to recycle **only** Tomcat (a
     controlled stop that escalated to KILL when Tomcat would not stop in time, then start
     Tomcat alone). PostgreSQL was healthy and left untouched. This is the scenario v1
     handled well and v2 must not regress.

The blind `systemctl restart` covers neither case. This design replaces the recovery layer
with a component-aware sequence built on `ctlscript.sh`.

## Decision

Replace `restart_service()` with a component-aware recovery module that diagnoses which
component is unhealthy via `ctlscript.sh status` + `pg_isready`, then applies the minimal
correct sequence, escalating to a full-stack restart only if the surgical repair does not
restore HTTP health. The existing health-probe, confirmation, circuit-breaker, evidence-
capture, and recovery-wait machinery is reused unchanged. All new behavior is driven by
configuration, defaulting to the values observed on the production host.

## Design

### 1. New configuration variables

Added to `jasper-watchdog.conf.example`, all with production-matching defaults:

- `JASPER_HOME="/opt/jasperreports-server-cp-7.1.0"`
- `CTLSCRIPT="$JASPER_HOME/ctlscript.sh"`
- `PG_ISREADY_BIN="$JASPER_HOME/postgresql/bin/pg_isready"` (the system `pg_isready` is not on `PATH`)
- `PG_COMPONENT="postgresql"` and `TOMCAT_COMPONENT="tomcat"` (component names passed to ctlscript)
- `CTL_ACTION_TIMEOUT_SEC=120` — per-ctlscript-invocation timeout. Must exceed BitNami's
  internal stop-then-kill timeout so we never TERM ctlscript mid-kill and leave Tomcat in a
  broken state.
- `PG_READY_TIMEOUT_SEC=60` and `PG_READY_RETRY_SEC=3` — how long to wait for `pg_isready`
  after starting PostgreSQL.
- `ESCALATE_TO_FULL_RESTART=1` — when the surgical recovery fails to restore HTTP health,
  run `ctlscript.sh restart` (whole stack) as a last resort before declaring
  `NOT_RECOVERED`. Set to `0` for the conservative behavior (alert, touch nothing more).

The `JASPER_SERVICE` variable and all `systemctl`/`journalctl` usage are removed from the
recovery and capture paths (see §5).

**The optional slow/content checks must be enabled to cover the slow-response scenario.**
The config example will prominently document, and set as active defaults matching v1:
`HEALTH_BODY_MARKER="MONITOR"` and `SLOW_RESPONSE_THRESHOLD_SEC=4`. Without these, a slow
HTTP 200 is only caught when it exceeds `HEALTH_MAX_TIME_SEC` (curl timeout); with them, the
"200 but slow/hung" failure mode is detected exactly as v1 detected it.

### 2. Diagnosis

New function `diagnose()`:

- Runs `ctlscript.sh status` (wrapped in `timeout`) and parses per-component state from the
  `<component> already running` / `<component> not running` lines into `PG_PROC_UP` and
  `TOMCAT_PROC_UP` (0/1).
- Runs `PG_ISREADY_BIN -h "$PGHOST" -p "$PGPORT"` to set `PG_ACCEPTING` (0/1). PostgreSQL is
  considered healthy only when the process is up **and** it accepts connections; a process
  that is up but not accepting is treated as down.
- **Fail-safe parsing:** if a component's state cannot be parsed from the status output, it
  is treated as *down* (we prefer attempting a start over doing nothing). The raw status
  output is written to the incident directory (`recovery_status.txt`).

### 3. Recovery sequence

Recovery runs only after a confirmed failure and after `take_restart_slot()` grants a slot
(the breaker is consulted **once per incident**, regardless of how many components are
touched).

```
recover_postgres():
    if not (PG_PROC_UP and PG_ACCEPTING):
        ctlscript start postgresql        # idempotent: "already running" is a safe no-op
        wait_pg_ready()                    # poll pg_isready up to PG_READY_TIMEOUT_SEC
        PG_REPAIRED = 1

recover_tomcat():
    if not TOMCAT_PROC_UP:
        ctlscript start tomcat
    else:
        ctlscript restart tomcat           # always recycle a running-but-unhealthy Tomcat
```

`recover_tomcat()` **always acts**: we only reach recovery on a confirmed health failure, so
a running Tomcat is by definition unhealthy (broken JDBC pool, hung, 404, or slow) and
benefits from a recycle. The `restart tomcat` path relies on ctlscript's own controlled-stop-
then-KILL behavior — the same mechanism v1 used — so we do not reimplement the kill.

Resulting decision matrix:

| Detected state | PostgreSQL action | Tomcat action |
|---|---|---|
| postgres down, tomcat up (DB outage) | start + wait pg_isready | restart |
| postgres up, tomcat down | — | start |
| both down | start + wait pg_isready | start |
| both up, HTTP 200 slow / 404 (v1 slow-hang case) | — | restart |

### 4. Recovery wait and escalation

- After the surgical sequence, `wait_for_recovery()` (unchanged) polls the HTTP health probe
  up to `RECOVERY_TIMEOUT_SEC`. Success → `RECOVERED`.
- If it does not recover and `ESCALATE_TO_FULL_RESTART=1`: run `ctlscript.sh restart` (whole
  stack, correct start ordering handled by ctlscript), then `wait_for_recovery()` again.
- If still not recovered (or escalation disabled): mark `NOT_RECOVERED`, call
  `notify_human("recovery_failed", ...)`. The existing summary/incident-status flow is
  reused.

### 5. Evidence capture adjustments

`capture_system_snapshot()` currently runs `systemctl status "$JASPER_SERVICE"` and
`journalctl -u "$JASPER_SERVICE"` (lines 169-170), which produce nothing on this host.
Replace those two captures with:

- `capture service_status_before.txt "$CTLSCRIPT" status`
- The `pg_isready` result at diagnosis time.

Jasper/Tomcat log tails (`capture_jasper_logs`) and the JVM thread dump already cover the
application-level evidence and are unchanged.

### 6. Error handling and edge cases

- **Missing/non-executable `CTLSCRIPT` or `PG_ISREADY_BIN`:** validated at the start of
  recovery. If absent, mark `phase=recovery result=ctlscript_missing`, `notify_human`, and
  exit `NOT_RECOVERED` without touching anything.
- **Per-command timeouts:** every ctlscript invocation is wrapped in
  `timeout --signal=TERM --kill-after=2s "${CTL_ACTION_TIMEOUT_SEC}s"` (same pattern as
  `psql_snapshot`).
- **`pg_isready` never responds:** `wait_pg_ready()` retries up to `PG_READY_TIMEOUT_SEC`. On
  timeout it proceeds to recycle Tomcat anyway (better than aborting) and records
  `pg_ready=timeout`.
- **Concurrency:** the existing `flock -n` (line 458) already guarantees one execution at a
  time; overlapping timer firings during a multi-minute recovery exit without acting.
  Unchanged.
- **Idempotency:** `ctlscript start` on an already-running component is a safe no-op, so the
  matrix is robust if state changes between diagnosis and action.

### 7. Automated tests (bats-core)

New `tests/test_component_recovery.bats` plus fake `ctlscript` and `pg_isready` fixtures
(same style as the existing `curl`/`ss` fixtures) whose states are scripted via environment
variables and which log received commands to a file the test inspects for order and
arguments. Cases:

- Each matrix row → asserts the **exact ctlscript command sequence**.
- **both up + slow probe → `restart tomcat` invoked and PostgreSQL untouched** (explicit
  guard that v2 does not regress v1's slow-hang recovery).
- `pg_isready` timeout → proceeds to Tomcat, logs `pg_ready=timeout`.
- Missing `CTLSCRIPT` → `NOT_RECOVERED` + alert, nothing invoked.
- Escalation: surgical recovery fails → `ctlscript restart` (full) invoked when
  `ESCALATE_TO_FULL_RESTART=1`; **not** invoked when `=0`.
- Circuit breaker consulted exactly once per incident.

## Out of scope

- Installing a proper systemd unit for JasperServer (the stack stays under `ctlscript.sh` /
  `inicio.sh`).
- Diagnosing/fixing the root cause of the PostgreSQL or Tomcat outages themselves — the
  watchdog restores service and captures evidence; root-cause remediation is separate.

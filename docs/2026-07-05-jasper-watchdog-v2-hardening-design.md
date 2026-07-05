# JasperServer Watchdog v2 — Hardening Design

**Date:** 2026-07-05
**Status:** Approved

## Context

The project has two watchdog implementations:

- **v1** (`jasper-watchdog-v1/`): a Spanish operational runbook and script deployed on host `inst-k5vj9-jasperserver-intdb4-poo` (JasperServer CP 7.1.0). It has a restart circuit breaker (max 3 auto-restarts per 15-minute window) and a content+latency health check (HTTP 200, body contains `MONITOR`, response under 4s).
- **v2** (`jasper-watchdog-v2/`): a generic, installable rewrite (systemd timer + service, PostgreSQL forensic snapshot). It dropped v1's circuit breaker and content/latency validation — it restarts on every confirmed failure with no limit, and only checks the HTTP status code.

Analysis of the repo surfaced these gaps plus: no alerting on incidents, no version control (repo had loose duplicate copies of `jasper-watchdog-v2.sh` / `.tar.gz` at the root), no automated tests, and no evidence capture targeting the root cause v1 already diagnosed (a cron job shutting down Tomcat via its shutdown port).

## Decision

v2 becomes the single canonical, maintained implementation. v1 is preserved unchanged as historical/incident documentation for INTDB4; no further development happens on it.

## Design

### 1. Restart circuit breaker

Ported from v1, with one deliberate improvement.

- New config variables in `jasper-watchdog.conf` (with defaults matching v1): `MAX_AUTORESTARTS=3`, `RESTART_WINDOW_SEC=900`.
- New state file `restart-history.log`, stored next to `GLOBAL_LOG` (i.e. `"$(dirname "$GLOBAL_LOG")/restart-history.log"`), holding one epoch timestamp per automatic restart.
- New function `take_restart_slot()`: prunes timestamps older than `RESTART_WINDOW_SEC`, counts what remains. If the count is `>= MAX_AUTORESTARTS`, returns failure (blocked) without recording a new slot. Otherwise appends `now()` and returns success.
- **Improvement over v1:** in v1, when the breaker trips, no evidence is captured for that event (the check happens before evidence capture). In v2, evidence capture (`capture_pre_restart`) always runs regardless of the breaker's decision — only the actual `systemctl restart` call is gated by `take_restart_slot()`. This preserves forensic data for the exact case where the system is flapping and a human needs to intervene.
- When blocked: the incident is marked `BLOCKED_CIRCUIT_BREAKER` in `README.md`/`incident.log`, `restart_service()` is skipped, and `notify_human()` (section 4) is invoked.

### 2. Content and latency health validation (optional, backward compatible)

- New optional config variables: `HEALTH_BODY_MARKER` (empty = no content check, current behavior) and `SLOW_RESPONSE_THRESHOLD_SEC` (empty = no latency check).
- `health_probe()` is extended: in addition to the existing HTTP status check, treat the probe as failed if `HEALTH_BODY_MARKER` is set and absent from the response body, or if `SLOW_RESPONSE_THRESHOLD_SEC` is set and `time_total` exceeds it.
- When `HEALTH_BODY_MARKER` is set, the probe writes the response body to a temp file (instead of `/dev/null`) to grep it, then removes the temp file. When unset, behavior is unchanged (`--output /dev/null`).
- The existing two-probe flow (first probe fails → wait `CONFIRM_DELAY_SEC` → confirmation probe) is reused unmodified for both hard and soft (content/latency) failures. v1's separate soft-failure counter (2 failures across independent 15s cycles before acting) is intentionally **not** ported: v2 already runs as an independent systemd-timer invocation every 15s, and adding a cross-invocation soft-failure counter would require extra persistent state for marginal benefit over the existing confirm-delay mechanism.

### 3. Alert hook (no channel implemented yet, extensible)

- New optional config variable `ALERT_COMMAND` (empty = no-op).
- New function `notify_human(event, message)`: if `ALERT_COMMAND` is set, executes it with `event` and `message` as positional arguments. Any external script (Slack webhook, email, PagerDuty, etc.) can be wired in without modifying the watchdog. Failure to execute `ALERT_COMMAND` is logged via `mark` but never blocks the watchdog's main flow.
- Called at exactly three points: incident created (`event=incident_created`), circuit breaker tripped (`event=circuit_breaker_tripped`), and post-restart recovery failed (`event=recovery_failed`).

### 4. Additional evidence capture

- New capture file `cron_and_sessions.txt`, added to `capture_pre_restart()`, containing:
  - `crontab -l` for root and any other user with a spool file under `/var/spool/cron`.
  - `ss -tlnp` filtered to known shutdown ports (Tomcat's configured shutdown port, default 8005, plus any value from a new optional `TOMCAT_SHUTDOWN_PORT` config variable).
  - `last -n 20` and `who`.
- This directly targets the root cause v1 already documented: a cron job sending a shutdown command to Tomcat's shutdown port.

### 5. Repository hygiene

- `git init` locally (no remote configured).
- `.gitignore` excludes `*.tar.gz`.
- Remove the duplicate root-level `jasper-watchdog-v2.sh` and `jasper-watchdog-v2.tar.gz` — `jasper-watchdog-v2/` is the single source of truth.
- Add a small build step (documented in `jasper-watchdog-v2/README.md`) to regenerate the tarball on demand instead of committing a binary artifact.
- Initial commit captures the cleaned-up state plus this spec.

### 6. Automated tests (bats-core)

- New `jasper-watchdog-v2/tests/` directory with bats test files covering:
  - `expected_http_code()` — matching against `EXPECTED_HTTP_CODES` lists.
  - `take_restart_slot()` — circuit breaker behavior using a temp state file and fabricated timestamps (under/at/over the window and the max-count threshold).
  - `health_probe()` — HTTP-code-only, content-marker, and latency-threshold paths, with `curl` stubbed via a `PATH`-shadowing fake.
  - `notify_human()` — verifies `ALERT_COMMAND` receives the right arguments and that a failing command doesn't abort the script.
- `jasper-watchdog-v2/tests/README.md` documents how to install bats-core and run the suite.

### 7. Documentation updates

- `jasper-watchdog-v2/README.md` updated to document: the new config variables (with defaults), circuit breaker behavior and `BLOCKED_CIRCUIT_BREAKER` status, the `ALERT_COMMAND` hook and its call sites, the new `cron_and_sessions.txt` evidence file, and how to run the test suite.

## Out of scope

- Any specific alerting channel implementation (Slack/email/webhook body) — only the generic `ALERT_COMMAND` hook is built.
- Metrics export (e.g., node_exporter textfile collector) — not applicable, no Prometheus/metrics stack in use.
- Changes to v1 — it remains frozen as historical documentation.
- A remote git repository / CI pipeline — only local `git init`.

## Testing strategy

Bats-core unit tests for the pure/mockable functions (section 6) are the primary safety net, since this script's blast radius is a production restart action. End-to-end validation still relies on the manual procedure already documented in `jasper-watchdog-v2/README.md` section 5 (dry-run against a disposable test service), extended to also verify: the circuit breaker blocks a 4th restart within the window, and `notify_human()` fires with a test `ALERT_COMMAND` script.

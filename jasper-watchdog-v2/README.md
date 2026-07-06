# JasperServer Watchdog v2

This version does not restart JasperServer on a single failed response. It runs every **15 seconds**, repeats a failed application-health probe after **5 seconds**, and only if the failure is confirmed it creates an incident folder, captures evidence, then diagnoses which component (`postgresql`, `tomcat`, or both) is unhealthy via `ctlscript.sh status` and `pg_isready`, and applies the minimal correct recovery — starting a stopped component or recycling a running-but-unhealthy Tomcat — before escalating to a full `ctlscript.sh restart` if that isn't enough.

The evidence is captured **before the restart** and stays inside the same incident:

```text
/var/log/jasper-watchdog/incidents/
  jasper_YYYYMMDDTHHMMSSZ_pidNNNN/
    README.md
    incident.log
    last_health_failure.html
    os_*.txt (including os_dmesg.txt and os_journal_recent.txt)
    service_status_before.txt
    log_tail_*.txt
    jvm_*.txt (process info, thread dump, per-thread CPU usage)
    cron_and_sessions.txt
    pg_*.txt
    recovery_status.txt
    recovery_postgres_start.txt
    recovery_tomcat_start.txt
    recovery_tomcat_restart.txt
    recovery_full_restart.txt
    recovery_checks.log
```

(the last four `recovery_*` files are only produced when that specific action was actually taken)

## 1. Prerequisites

- `curl`, `psql`, `timeout`, `flock`, `ss`, `pg_isready` (shipped with JasperServer's bundled PostgreSQL).
- `dmesg` and `journalctl` for kernel/system-journal evidence. If either is missing, its capture file just records the error — the watchdog still runs.
- Read/execute access to `ctlscript.sh` in the JasperServer install directory — this watchdog controls JasperServer through it, not through a systemd unit.
- `systemctl` is still required to run the watchdog's own timer/service (see Install, step 3.4), independent of how JasperServer itself is managed.
- `jcmd` or `jstack` from the JDK is recommended, so the incident includes a JVM thread dump.
- A dedicated PostgreSQL monitoring login. Do **not** reuse the application role `jasperdb` or its password.
- The watchdog is intended to run as `root`, because it needs to invoke `ctlscript.sh` and read Tomcat/Jasper logs.

## 2. PostgreSQL monitoring role

First check the server version:

```bash
sudo -u postgres psql -d jasperserver -c "SHOW server_version_num;"
```

For PostgreSQL 10+, create the role without exposing its password in command history:

```bash
sudo -u postgres psql -d postgres
CREATE ROLE jasper_watchdog LOGIN;
\password jasper_watchdog
\q
sudo -u postgres psql -d jasperserver -f /root/jasper-watchdog-v2/postgres-watchdog-role.sql
```

`pg_monitor` is the recommended least-privilege role for the PostgreSQL statistics views. The snapshot relies on `pg_stat_activity`, `pg_locks`, and `pg_blocking_pids()` to correlate active work and lock waits.

For PostgreSQL 9.6 or older, do not make the watchdog a superuser. `pg_monitor` is not available on those versions; use a restricted `SECURITY DEFINER` interface or plan the PostgreSQL upgrade before enabling the full snapshot.

## 3. Install

### 3.1 Get the files

Option 1 — git (recommended, when the server can reach GitHub):

```bash
sudo git clone https://github.com/martinlmedina/jasperserver-watchdog.git /opt/jasper-watchdog
# Check out the latest published release tag:
sudo git -C /opt/jasper-watchdog checkout "$(git -C /opt/jasper-watchdog describe --tags --abbrev=0)"
cd /opt/jasper-watchdog/jasper-watchdog-v2
```

To install a specific release instead, replace the checkout with the exact tag,
e.g. `sudo git -C /opt/jasper-watchdog checkout v2.1.0`.

Option 2 — air-gapped: on any machine with the repo, run `./package.sh` to build
`jasper-watchdog-v2.tar.gz`, copy it to the server, extract it, and `cd` into it:

```bash
scp jasper-watchdog-v2.tar.gz root@server:/root/
ssh root@server 'tar -xzf /root/jasper-watchdog-v2.tar.gz -C /root/'
cd /root/jasper-watchdog-v2
```

### 3.2 Run the installer

```bash
sudo ./install.sh
```

The installer is idempotent. It places the binary, systemd units, logrotate and
tmpfiles configuration into their system paths, creates the config from the
example only if it does not already exist, never touches `pgpass`, reloads
systemd, and prints a configuration checklist. It does **not** enable the timer —
that is the explicit go-live step in 3.4.

### 3.3 Configure

Edit `/etc/jasper-watchdog/jasper-watchdog.conf` and validate these values
against the server:

- `HEALTH_URL`: a JasperServer endpoint that proves the application is alive. Do not leave a mere port check as the only health condition. `HEALTH_BODY_MARKER` and `SLOW_RESPONSE_THRESHOLD_SEC` ship enabled by default (`"MONITOR"` / `4` seconds) so a slow-but-200 response is treated as a failure; comment both out to validate only the HTTP status code.
- `JASPER_HOME`/`CTLSCRIPT`/`PG_ISREADY_BIN`: confirm these match the actual JasperServer install path on this server.
- `JASPER_LOG_DIR`: the Tomcat/Jasper logs directory.

Create the password file. The line format is `host:port:database:user:password`:

```bash
sudo sh -c 'umask 077; cat > /etc/jasper-watchdog/pgpass'
# Enter exactly one line, then Ctrl+D:
# 127.0.0.1:5432:jasperserver:jasper_watchdog:REPLACE_WITH_GENERATED_PASSWORD
sudo chmod 0600 /etc/jasper-watchdog/pgpass
sudo chown root:root /etc/jasper-watchdog/pgpass
```

### 3.4 Enable the timer

```bash
sudo systemctl enable --now jasper-watchdog.timer
systemctl list-timers jasper-watchdog.timer
```

A systemd `.timer` unit activates the accompanying `.service` according to the configured timing schedule; the service performs a single monitor execution.

### 3.5 Updating

```bash
sudo git -C /opt/jasper-watchdog fetch --tags
sudo git -C /opt/jasper-watchdog checkout v2.1.0     # the tag you are moving to
sudo /opt/jasper-watchdog/jasper-watchdog-v2/install.sh
```

Your `jasper-watchdog.conf` and incident evidence are preserved. The timer stays
enabled and runs the new binary on its next tick — no restart needed.

### 3.6 Uninstall

```bash
sudo /opt/jasper-watchdog/jasper-watchdog-v2/uninstall.sh          # keeps config + incidents
sudo /opt/jasper-watchdog/jasper-watchdog-v2/uninstall.sh --purge  # also removes them
```

## 4. What PostgreSQL evidence is captured

Every confirmed incident includes:

- PostgreSQL version and DB identity.
- Connection counts grouped by state and wait event.
- Active sessions and transactions older than two minutes, with SQL text redacted for quoted literals.
- Sessions blocked by other backends, including `pg_blocking_pids()`.
- Locks, their holder/waiter state, and relation when available.
- Per-database counters and size.
- Key PostgreSQL settings relevant to saturation.

The monitor uses short connection, statement, and lock timeouts, so an unhealthy PostgreSQL instance cannot delay the JasperServer restart indefinitely. PostgreSQL 9.6 and newer expose wait type and wait event details in `pg_stat_activity`, which helps separate lock, I/O, client, and other waiting conditions.

## 5. Validation before production

```bash
sudo bash -n install.sh uninstall.sh /usr/local/sbin/jasper-watchdog-v2
sudo CONFIG_FILE=/etc/jasper-watchdog/jasper-watchdog.conf /usr/local/sbin/jasper-watchdog-v2
sudo systemctl status jasper-watchdog.timer --no-pager
sudo tail -f /var/log/jasper-watchdog/watchdog.log
```

To test the incident path without modifying the production service, temporarily set `HEALTH_URL` to an unused local port in a non-production window. Then verify that the incident directory includes all `pg_*.txt` files **before** the `recovery_*.txt` files. This test will trigger a real `ctlscript.sh` restart sequence against the test service — do not point it at a live JasperServer instance.

## 6. Operational rule

Do not cancel PostgreSQL backends, kill JVM threads, or reboot the VM from this watchdog. Its responsibility is strictly:

1. confirm an application health failure;
2. preserve forensic evidence;
3. diagnose and recover the unhealthy component(s) — starting whichever of `postgresql`/`tomcat` is down, always recycling a running-but-unhealthy Tomcat, escalating to a full `ctlscript.sh restart` only if that doesn't restore health and `ESCALATE_TO_FULL_RESTART=1`;
4. record whether health recovered and which recovery actions were taken.

This preserves the evidence needed to determine whether the root cause was Jasper/Tomcat, a blocked or saturated PostgreSQL workload, resource pressure, or the surrounding host.

## 7. Restart circuit breaker

`MAX_AUTORESTARTS` (default 3) and `RESTART_WINDOW_SEC` (default 900) bound how many
automatic restarts the watchdog performs inside a rolling time window. Once the limit is
reached, the watchdog marks the incident `BLOCKED_CIRCUIT_BREAKER`, skips component-aware
recovery, and requires a human to investigate and restart the service manually. Restart
timestamps are tracked in a state file next to `GLOBAL_LOG` (`restart-history.log` by
default, overridable via `RESTART_HISTORY_FILE`).

When the breaker is tripped **and the service stays down**, the watchdog still captures a
full forensic incident **once per blocked window** (the flapping snapshot a human needs),
then suppresses the per-tick churn: subsequent 15s ticks that are still blocked only append
a lightweight `event=circuit_breaker_still_blocked` line to the log — no new incident
directory, no re-capture, no repeated alert. A second block-episode timestamp file
(`circuit-breaker-blocked.marker`, overridable via `BLOCK_MARKER_FILE`) tracks this. To
resume automatic recovery, either wait for the window to elapse or clear the breaker with
`rm -f /var/log/jasper-watchdog/restart-history.log`.

## 8. Alerting hook

Set `ALERT_COMMAND` in `jasper-watchdog.conf` to the path of an executable. The watchdog
calls it as `"$ALERT_COMMAND" "<event>" "<message>"` on three events: `incident_created`,
`circuit_breaker_tripped`, and `recovery_failed`. Leave it unset to disable alerting; a
failing `ALERT_COMMAND` is logged but never blocks the watchdog. Wire it to Slack,
email, or any paging system outside this script.

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

## 10. Debug mode

On healthy ticks the watchdog is silent — the main log only records events (failed probes, incidents, recovery). That is by design, but it can feel like nothing is happening. When you need to *see* the checks, set `DEBUG=1` in `jasper-watchdog.conf`. Every health check then writes one line to `DEBUG_LOG` (default `/var/log/jasper-watchdog/watchdog-debug.log`, next to the main log):

```text
2026-07-06T05:14:16Z | DEBUG probe | http_code=200 time_total=0.081s curl_rc=0 marker=MONITOR found=yes result=OK
2026-07-06T05:14:31Z | DEBUG probe | http_code=000 time_total=?s curl_rc=7 marker=MONITOR found=n/a result=FAIL(http_code=none curl_rc=7)
2026-07-06T05:14:46Z | DEBUG probe | http_code=200 time_total=6.2s curl_rc=0 marker=MONITOR found=no result=FAIL(body_marker_missing=MONITOR)
```

You get, per check: the response time, the HTTP code, and whether `HEALTH_BODY_MARKER` was found in the body. Two ways to use it:

- **Live:** `DEBUG=1`, then `tail -f /var/log/jasper-watchdog/watchdog-debug.log` and watch each 15s tick.
- **On demand:** with `DEBUG=1` in the config, run one check by hand and read the line it appends: `sudo CONFIG_FILE=/etc/jasper-watchdog/jasper-watchdog.conf /usr/local/sbin/jasper-watchdog-v2`.

Turn `DEBUG` back to `0` when you are done — otherwise the debug log grows one line every 15 seconds (logrotate covers it, but there is no reason to leave it on). It never affects the normal recovery behavior.

# JasperServer Watchdog v2

This version does not restart JasperServer on a single failed response. It runs every **15 seconds**, repeats a failed application-health probe after **5 seconds**, and only if the failure is confirmed it creates an incident folder, captures evidence, and then executes `systemctl restart jasperserver`.

The evidence is captured **before the restart** and stays inside the same incident:

```text
/var/log/jasper-watchdog/incidents/
  jasper_YYYYMMDDTHHMMSSZ_pidNNNN/
    README.md
    incident.log
    os_*.txt
    service_*.txt
    log_tail_*.txt
    jvm_thread_dump.txt
    pg_*.txt
    restart_command.txt
    recovery_checks.log
```

## 1. Prerequisites

- `curl`, `psql`, `systemctl`, `journalctl`, `timeout`, `flock`, `ss`.
- `jcmd` or `jstack` from the JDK is recommended, so the incident includes a JVM thread dump.
- A dedicated PostgreSQL monitoring login. Do **not** reuse the application role `jasperdb` or its password.
- The watchdog is intended to run as `root`, because it needs to invoke `systemctl restart` and read Tomcat/Jasper logs.

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

Copy files to the target server and install them:

```bash
sudo install -d -m 0750 -o root -g root /etc/jasper-watchdog
sudo install -d -m 0700 -o root -g root /var/log/jasper-watchdog/incidents

sudo install -m 0700 -o root -g root jasper-watchdog-v2.sh /usr/local/sbin/jasper-watchdog-v2
sudo install -m 0600 -o root -g root jasper-watchdog.conf.example /etc/jasper-watchdog/jasper-watchdog.conf
sudo install -m 0644 -o root -g root jasper-watchdog.service /etc/systemd/system/jasper-watchdog.service
sudo install -m 0644 -o root -g root jasper-watchdog.timer /etc/systemd/system/jasper-watchdog.timer
sudo install -m 0644 -o root -g root logrotate-jasper-watchdog /etc/logrotate.d/jasper-watchdog
sudo install -m 0644 -o root -g root tmpfiles-jasper-watchdog.conf /etc/tmpfiles.d/jasper-watchdog.conf
```

Edit `/etc/jasper-watchdog/jasper-watchdog.conf` and validate these values against the server:

- `HEALTH_URL`: a JasperServer endpoint that proves the application is alive. Do not leave a mere port check as the only health condition.
- `JASPER_SERVICE`: the actual systemd service name.
- `JASPER_LOG_DIR`: the Tomcat/Jasper logs directory.

Create the password file. The line format is `host:port:database:user:password`:

```bash
sudo sh -c 'umask 077; cat > /etc/jasper-watchdog/pgpass'
# Enter exactly one line, then Ctrl+D:
# 127.0.0.1:5432:jasperserver:jasper_watchdog:REPLACE_WITH_GENERATED_PASSWORD
sudo chmod 0600 /etc/jasper-watchdog/pgpass
sudo chown root:root /etc/jasper-watchdog/pgpass
```

Enable the timer:

```bash
sudo systemctl daemon-reload
sudo systemd-tmpfiles --create /etc/tmpfiles.d/jasper-watchdog.conf
sudo systemctl enable --now jasper-watchdog.timer
systemctl list-timers jasper-watchdog.timer
```

A systemd `.timer` unit activates the accompanying `.service` according to the configured timing schedule; the service performs a single monitor execution.

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
sudo bash -n /usr/local/sbin/jasper-watchdog-v2
sudo CONFIG_FILE=/etc/jasper-watchdog/jasper-watchdog.conf /usr/local/sbin/jasper-watchdog-v2
sudo systemctl status jasper-watchdog.timer --no-pager
sudo tail -f /var/log/jasper-watchdog/watchdog.log
```

To test the incident path without modifying the production service, temporarily set `HEALTH_URL` to an unused local port and replace `JASPER_SERVICE` with a harmless disposable test service in a non-production window. Then verify that the incident directory includes all `pg_*.txt` files **before** `restart_command.txt`.

## 6. Operational rule

Do not cancel PostgreSQL backends, kill JVM threads, or reboot the VM from this watchdog. Its responsibility is strictly:

1. confirm an application health failure;
2. preserve forensic evidence;
3. restart JasperServer;
4. record whether health recovered.

This preserves the evidence needed to determine whether the root cause was Jasper/Tomcat, a blocked or saturated PostgreSQL workload, resource pressure, or the surrounding host.

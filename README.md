# JasperServer Watchdog

A bash + systemd health monitor for a JasperServer/Tomcat instance. It probes the
application health endpoint and, on a confirmed failure, captures forensic
evidence (OS, JVM thread dump, PostgreSQL activity/locks, cron and login
sessions) **before** restarting the service — with a restart circuit breaker and
an optional alert hook.

Installation and operation: **[jasper-watchdog-v2/README.md](jasper-watchdog-v2/README.md)**.

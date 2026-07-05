-- Run as the PostgreSQL administrator after first checking the version:
-- SHOW server_version_num;
--
-- PostgreSQL 10+:
--   1) Create the login role interactively (avoid placing its password in shell history):
--      CREATE ROLE jasper_watchdog LOGIN;
--      \password jasper_watchdog
--   2) Then run the grants below.
--
-- pg_monitor grants access to statistics and monitoring views without making
-- the watchdog a superuser. This supports the pre-restart SQL snapshots.

GRANT CONNECT ON DATABASE jasperserver TO jasper_watchdog;
GRANT pg_monitor TO jasper_watchdog;

-- PostgreSQL 9.6 or older does not provide pg_monitor. Do not grant SUPERUSER
-- to the watchdog. Use a tightly scoped SECURITY DEFINER function owned by the
-- PostgreSQL administrator to expose only the required pg_stat_activity / locks
-- fields, or upgrade the bundled PostgreSQL instance before enabling full detail.

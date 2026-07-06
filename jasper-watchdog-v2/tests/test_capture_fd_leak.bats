#!/usr/bin/env bats

# Regression test for the flock-fd leak: main() holds the watchdog lock via
# `exec 9>LOCK; flock -n 9`, and capture() must close fd 9 for every command
# it runs so a daemon started by a recovery action (ctlscript -> Tomcat/
# Postgres) can't inherit the lock and wedge all later ticks.

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  INCIDENT="$(mktemp -d)"
}

teardown() {
  rm -rf "$INCIDENT"
}

@test "capture does not leak the flock fd into spawned daemons" {
  command -v flock >/dev/null 2>&1 || skip "flock not available in this environment"
  local lock pidfile
  lock="$(mktemp)"
  pidfile="$(mktemp)"

  # Hold the lock exactly as main() does.
  exec 9>"$lock"
  flock -n 9

  # A recovery action backgrounds a long-lived daemon through capture().
  PIDFILE="$pidfile" capture leak.txt bash -c 'sleep 30 & echo $! > "$PIDFILE"'

  # main() exiting drops its own fd 9; only a leaked child could still hold it.
  exec 9>&-

  # Fresh acquire succeeds only if no child inherited the lock.
  run flock -n "$lock" -c 'true'

  kill "$(cat "$pidfile")" 2>/dev/null || true
  rm -f "$lock" "$pidfile"

  [ "$status" -eq 0 ]
}

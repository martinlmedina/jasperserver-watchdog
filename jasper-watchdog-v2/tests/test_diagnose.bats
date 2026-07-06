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

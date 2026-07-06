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

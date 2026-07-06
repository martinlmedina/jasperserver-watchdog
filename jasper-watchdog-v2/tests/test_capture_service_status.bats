#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
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

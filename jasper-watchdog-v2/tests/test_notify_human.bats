#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  GLOBAL_LOG="$(mktemp)"
  INCIDENT=""
  ALERT_LOG="$(mktemp)"
  export ALERT_LOG
  ALERT_COMMAND="$BATS_TEST_DIRNAME/fixtures/fake-alert-command"
}

teardown() {
  rm -f "$GLOBAL_LOG" "$ALERT_LOG"
}

@test "does nothing when ALERT_COMMAND is unset" {
  unset ALERT_COMMAND
  run notify_human "test_event" "test message"
  [ "$status" -eq 0 ]
}

@test "invokes ALERT_COMMAND with event and message" {
  notify_human "incident_created" "hello world"
  run cat "$ALERT_LOG"
  [[ "$output" == *"event=incident_created"* ]]
  [[ "$output" == *"message=hello world"* ]]
}

@test "logs but does not fail when ALERT_COMMAND fails" {
  ALERT_COMMAND="$BATS_TEST_DIRNAME/fixtures/fake-alert-command-failing"
  run notify_human "incident_created" "hello world"
  [ "$status" -eq 0 ]
  run grep -c "alert_command_failed" "$GLOBAL_LOG"
  [ "$output" -eq 1 ]
}

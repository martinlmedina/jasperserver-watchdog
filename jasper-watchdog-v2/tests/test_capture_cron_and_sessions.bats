#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  INCIDENT="$(mktemp -d)"
  GLOBAL_LOG="$(mktemp)"
  TOMCAT_SHUTDOWN_PORT=8005
}

teardown() {
  rm -rf "$INCIDENT"
  rm -f "$GLOBAL_LOG"
}

@test "writes cron_and_sessions.txt with all evidence sections" {
  capture_cron_and_sessions
  [ -f "$INCIDENT/cron_and_sessions.txt" ]
  run cat "$INCIDENT/cron_and_sessions.txt"
  [[ "$output" == *"crontab -l (root)"* ]]
  [[ "$output" == *"other user crontabs"* ]]
  [[ "$output" == *"listening sockets on shutdown-related ports"* ]]
  [[ "$output" == *"last 20 logins"* ]]
  [[ "$output" == *"who is currently logged in"* ]]
  [[ "$output" == *"limpiar_tomcat.sh"* ]]
}

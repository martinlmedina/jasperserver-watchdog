#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  INCIDENT="$(mktemp -d)"
  INCIDENT_ID="jasper_20260705T000000Z_pid1"
  HEALTH_URL="http://127.0.0.1:8080/jasperserver/login.html"
  FIRST_PROBE="curl_rc=0; http_code=500"
  CONFIRM_PROBE="curl_rc=0; http_code=500"
  RECOVERY_PROBE="curl_rc=0; http_code=200"
}

teardown() {
  rm -rf "$INCIDENT"
}

@test "includes the recovery actions taken in the incident summary" {
  RECOVERY_ACTIONS="postgres_start tomcat_restart "
  write_summary "RECOVERED"
  run cat "$INCIDENT/README.md"
  [[ "$output" == *"Recovery actions taken:** postgres_start tomcat_restart"* ]]
}

@test "shows none when no recovery actions were recorded" {
  RECOVERY_ACTIONS=""
  write_summary "BLOCKED_CIRCUIT_BREAKER"
  run cat "$INCIDENT/README.md"
  [[ "$output" == *"Recovery actions taken:** none"* ]]
}

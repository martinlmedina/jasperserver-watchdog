#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  HEALTH_URL="http://example.invalid/health"
  HEALTH_CONNECT_TIMEOUT_SEC=3
  HEALTH_MAX_TIME_SEC=10
  EXPECTED_HTTP_CODES="200 302"
  HEALTH_BODY_MARKER=""
  SLOW_RESPONSE_THRESHOLD_SEC=""
  export FAKE_CURL_RC=0
  export FAKE_CURL_HTTP_CODE=200
  export FAKE_CURL_TIME_TOTAL=0.100
  export FAKE_CURL_BODY=""
  export FAKE_CURL_ERR=""
}

@test "succeeds on an expected HTTP code with no marker or threshold configured" {
  run health_probe
  [ "$status" -eq 0 ]
}

@test "fails on an unexpected HTTP code" {
  FAKE_CURL_HTTP_CODE=500
  run health_probe
  [ "$status" -eq 1 ]
}

@test "succeeds when the configured body marker is present" {
  HEALTH_BODY_MARKER="MONITOR"
  FAKE_CURL_BODY="...MONITOR..."
  run health_probe
  [ "$status" -eq 0 ]
}

@test "fails when the configured body marker is absent" {
  HEALTH_BODY_MARKER="MONITOR"
  FAKE_CURL_BODY="<html>login</html>"
  run health_probe
  [ "$status" -eq 1 ]
}

@test "fails when the response is slower than the configured threshold" {
  SLOW_RESPONSE_THRESHOLD_SEC="4"
  FAKE_CURL_TIME_TOTAL=7.5
  run health_probe
  [ "$status" -eq 1 ]
}

@test "succeeds when the response is under the configured threshold" {
  SLOW_RESPONSE_THRESHOLD_SEC="4"
  FAKE_CURL_TIME_TOTAL=1.2
  run health_probe
  [ "$status" -eq 0 ]
}

@test "DEBUG=1 writes one detail line per probe on success" {
  DEBUG=1
  DEBUG_LOG="$(mktemp)"
  HEALTH_BODY_MARKER="MONITOR"
  FAKE_CURL_BODY="...MONITOR..."
  run health_probe
  [ "$status" -eq 0 ]
  run cat "$DEBUG_LOG"
  [[ "$output" == *"DEBUG probe"* ]]
  [[ "$output" == *"http_code=200"* ]]
  [[ "$output" == *"time_total="* ]]
  [[ "$output" == *"found=yes"* ]]
  [[ "$output" == *"result=OK"* ]]
  rm -f "$DEBUG_LOG"
}

@test "DEBUG=1 records a failed marker check as found=no and FAIL" {
  DEBUG=1
  DEBUG_LOG="$(mktemp)"
  HEALTH_BODY_MARKER="MONITOR"
  FAKE_CURL_BODY="<html>login</html>"
  run health_probe
  [ "$status" -eq 1 ]
  run cat "$DEBUG_LOG"
  [[ "$output" == *"found=no"* ]]
  [[ "$output" == *"result=FAIL(body_marker_missing=MONITOR)"* ]]
  rm -f "$DEBUG_LOG"
}

@test "writes nothing to the debug log when DEBUG is off" {
  DEBUG=0
  DEBUG_LOG="$(mktemp)"
  run health_probe
  [ "$status" -eq 0 ]
  [ ! -s "$DEBUG_LOG" ]
  rm -f "$DEBUG_LOG"
}

@test "leaves the response body file in place after a failure" {
  FAKE_CURL_HTTP_CODE=500
  FAKE_CURL_BODY="<html>error</html>"
  health_probe || true
  [ -f "$PROBE_BODY_FILE" ]
  run cat "$PROBE_BODY_FILE"
  [[ "$output" == *"error"* ]]
  rm -f "$PROBE_BODY_FILE"
}

@test "removes the response body file after a successful probe" {
  health_probe
  [ ! -e "$PROBE_BODY_FILE" ]
}

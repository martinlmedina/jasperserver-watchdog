#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
}

@test "expected_http_code matches a code in the list" {
  EXPECTED_HTTP_CODES="200 302"
  run expected_http_code "200"
  [ "$status" -eq 0 ]
}

@test "expected_http_code rejects a code not in the list" {
  EXPECTED_HTTP_CODES="200 302"
  run expected_http_code "500"
  [ "$status" -eq 1 ]
}

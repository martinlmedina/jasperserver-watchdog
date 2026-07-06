#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  INCIDENT="$(mktemp -d)"
  GLOBAL_LOG="$(mktemp)"
  JASPER_LOG_DIR="$(mktemp -d)"
  TAIL_LINES=10
  JASPER_LOG_MAX_AGE_MIN=1440

  printf 'live catalina.out line\n' > "$JASPER_LOG_DIR/catalina.out"
  printf 'recent dated log\n' > "$JASPER_LOG_DIR/catalina.2026-07-06.log"
  printf 'stale rotated log\n' > "$JASPER_LOG_DIR/catalina.2026-04-26.log"
  printf 'stale localhost log\n' > "$JASPER_LOG_DIR/localhost.2026-04-26.log"
  # Backdate the stale logs well outside the 24h window.
  touch -t 202601010000 "$JASPER_LOG_DIR/catalina.2026-04-26.log" "$JASPER_LOG_DIR/localhost.2026-04-26.log"
}

teardown() {
  rm -rf "$INCIDENT" "$JASPER_LOG_DIR"
  rm -f "$GLOBAL_LOG"
}

@test "always captures catalina.out" {
  capture_jasper_logs
  [ -f "$INCIDENT/log_tail_catalina.out.txt" ]
}

@test "captures logs modified within the age window" {
  capture_jasper_logs
  [ -f "$INCIDENT/log_tail_catalina.2026-07-06.log.txt" ]
}

@test "skips rotated logs older than the age window" {
  capture_jasper_logs
  [ ! -f "$INCIDENT/log_tail_catalina.2026-04-26.log.txt" ]
  [ ! -f "$INCIDENT/log_tail_localhost.2026-04-26.log.txt" ]
}

@test "records a note when the log directory does not exist" {
  JASPER_LOG_DIR="$INCIDENT/does-not-exist"
  capture_jasper_logs
  [ -f "$INCIDENT/jasper_logs_note.txt" ]
}

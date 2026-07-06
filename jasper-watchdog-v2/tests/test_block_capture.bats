#!/usr/bin/env bats

# block_capture_due() gates the once-per-window forensic capture while the
# circuit breaker stays tripped, so a blocked-and-down service does not spawn a
# fresh incident + full evidence capture on every 15s tick.

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  BLOCK_MARKER_FILE="$(mktemp)"
  : > "$BLOCK_MARKER_FILE"   # start empty (no prior blocked incident)
  RESTART_WINDOW_SEC=900
}

teardown() {
  rm -f "$BLOCK_MARKER_FILE"
}

@test "captures on the first blocked tick when no marker exists" {
  run block_capture_due
  [ "$status" -eq 0 ]
}

@test "records the capture timestamp so the next tick is suppressed" {
  block_capture_due
  run cat "$BLOCK_MARKER_FILE"
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "suppresses subsequent blocked ticks within the window" {
  block_capture_due
  run block_capture_due
  [ "$status" -eq 1 ]
}

@test "captures again once the window has elapsed" {
  local old=$(( $(date +%s) - RESTART_WINDOW_SEC - 60 ))
  printf '%s\n' "$old" > "$BLOCK_MARKER_FILE"
  run block_capture_due
  [ "$status" -eq 0 ]
}

@test "treats a corrupt marker as no prior capture" {
  printf 'not-a-number\n' > "$BLOCK_MARKER_FILE"
  run block_capture_due
  [ "$status" -eq 0 ]
}

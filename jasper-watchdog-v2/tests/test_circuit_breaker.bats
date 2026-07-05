#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  RESTART_HISTORY_FILE="$(mktemp)"
  MAX_AUTORESTARTS=3
  RESTART_WINDOW_SEC=900
}

teardown() {
  rm -f "$RESTART_HISTORY_FILE"
}

@test "allows restarts up to the configured maximum" {
  run take_restart_slot
  [ "$status" -eq 0 ]
  run take_restart_slot
  [ "$status" -eq 0 ]
  run take_restart_slot
  [ "$status" -eq 0 ]
}

@test "blocks the restart once the maximum is reached within the window" {
  take_restart_slot
  take_restart_slot
  take_restart_slot
  run take_restart_slot
  [ "$status" -eq 1 ]
}

@test "does not count restarts older than the window" {
  local old_timestamp=$(( $(date +%s) - RESTART_WINDOW_SEC - 60 ))
  printf '%s\n' "$old_timestamp" > "$RESTART_HISTORY_FILE"
  take_restart_slot
  take_restart_slot
  run take_restart_slot
  [ "$status" -eq 0 ]
}

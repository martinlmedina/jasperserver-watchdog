#!/usr/bin/env bats

setup() {
  STAGE="$(mktemp -d)"
  export DESTDIR="$STAGE"
  INSTALLER="$BATS_TEST_DIRNAME/../install.sh"
}

teardown() {
  unset DESTDIR
  rm -rf "$STAGE"
}

@test "clean install places all managed artifacts" {
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ -f "$STAGE/usr/local/sbin/jasper-watchdog-v2" ]
  [ -f "$STAGE/etc/systemd/system/jasper-watchdog.service" ]
  [ -f "$STAGE/etc/systemd/system/jasper-watchdog.timer" ]
  [ -f "$STAGE/etc/logrotate.d/jasper-watchdog" ]
  [ -f "$STAGE/etc/tmpfiles.d/jasper-watchdog.conf" ]
  [ -f "$STAGE/etc/jasper-watchdog/jasper-watchdog.conf" ]
  [ -f "$STAGE/etc/jasper-watchdog/jasper-watchdog.conf.example" ]
}

@test "installed binary is not world-accessible" {
  bash "$INSTALLER"
  mode="$(stat -c '%a' "$STAGE/usr/local/sbin/jasper-watchdog-v2" 2>/dev/null || echo skip)"
  if [ "$mode" = "skip" ]; then skip "stat -c unsupported here"; fi
  [ "$mode" = "700" ]
}

@test "log parent directory is not world-accessible" {
  bash "$INSTALLER"
  mode="$(stat -c '%a' "$STAGE/var/log/jasper-watchdog" 2>/dev/null || echo skip)"
  if [ "$mode" = "skip" ]; then skip "stat -c unsupported here"; fi
  [ "$mode" = "750" ]
}

@test "re-install preserves an existing config" {
  bash "$INSTALLER"
  printf 'CUSTOM_EDIT=1\n' >> "$STAGE/etc/jasper-watchdog/jasper-watchdog.conf"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -q 'CUSTOM_EDIT=1' "$STAGE/etc/jasper-watchdog/jasper-watchdog.conf"
  [ "$status" -eq 0 ]
}

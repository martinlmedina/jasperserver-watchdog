#!/usr/bin/env bats

setup() {
  STAGE="$(mktemp -d)"
  export DESTDIR="$STAGE"
  INSTALLER="$BATS_TEST_DIRNAME/../install.sh"
  UNINSTALLER="$BATS_TEST_DIRNAME/../uninstall.sh"
  bash "$INSTALLER"
}

teardown() {
  unset DESTDIR
  rm -rf "$STAGE"
}

@test "uninstall removes managed artifacts but keeps config by default" {
  run bash "$UNINSTALLER"
  [ "$status" -eq 0 ]
  [ ! -f "$STAGE/usr/local/sbin/jasper-watchdog-v2" ]
  [ ! -f "$STAGE/etc/systemd/system/jasper-watchdog.service" ]
  [ ! -f "$STAGE/etc/systemd/system/jasper-watchdog.timer" ]
  [ ! -f "$STAGE/etc/logrotate.d/jasper-watchdog" ]
  [ ! -f "$STAGE/etc/tmpfiles.d/jasper-watchdog.conf" ]
  # Config and incident evidence are preserved.
  [ -f "$STAGE/etc/jasper-watchdog/jasper-watchdog.conf" ]
  [ -d "$STAGE/var/log/jasper-watchdog/incidents" ]
}

@test "uninstall --purge also removes config and evidence" {
  run bash "$UNINSTALLER" --purge
  [ "$status" -eq 0 ]
  [ ! -d "$STAGE/etc/jasper-watchdog" ]
  [ ! -d "$STAGE/var/log/jasper-watchdog" ]
}

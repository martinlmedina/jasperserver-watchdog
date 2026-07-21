#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
}

# Regression: the bundled PostgreSQL runs from a path containing
# "jasperreports-server", so a pattern that includes that substring matches
# postgres too. pgrep returns it first (lower PID), and the watchdog ends up
# thread-dumping PostgreSQL instead of the Tomcat JVM -> empty dumps.
@test "find_jasper_java_pid selects the Tomcat JVM, not the bundled PostgreSQL" {
  run find_jasper_java_pid
  [ "$status" -eq 0 ]
  [ "$output" = "2215694" ]
}

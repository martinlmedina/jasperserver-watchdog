#!/usr/bin/env bats

# limpiar_tomcat.sh cleans Tomcat junk by age while the stack stays up. These
# tests source the script (main is guarded) and drive the cleaner functions
# against throwaway TEMP_DIR/LOG_DIR fixtures, backdating files with `touch -d`
# to land on either side of each age threshold.

setup() {
  source "$BATS_TEST_DIRNAME/../limpiar_tomcat.sh"

  TEMP_DIR="$(mktemp -d)"
  LOG_DIR="$(mktemp -d)"
  LOG_FILE="$(mktemp)"

  HPROF_MAX_AGE_DAYS=3
  LOG_MAX_AGE_DAYS=21
  TEMP_MAX_AGE_MIN=720
  JDBC_MAX_AGE_MIN=1440
  CATALINA_OUT_MAX_MB=200
  DRY_RUN=0

  RECLAIMED_BYTES=0
  COUNT=0
}

teardown() {
  rm -rf "$TEMP_DIR" "$LOG_DIR"
  rm -f "$LOG_FILE"
}

# ---- heap dumps -----------------------------------------------------------

@test "clean_heapdumps removes a heap dump older than the age limit" {
  printf 'dump\n' > "$TEMP_DIR/java_pid1.hprof"
  touch -d '5 days ago' "$TEMP_DIR/java_pid1.hprof"
  clean_heapdumps
  [ ! -f "$TEMP_DIR/java_pid1.hprof" ]
}

@test "clean_heapdumps keeps a recent heap dump" {
  printf 'dump\n' > "$TEMP_DIR/java_pid2.hprof"
  touch -d '1 hour ago' "$TEMP_DIR/java_pid2.hprof"
  clean_heapdumps
  [ -f "$TEMP_DIR/java_pid2.hprof" ]
}

@test "clean_heapdumps logs the size of what it removes" {
  printf 'dump-body\n' > "$TEMP_DIR/java_pid3.hprof"
  touch -d '5 days ago' "$TEMP_DIR/java_pid3.hprof"
  clean_heapdumps
  run cat "$LOG_FILE"
  [[ "$output" == *"[heapdump] deleted"* ]]
}

# ---- catalina.out ---------------------------------------------------------

@test "clean_catalina_out truncates in place when over threshold, preserving the inode" {
  CATALINA_OUT_MAX_MB=0            # any non-empty file is over the limit
  printf 'noisy startup log\n' > "$LOG_DIR/catalina.out"
  local before_inode after_inode
  before_inode="$(stat -c '%i' "$LOG_DIR/catalina.out")"

  clean_catalina_out

  after_inode="$(stat -c '%i' "$LOG_DIR/catalina.out")"
  [ -f "$LOG_DIR/catalina.out" ]                                 # not deleted
  [ "$before_inode" = "$after_inode" ]                           # same fd/inode
  [ "$(stat -c '%s' "$LOG_DIR/catalina.out")" -eq 0 ]            # emptied
}

@test "clean_catalina_out leaves a small file untouched" {
  CATALINA_OUT_MAX_MB=100
  printf 'small\n' > "$LOG_DIR/catalina.out"
  clean_catalina_out
  [ "$(cat "$LOG_DIR/catalina.out")" = "small" ]
}

# ---- rotated logs ---------------------------------------------------------

@test "clean_old_logs removes stale dated logs but keeps recent ones" {
  printf 'old\n'    > "$LOG_DIR/catalina.2026-01-01.log"
  printf 'recent\n' > "$LOG_DIR/catalina.2026-07-06.log"
  touch -d '40 days ago' "$LOG_DIR/catalina.2026-01-01.log"
  touch -d '2 days ago'  "$LOG_DIR/catalina.2026-07-06.log"

  clean_old_logs

  [ ! -f "$LOG_DIR/catalina.2026-01-01.log" ]
  [ -f "$LOG_DIR/catalina.2026-07-06.log" ]
}

@test "clean_old_logs never touches catalina.out" {
  printf 'live\n' > "$LOG_DIR/catalina.out"
  touch -d '40 days ago' "$LOG_DIR/catalina.out"   # old, but it is the live log
  clean_old_logs
  [ -f "$LOG_DIR/catalina.out" ]
}

# ---- report temp ----------------------------------------------------------

@test "clean_report_temp removes stale virtualizer and JR temp files" {
  printf 'x\n' > "$TEMP_DIR/file.buff.os.123.tmp"
  printf 'x\n' > "$TEMP_DIR/+~JF456.tmp"
  touch -d '2 days ago' "$TEMP_DIR/file.buff.os.123.tmp" "$TEMP_DIR/+~JF456.tmp"

  clean_report_temp

  [ ! -f "$TEMP_DIR/file.buff.os.123.tmp" ]
  [ ! -f "$TEMP_DIR/+~JF456.tmp" ]
}

@test "clean_report_temp keeps in-flight (recent) temp files" {
  printf 'x\n' > "$TEMP_DIR/file.buff.os.789.tmp"
  touch -d '5 minutes ago' "$TEMP_DIR/file.buff.os.789.tmp"
  clean_report_temp
  [ -f "$TEMP_DIR/file.buff.os.789.tmp" ]
}

@test "clean_report_temp cleans stale files under buffer/ and prunes empty dirs" {
  mkdir -p "$TEMP_DIR/buffer/sub"
  printf 'x\n' > "$TEMP_DIR/buffer/sub/old.dat"
  touch -d '2 days ago' "$TEMP_DIR/buffer/sub/old.dat"

  clean_report_temp

  [ ! -f "$TEMP_DIR/buffer/sub/old.dat" ]
  [ ! -d "$TEMP_DIR/buffer/sub" ]      # empty subdir pruned
  [ -d "$TEMP_DIR/buffer" ]            # buffer root kept
}

@test "clean_report_temp never deletes catalina.pid or the app dir" {
  printf '12345\n' > "$TEMP_DIR/catalina.pid"
  mkdir -p "$TEMP_DIR/jasperserver/keystore"
  printf 'k\n' > "$TEMP_DIR/jasperserver/keystore/key"
  touch -d '30 days ago' "$TEMP_DIR/catalina.pid" "$TEMP_DIR/jasperserver/keystore/key"

  clean_report_temp

  [ -f "$TEMP_DIR/catalina.pid" ]
  [ -f "$TEMP_DIR/jasperserver/keystore/key" ]
}

# ---- JDBC jars ------------------------------------------------------------

@test "clean_jdbc_jars removes an old jar from a previous instance" {
  printf 'pid\n' > "$TEMP_DIR/catalina.pid"
  touch -d '1 hour ago' "$TEMP_DIR/catalina.pid"
  printf 'jar\n' > "$TEMP_DIR/jdbc-old.jar"
  touch -d '3 days ago' "$TEMP_DIR/jdbc-old.jar"

  clean_jdbc_jars

  [ ! -f "$TEMP_DIR/jdbc-old.jar" ]
}

@test "clean_jdbc_jars keeps the current instance jar even when it is old" {
  # Tomcat has been up for a week: pid file and its jar are both old, but the
  # jar is as new as the pid, so it must be kept.
  printf 'pid\n' > "$TEMP_DIR/catalina.pid"
  touch -d '7 days ago' "$TEMP_DIR/catalina.pid"
  printf 'jar\n' > "$TEMP_DIR/jdbc-current.jar"
  touch -d '7 days ago' "$TEMP_DIR/jdbc-current.jar"

  clean_jdbc_jars

  [ -f "$TEMP_DIR/jdbc-current.jar" ]
}

@test "clean_jdbc_jars keeps the newest jar when there is no pid file" {
  printf 'jar\n' > "$TEMP_DIR/jdbc-a.jar"
  printf 'jar\n' > "$TEMP_DIR/jdbc-b.jar"
  touch -d '10 days ago' "$TEMP_DIR/jdbc-a.jar"
  touch -d '9 days ago'  "$TEMP_DIR/jdbc-b.jar"

  clean_jdbc_jars

  [ ! -f "$TEMP_DIR/jdbc-a.jar" ]      # older one removed
  [ -f "$TEMP_DIR/jdbc-b.jar" ]        # newest kept as the safe fallback
}

# ---- dry run & accounting -------------------------------------------------

@test "DRY_RUN deletes nothing but still reports and counts bytes" {
  DRY_RUN=1
  printf 'dump\n' > "$TEMP_DIR/java_pid9.hprof"
  touch -d '5 days ago' "$TEMP_DIR/java_pid9.hprof"

  clean_heapdumps

  [ -f "$TEMP_DIR/java_pid9.hprof" ]           # still there
  [ "$COUNT" -eq 1 ]                           # but accounted for
  [ "${RECLAIMED_BYTES:-0}" -gt 0 ]
  run cat "$LOG_FILE"
  [[ "$output" == *"DRY_RUN would delete"* ]]
}

@test "reclaimed byte accounting accumulates across cleaners" {
  printf 'aaaa\n' > "$TEMP_DIR/java_pidA.hprof"
  printf 'bbbb\n' > "$TEMP_DIR/file.buff.os.1.tmp"
  touch -d '5 days ago' "$TEMP_DIR/java_pidA.hprof"
  touch -d '2 days ago' "$TEMP_DIR/file.buff.os.1.tmp"

  clean_heapdumps
  clean_report_temp

  [ "$COUNT" -eq 2 ]
  [ "${RECLAIMED_BYTES}" -gt 0 ]
}

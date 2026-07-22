#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  INCIDENT="$(mktemp -d)"
  GLOBAL_LOG="$(mktemp)"
  SIGQUIT_WAIT_SEC=0
}

teardown() {
  rm -rf "$INCIDENT"
  rm -f "$GLOBAL_LOG"
}

@test "thread_dump_has_threads: true when the file has a thread stack header" {
  printf '2026-01-01 00:00:00\nFull thread dump\n"main" #1 prio=5 os_prio=0\n' > "$INCIDENT/td.txt"
  run thread_dump_has_threads "$INCIDENT/td.txt"
  [ "$status" -eq 0 ]
}

@test "thread_dump_has_threads: false on an attach-failure file with no threads" {
  printf '2414213:\ncom.sun.tools.attach.AttachNotSupportedException: target process not responding\n# exit_code=1\n' > "$INCIDENT/td.txt"
  run thread_dump_has_threads "$INCIDENT/td.txt"
  [ "$status" -ne 0 ]
}

@test "capture_sigquit_dump: SIGQUITs the JVM and appends the new catalina.out lines" {
  local catalina_out="$INCIDENT/catalina.out"
  printf 'old log line 1\nold log line 2\n' > "$catalina_out"

  # The real JVM writes its thread dump to catalina.out on SIGQUIT. Emulate that
  # by overriding `kill` (a shell builtin) with a function that appends a dump.
  kill() {
    if [[ "$1" == "-3" ]]; then
      printf 'Full thread dump\n"http-nio-8080-exec-1" #42 daemon prio=5\n   java.lang.Thread.State: RUNNABLE\n' >> "$catalina_out"
    fi
    return 0
  }

  capture_sigquit_dump 2414213 "$catalina_out" "$INCIDENT/jvm_thread_dump.txt"

  run cat "$INCIDENT/jvm_thread_dump.txt"
  [[ "$output" == *"SIGQUIT thread dump"* ]]
  [[ "$output" == *"http-nio-8080-exec-1"* ]]
  [[ "$output" != *"old log line"* ]]   # only the delta, not the whole file
}

@test "capture_sigquit_dump: notes when catalina.out is missing" {
  capture_sigquit_dump 2414213 "$INCIDENT/nope.out" "$INCIDENT/jvm_thread_dump.txt"
  run cat "$INCIDENT/jvm_thread_dump.txt"
  [[ "$output" == *"catalina.out not found"* ]]
}

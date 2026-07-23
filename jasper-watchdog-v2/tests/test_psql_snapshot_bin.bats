#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../jasper-watchdog-v2.sh"
  PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  INCIDENT="$(mktemp -d)"
  GLOBAL_LOG="$(mktemp)"
  PGHOST=127.0.0.1; PGPORT=5432; PGUSER=watch; PGDATABASE=jasper; PGPASSFILE=/dev/null
  PG_CONNECT_TIMEOUT_SEC=3; PG_STATEMENT_TIMEOUT_MS=3500; PG_LOCK_TIMEOUT_MS=800
  CAPTURE_TIMEOUT_SEC=8
}

teardown() {
  rm -rf "$INCIDENT"
  rm -f "$GLOBAL_LOG"
}

# Regression: the bundled PostgreSQL's psql lives at
# $JASPER_HOME/postgresql/bin/psql, not on PATH. psql_snapshot must honour a
# configurable PSQL_BIN so the DB snapshot doesn't fail with 127 (psql not found).
@test "psql_snapshot runs PSQL_BIN, not a bare psql from PATH" {
  local fake="$INCIDENT/fake-psql"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null        # consume the SQL on stdin
echo "SNAPSHOT_OK"
EOF
  chmod +x "$fake"
  PSQL_BIN="$fake"

  psql_snapshot pg_probe.txt "SELECT 1;"

  run cat "$INCIDENT/pg_probe.txt"
  [[ "$output" == *"SNAPSHOT_OK"* ]]
  [[ "$output" == *"exit_code=0"* ]]
}

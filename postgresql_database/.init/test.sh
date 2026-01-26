#!/usr/bin/env bash
set -euo pipefail
# Functional DB test (start, query, stop) with chmod fallback
WORKSPACE="/home/kavia/workspace/code-generation/github-insights-dashboard-42879/postgresql_database"
DATA_DIR="/var/lib/postgresql/data"
cd "$WORKSPACE"
MAX_WAIT=${MAX_WAIT:-30}
PG_CTL=$(command -v pg_ctl || true)
PSQL=$(command -v psql || true)
PG_ISREADY=$(command -v pg_isready || true)
[ -n "$PG_CTL" ] || { echo "pg_ctl missing" >&2; exit 2; }
[ -n "$PSQL" ] || { echo "psql missing" >&2; exit 3; }
[ -n "$PG_ISREADY" ] || { echo "pg_isready missing" >&2; exit 4; }
# Start DB if not running
if sudo -u postgres "$PG_CTL" -D "$DATA_DIR" status >/dev/null 2>&1; then :; else
  sudo -u postgres "$PG_CTL" -D "$DATA_DIR" -w start -o "-c config_file='$DATA_DIR/postgresql.conf'" >/dev/null
fi
# Wait for readiness
i=0
while [ $i -lt "$MAX_WAIT" ]; do
  pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && break || true
  sleep 1; i=$((i+1))
done
pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 || { echo "Postgres not ready" >&2; sudo -u postgres "$PG_CTL" -D "$DATA_DIR" -m fast -w stop >/dev/null || true; exit 7; }
# Prepare test runner file
TEST_RUNNER="$WORKSPACE/.init/test.sh"
mkdir -p "$(dirname "$TEST_RUNNER")"
cat > "$TEST_RUNNER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
PSQL=$(command -v psql)
DB="${POSTGRES_DB:-devdb}"
USER="${POSTGRES_USER:-devuser}"
PGPASS="${POSTGRES_PASSWORD:-}"
[ -z "$PGPASS" ] && [ -r /run/secrets/pg_password ] && PGPASS=$(cat /run/secrets/pg_password)
if [ -n "$PGPASS" ]; then
  PGPASSF=$(mktemp -p /tmp pgpass.XXXX); trap 'rm -f "$PGPASSF"' EXIT INT TERM
  printf '127.0.0.1:5432:%s:%s:%s\n' "$DB" "$USER" "$PGPASS" > "$PGPASSF"; chmod 600 "$PGPASSF"; sudo chown postgres:postgres "$PGPASSF"
  sudo -u postgres env PGPASSFILE="$PGPASSF" "$PSQL" -h 127.0.0.1 -U "$USER" -d "$DB" -c "CREATE TABLE IF NOT EXISTS dev_health(id serial primary key, msg text);"
  sudo -u postgres env PGPASSFILE="$PGPASSF" "$PSQL" -h 127.0.0.1 -U "$USER" -d "$DB" -c "INSERT INTO dev_health(msg) VALUES('ok');"
  RESULT=$(sudo -u postgres env PGPASSFILE="$PGPASSF" "$PSQL" -h 127.0.0.1 -U "$USER" -d "$DB" -t -c "SELECT msg FROM dev_health ORDER BY id DESC LIMIT 1;" | tr -d '[:space:]')
  rm -f "$PGPASSF"
else
  sudo -u postgres "$PSQL" -h 127.0.0.1 -U "$USER" -d "$DB" -c "CREATE TABLE IF NOT EXISTS dev_health(id serial primary key, msg text);"
  sudo -u postgres "$PSQL" -h 127.0.0.1 -U "$USER" -d "$DB" -c "INSERT INTO dev_health(msg) VALUES('ok');"
  RESULT=$(sudo -u postgres "$PSQL" -h 127.0.0.1 -U "$USER" -d "$DB" -t -c "SELECT msg FROM dev_health ORDER BY id DESC LIMIT 1;" | tr -d '[:space:]')
fi
[ "$RESULT" = "ok" ] || { echo "DB functional test failed: $RESULT" >&2; exit 8; }
EOF
chmod 0644 "$TEST_RUNNER" || true
# Try to make it executable; if not permitted, we'll run via 'bash file'
if chmod +x "$TEST_RUNNER" 2>/dev/null; then
  RUN_CMD=("bash" "-c" "$TEST_RUNNER")
else
  if [ -r "$TEST_RUNNER" ]; then
    RUN_CMD=("bash" "$TEST_RUNNER")
  else
    echo "Cannot read test runner $TEST_RUNNER; check permissions" >&2
    sudo -u postgres "$PG_CTL" -D "$DATA_DIR" -m fast -w stop >/dev/null || true
    exit 9
  fi
fi
# Execute test runner
"${RUN_CMD[@]}"
# Stop DB cleanly
sudo -u postgres "$PG_CTL" -D "$DATA_DIR" -m fast -w stop >/dev/null || true
echo "DB functional test passed"
exit 0

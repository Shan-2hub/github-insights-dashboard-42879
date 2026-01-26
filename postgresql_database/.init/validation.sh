#!/usr/bin/env bash
set -euo pipefail
# Validation: full lifecycle - start (foreground), healthcheck, dump, and clean stop
WORKSPACE="/home/kavia/workspace/code-generation/github-insights-dashboard-42879/postgresql_database"
DATA_DIR="/var/lib/postgresql/data"
cd "$WORKSPACE"
MAX_WAIT=${MAX_WAIT:-30}
# start postgres foreground process via init_start_postgres.sh as postgres user (exec keeps PID as child)
sudo -u postgres bash -c "exec '$WORKSPACE/init_start_postgres.sh'" &
PG_PID=$!
cleanup() {
  kill -TERM "$PG_PID" 2>/dev/null || true
  wait "$PG_PID" 2>/dev/null || true
}
trap 'cleanup' EXIT INT TERM
# wait for readiness
i=0
while [ $i -lt "$MAX_WAIT" ]; do pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && break || true; sleep 1; i=$((i+1)); done
pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 || { echo "Validation: postgres not ready within ${MAX_WAIT}s" >&2; cleanup; exit 9; }
# prepare password handling
PGPASS="${POSTGRES_PASSWORD:-}"
[ -z "$PGPASS" ] && [ -r /run/secrets/pg_password ] && PGPASS=$(cat /run/secrets/pg_password || true)
OUTFILE="/tmp/validation_pg_dump_$(date +%s).dump"
if [ -n "$PGPASS" ]; then
  PGPASSF=$(mktemp -p /tmp pgpass.XXXX)
  # ensure temp file removed and DB stopped on exit
  trap 'rm -f "$PGPASSF"; cleanup' EXIT INT TERM
  printf '127.0.0.1:5432:%s:%s:%s\n' "${POSTGRES_DB:-devdb}" "${POSTGRES_USER:-devuser}" "$PGPASS" > "$PGPASSF"
  chmod 600 "$PGPASSF"
  sudo chown postgres:postgres "$PGPASSF" || true
  sudo -u postgres env PGPASSFILE="$PGPASSF" pg_dump -h 127.0.0.1 -U "${POSTGRES_USER:-devuser}" -Fc "${POSTGRES_DB:-devdb}" -f "$OUTFILE"
  rm -f "$PGPASSF"
else
  sudo -u postgres pg_dump -h 127.0.0.1 -U "${POSTGRES_USER:-devuser}" -Fc "${POSTGRES_DB:-devdb}" -f "$OUTFILE"
fi
[ -s "$OUTFILE" ] || { echo "Validation: dump failed" >&2; cleanup; exit 10; }
echo "Validation: dump created at $OUTFILE"
# stop postgres cleanly
cleanup
echo "Validation: stopped postgres cleanly"
exit 0

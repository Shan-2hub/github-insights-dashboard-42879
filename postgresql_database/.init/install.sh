#!/usr/bin/env bash
set -euo pipefail
WORKSPACE="/home/kavia/workspace/code-generation/github-insights-dashboard-42879/postgresql_database"
mkdir -p "$WORKSPACE" && cd "$WORKSPACE"
# quick sudo sanity
if ! command -v sudo >/dev/null 2>&1; then echo "sudo not found" >&2; exit 2; fi
need_bins=(postgres initdb pg_ctl psql pg_isready pg_dump pg_restore)
missing_bins=()
for b in "${need_bins[@]}"; do command -v "$b" >/dev/null 2>&1 || missing_bins+=("$b"); done
if [ ${#missing_bins[@]} -gt 0 ]; then
  echo "Missing binaries: ${missing_bins[*]}. Will attempt to install minimal packages if possible." >&2
  if command -v apt-get >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo apt-get update -q && sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends postgresql postgresql-client ca-certificates procps >/dev/null
    missing_bins=()
    for b in "${need_bins[@]}"; do command -v "$b" >/dev/null 2>&1 || missing_bins+=("$b"); done
    if [ ${#missing_bins[@]} -gt 0 ]; then
      echo "After install attempt, still missing: ${missing_bins[*]}. Please check package sources or install manually: sudo apt-get install -y postgresql postgresql-client" >&2
      exit 4
    fi
  else
    echo "APT not available or sudo requires password; cannot install missing server packages automatically. Missing: ${missing_bins[*]}. Run: sudo apt-get update && sudo apt-get install -y postgresql postgresql-client ca-certificates procps" >&2
    exit 3
  fi
fi
# print resolved paths and versions (non-fatal)
for b in postgres initdb pg_ctl psql pg_isready pg_dump pg_restore; do p=$(command -v "$b" || true); [ -n "$p" ] && printf "%s -> %s\n" "$b" "$p" || printf "%s -> MISSING\n" "$b"; done
postgres --version 2>/dev/null || true
psql --version 2>/dev/null || true
# workspace env template (non-secret)
cat > "$WORKSPACE/postgres_env.template" <<'EOF'
# Template (workspace): non-secret defaults for development
POSTGRES_USER="devuser"
POSTGRES_DB="devdb"
# Do NOT place POSTGRES_PASSWORD here. Supply via env or /run/secrets/pg_password
SECRET_KEY="dev-secret-key"
EOF
chmod 0644 "$WORKSPACE/postgres_env.template"
# System informational template (do not export secrets here). Use .sh.tmpl to avoid accidental sourcing.
SYSTEM_TMPL="/etc/profile.d/postgres_dev.sh.tmpl"
if ! sudo test -f "$SYSTEM_TMPL" >/dev/null 2>&1; then
  sudo tee "$SYSTEM_TMPL" >/dev/null <<'EOF'
# Informational template for operators. Do NOT store secrets here.
# Copy values from this template into a secure location, e.g. /run/secrets/pg_password or process env.
POSTGRES_USER=devuser
POSTGRES_DB=devdb
EOF
  sudo chmod 0644 "$SYSTEM_TMPL"
fi
exit 0

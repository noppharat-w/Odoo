#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  echo "Usage: ./restore.sh backups/odoo-DB-TIMESTAMP.tar.gz [--yes]"
}

[[ $# -ge 1 ]] || {
  usage
  exit 1
}

BACKUP_ARCHIVE="$1"
YES="${2:-}"

[[ -f .env ]] || fail ".env not found"
[[ -f "$BACKUP_ARCHIVE" ]] || fail "Backup archive not found: $BACKUP_ARCHIVE"

set -a
# shellcheck disable=SC1091
source .env
set +a

: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"

[[ "$POSTGRES_DB" =~ ^[A-Za-z0-9_]+$ ]] || fail "POSTGRES_DB may only contain letters, numbers, and underscores"
[[ "$POSTGRES_USER" =~ ^[A-Za-z0-9_]+$ ]] || fail "POSTGRES_USER may only contain letters, numbers, and underscores"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ -f "$BACKUP_ARCHIVE.sha256" ]]; then
  sha256sum -c "$BACKUP_ARCHIVE.sha256"
fi

tar -xzf "$BACKUP_ARCHIVE" -C "$TMP_DIR"

[[ -f "$TMP_DIR/postgres.dump" ]] || fail "postgres.dump missing from backup"
[[ -f "$TMP_DIR/filestore.tar.gz" ]] || fail "filestore.tar.gz missing from backup"

if [[ "$YES" != "--yes" ]]; then
  echo "This will replace database '$POSTGRES_DB' and the Odoo filestore."
  read -r -p "Type RESTORE to continue: " CONFIRM
  [[ "$CONFIRM" == "RESTORE" ]] || fail "Restore cancelled"
fi

docker compose up -d db

echo "Stopping Odoo"
docker compose stop odoo >/dev/null 2>&1 || true

echo "Recreating PostgreSQL database"
docker compose exec -T db psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${POSTGRES_DB}";
CREATE DATABASE "${POSTGRES_DB}" OWNER "${POSTGRES_USER}";
SQL

echo "Restoring PostgreSQL dump"
docker compose exec -T db \
  pg_restore \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    --no-owner \
    --no-acl \
  <"$TMP_DIR/postgres.dump"

echo "Restoring Odoo filestore"
docker compose run --rm -T --no-deps --entrypoint sh odoo \
  -c "rm -rf /var/lib/odoo/filestore && mkdir -p /var/lib/odoo/filestore"

docker compose run --rm -T --no-deps --entrypoint tar odoo \
  -C /var/lib/odoo -xzf - \
  <"$TMP_DIR/filestore.tar.gz"

docker compose run --rm -T --no-deps --entrypoint sh odoo \
  -c "chown -R odoo:odoo /var/lib/odoo/filestore || true"

echo "Starting services"
docker compose up -d

echo "Restore complete"

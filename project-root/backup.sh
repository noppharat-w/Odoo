#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -f .env ]] || fail ".env not found"

set -a
# shellcheck disable=SC1091
source .env
set +a

: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_BASE="$ROOT_DIR/backups"
WORK_DIR="$BACKUP_BASE/.tmp-$TIMESTAMP"
ARCHIVE="$BACKUP_BASE/odoo-${POSTGRES_DB}-${TIMESTAMP}.tar.gz"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR" "$BACKUP_BASE"

docker compose ps -q db >/dev/null || fail "db container is not running"
docker compose ps -q odoo >/dev/null || fail "odoo container is not running"

echo "Creating PostgreSQL backup"
docker compose exec -T db \
  pg_dump \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    --format=custom \
    --no-owner \
    --no-acl \
  >"$WORK_DIR/postgres.dump"

echo "Creating Odoo filestore backup"
docker compose exec -T odoo \
  tar -C /var/lib/odoo -czf - filestore \
  >"$WORK_DIR/filestore.tar.gz"

cat >"$WORK_DIR/manifest.env" <<EOF
BACKUP_CREATED_UTC=$TIMESTAMP
POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
ODOO_VERSION=${ODOO_VERSION:-18.0}
POSTGRES_VERSION=${POSTGRES_VERSION:-18.4}
EOF

echo "Compressing backup"
tar -C "$WORK_DIR" -czf "$ARCHIVE" .
sha256sum "$ARCHIVE" >"$ARCHIVE.sha256"

if [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( RETENTION_DAYS > 0 )); then
  find "$BACKUP_BASE" -maxdepth 1 -type f -name "odoo-${POSTGRES_DB}-*.tar.gz" -mtime +"$RETENTION_DAYS" -delete
  find "$BACKUP_BASE" -maxdepth 1 -type f -name "odoo-${POSTGRES_DB}-*.tar.gz.sha256" -mtime +"$RETENTION_DAYS" -delete
fi

echo "Backup created: $ARCHIVE"
echo "Checksum: $ARCHIVE.sha256"

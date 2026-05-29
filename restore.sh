#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$PROJECT_DIR/docker-compose.yml}"
BACKUP_ROOT="${BACKUP_ROOT:-$PROJECT_DIR/backups}"
DB_SERVICE="${DB_SERVICE:-db}"
ODOO_SERVICE="${ODOO_SERVICE:-odoo}"
RESTORE_GLOBALS="${RESTORE_GLOBALS:-0}"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /absolute/path/to/odoo-backup-YYYYMMDDTHHMMSSZ.tar.gz" >&2
  exit 1
fi

ARCHIVE="$1"
RESTORE_WORKDIR="$BACKUP_ROOT/restore-$(date -u +%Y%m%dT%H%M%SZ)"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 1
  }
}

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

sql_literal() {
  printf "%s" "$1" | sed "s/'/''/g"
}

sql_identifier() {
  printf '"%s"' "$(printf "%s" "$1" | sed 's/"/""/g')"
}

wait_for_db() {
  for _ in $(seq 1 60); do
    if compose exec -T "$DB_SERVICE" pg_isready -U "$POSTGRES_USER" -d postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "PostgreSQL did not become ready in time." >&2
  return 1
}

wait_for_odoo() {
  local url="http://127.0.0.1:${ODOO_HTTP_PORT:-8069}/web/login"
  for _ in $(seq 1 90); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Odoo did not respond at $url in time." >&2
  return 1
}

require_command docker
require_command tar
require_command curl

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Backup archive does not exist: $ARCHIVE" >&2
  exit 1
fi

mkdir -p "$RESTORE_WORKDIR"
tar -C "$RESTORE_WORKDIR" -xzf "$ARCHIVE"
PAYLOAD_DIR="$(find "$RESTORE_WORKDIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

if [[ -z "$PAYLOAD_DIR" || ! -f "$PAYLOAD_DIR/db/manifest.tsv" || ! -f "$PAYLOAD_DIR/source/source.tar.gz" ]]; then
  echo "Archive does not match the expected Odoo backup layout." >&2
  exit 1
fi

echo "Restoring source tree and configuration files"
tar -C "$PROJECT_DIR" -xzf "$PAYLOAD_DIR/source/source.tar.gz"
[[ -f "$PAYLOAD_DIR/config/docker-compose.yml" ]] && cp "$PAYLOAD_DIR/config/docker-compose.yml" "$PROJECT_DIR/docker-compose.yml"
[[ -f "$PAYLOAD_DIR/config/.env" ]] && cp "$PAYLOAD_DIR/config/.env" "$PROJECT_DIR/.env"
[[ -f "$PAYLOAD_DIR/config/env.example" ]] && cp "$PAYLOAD_DIR/config/env.example" "$PROJECT_DIR/env.example"
[[ -f "$PAYLOAD_DIR/config/odoo.conf" ]] && cp "$PAYLOAD_DIR/config/odoo.conf" "$PROJECT_DIR/odoo.conf"
[[ -f "$PAYLOAD_DIR/config/Dockerfile" ]] && cp "$PAYLOAD_DIR/config/Dockerfile" "$PROJECT_DIR/Dockerfile"
[[ -f "$PAYLOAD_DIR/config/docker-dir.tar" ]] && tar -C "$PROJECT_DIR" -xf "$PAYLOAD_DIR/config/docker-dir.tar"
[[ -f "$PAYLOAD_DIR/config/deploy-dir.tar" ]] && tar -C "$PROJECT_DIR" -xf "$PAYLOAD_DIR/config/deploy-dir.tar"

if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_DIR/.env"
  set +a
fi

POSTGRES_USER="${POSTGRES_USER:-odoo}"

echo "Building Odoo image"
compose build "$ODOO_SERVICE"

echo "Stopping application containers before database restore"
compose stop "$ODOO_SERVICE" >/dev/null 2>&1 || true
compose up -d "$DB_SERVICE"
wait_for_db

if [[ "$RESTORE_GLOBALS" == "1" && -f "$PAYLOAD_DIR/db/globals.sql" ]]; then
  echo "Restoring PostgreSQL globals"
  compose exec -T "$DB_SERVICE" psql -U "$POSTGRES_USER" -d postgres < "$PAYLOAD_DIR/db/globals.sql" || true
fi

while IFS=$'\t' read -r db_name dump_file; do
  [[ -z "$db_name" || -z "$dump_file" ]] && continue
  dump_path="$PAYLOAD_DIR/db/$dump_file"
  if [[ ! -f "$dump_path" ]]; then
    echo "Missing dump file for database '$db_name': $dump_path" >&2
    exit 1
  fi

  db_literal="$(sql_literal "$db_name")"
  db_identifier="$(sql_identifier "$db_name")"
  owner_identifier="$(sql_identifier "$POSTGRES_USER")"

  echo "Restoring database: $db_name"
  compose exec -T "$DB_SERVICE" psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db_literal' AND pid <> pg_backend_pid();"
  compose exec -T "$DB_SERVICE" psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS $db_identifier;"
  compose exec -T "$DB_SERVICE" psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE $db_identifier OWNER $owner_identifier;"
  compose exec -T "$DB_SERVICE" pg_restore -U "$POSTGRES_USER" --no-owner --no-acl --dbname="$db_name" < "$dump_path"
done < "$PAYLOAD_DIR/db/manifest.tsv"

echo "Restoring Odoo filestore"
compose run --rm --no-deps -v "$PAYLOAD_DIR/filestore:/restore:ro" --entrypoint sh "$ODOO_SERVICE" -c \
  'rm -rf /var/lib/odoo/filestore && mkdir -p /var/lib/odoo && tar -C /var/lib/odoo -xf /restore/filestore.tar'

echo "Starting full stack"
compose up -d --build
wait_for_db
wait_for_odoo

echo "Validating restored databases"
while IFS=$'\t' read -r db_name _dump_file; do
  [[ -z "$db_name" ]] && continue
  db_exists="$(compose exec -T "$DB_SERVICE" psql -U "$POSTGRES_USER" -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$(sql_literal "$db_name")';")"
  if [[ "$db_exists" != "1" ]]; then
    echo "Database validation failed for: $db_name" >&2
    exit 1
  fi
done < "$PAYLOAD_DIR/db/manifest.tsv"

echo "Restore complete"

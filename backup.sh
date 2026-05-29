#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$PROJECT_DIR/docker-compose.yml}"
BACKUP_ROOT="${BACKUP_ROOT:-$PROJECT_DIR/backups}"
DB_SERVICE="${DB_SERVICE:-db}"
ODOO_SERVICE="${ODOO_SERVICE:-odoo}"
COLD_VOLUME_BACKUP="${COLD_VOLUME_BACKUP:-1}"
KEEP_UNCOMPRESSED="${KEEP_UNCOMPRESSED:-0}"

if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_DIR/.env"
  set +a
fi

POSTGRES_USER="${POSTGRES_USER:-odoo}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
ARCHIVE="$BACKUP_ROOT/odoo-backup-$TIMESTAMP.tar.gz"
STOPPED_FOR_VOLUME_BACKUP=0

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 1
  }
}

restart_stack_if_needed() {
  if [[ "$STOPPED_FOR_VOLUME_BACKUP" == "1" ]]; then
    compose up -d
  fi
}

trap restart_stack_if_needed EXIT

require_command docker
require_command tar

mkdir -p "$BACKUP_DIR"/{config,db,filestore,metadata,source,volumes}

echo "Starting Odoo backup: $TIMESTAMP"
compose up -d

DB_CONTAINER="$(compose ps -q "$DB_SERVICE")"
ODOO_CONTAINER="$(compose ps -q "$ODOO_SERVICE")"

if [[ -z "$DB_CONTAINER" || -z "$ODOO_CONTAINER" ]]; then
  echo "Could not find running containers for services '$DB_SERVICE' and '$ODOO_SERVICE'." >&2
  exit 1
fi

compose config > "$BACKUP_DIR/metadata/docker-compose.rendered.yml"
compose ps > "$BACKUP_DIR/metadata/docker-compose.ps.txt"
docker inspect "$DB_CONTAINER" > "$BACKUP_DIR/metadata/db-container.inspect.json"
docker inspect "$ODOO_CONTAINER" > "$BACKUP_DIR/metadata/odoo-container.inspect.json"
docker inspect "$DB_CONTAINER" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{.Destination}}{{println}}{{end}}{{end}}' > "$BACKUP_DIR/metadata/db-volume-mounts.txt"
docker inspect "$ODOO_CONTAINER" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{.Destination}}{{println}}{{end}}{{end}}' > "$BACKUP_DIR/metadata/odoo-volume-mounts.txt"

cp "$COMPOSE_FILE" "$BACKUP_DIR/config/docker-compose.yml"
[[ -f "$PROJECT_DIR/.env" ]] && cp "$PROJECT_DIR/.env" "$BACKUP_DIR/config/.env"
[[ -f "$PROJECT_DIR/env.example" ]] && cp "$PROJECT_DIR/env.example" "$BACKUP_DIR/config/env.example"
[[ -f "$PROJECT_DIR/odoo.conf" ]] && cp "$PROJECT_DIR/odoo.conf" "$BACKUP_DIR/config/odoo.conf"
[[ -f "$PROJECT_DIR/Dockerfile" ]] && cp "$PROJECT_DIR/Dockerfile" "$BACKUP_DIR/config/Dockerfile"
[[ -d "$PROJECT_DIR/docker" ]] && tar -C "$PROJECT_DIR" -cf "$BACKUP_DIR/config/docker-dir.tar" docker
[[ -d "$PROJECT_DIR/deploy" ]] && tar -C "$PROJECT_DIR" -cf "$BACKUP_DIR/config/deploy-dir.tar" deploy

echo "Exporting PostgreSQL globals"
compose exec -T "$DB_SERVICE" pg_dumpall -U "$POSTGRES_USER" --globals-only > "$BACKUP_DIR/db/globals.sql"

echo "Discovering user databases"
compose exec -T "$DB_SERVICE" psql -U "$POSTGRES_USER" -d postgres -Atc \
  "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres' ORDER BY datname;" \
  > "$BACKUP_DIR/db/databases.txt"

if [[ ! -s "$BACKUP_DIR/db/databases.txt" ]]; then
  echo "No user databases found to back up." >&2
  exit 1
fi

while IFS= read -r db_name; do
  [[ -z "$db_name" ]] && continue
  safe_name="$(printf '%s' "$db_name" | tr -c 'A-Za-z0-9_.-' '_')"
  echo "Exporting database: $db_name"
  compose exec -T "$DB_SERVICE" pg_dump -U "$POSTGRES_USER" --format=custom --no-owner --no-acl --dbname="$db_name" \
    > "$BACKUP_DIR/db/$safe_name.dump"
  printf '%s\t%s.dump\n' "$db_name" "$safe_name" >> "$BACKUP_DIR/db/manifest.tsv"
done < "$BACKUP_DIR/db/databases.txt"

echo "Backing up Odoo filestore"
compose exec -T "$ODOO_SERVICE" sh -c \
  'if [ -d /var/lib/odoo/filestore ]; then tar -C /var/lib/odoo -cf - filestore; else tar -cf - --files-from /dev/null; fi' \
  > "$BACKUP_DIR/filestore/filestore.tar"

echo "Backing up repository source and custom addons"
tar -C "$PROJECT_DIR" \
  --exclude='./.git' \
  --exclude='./.venv' \
  --exclude='./backups' \
  --exclude='./__pycache__' \
  -czf "$BACKUP_DIR/source/source.tar.gz" .

if [[ "$COLD_VOLUME_BACKUP" == "1" ]]; then
  echo "Stopping stack for cold Docker volume archives"
  compose stop
  STOPPED_FOR_VOLUME_BACKUP=1

  db_volume="$(awk '$2 == "/var/lib/postgresql/data" {print $1; exit}' "$BACKUP_DIR/metadata/db-volume-mounts.txt")"
  odoo_volume="$(awk '$2 == "/var/lib/odoo" {print $1; exit}' "$BACKUP_DIR/metadata/odoo-volume-mounts.txt")"

  if [[ -n "${db_volume:-}" ]]; then
    echo "Archiving PostgreSQL Docker volume: $db_volume"
    docker run --rm -v "$db_volume:/volume:ro" -v "$BACKUP_DIR/volumes:/backup" postgres:16-alpine \
      sh -c 'cd /volume && tar -cf /backup/postgres-data-volume.tar .'
  fi

  if [[ -n "${odoo_volume:-}" ]]; then
    echo "Archiving Odoo Docker volume: $odoo_volume"
    docker run --rm -v "$odoo_volume:/volume:ro" -v "$BACKUP_DIR/volumes:/backup" local/odoo-source:19 \
      sh -c 'cd /volume && tar -cf /backup/odoo-data-volume.tar .'
  fi

  echo "Restarting stack"
  compose up -d
  STOPPED_FOR_VOLUME_BACKUP=0
fi

sha256sum "$BACKUP_DIR"/db/*.dump "$BACKUP_DIR/filestore/filestore.tar" "$BACKUP_DIR/source/source.tar.gz" \
  > "$BACKUP_DIR/metadata/checksums.sha256"

echo "Creating compressed archive: $ARCHIVE"
tar -C "$BACKUP_ROOT" -czf "$ARCHIVE" "$TIMESTAMP"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

if [[ "$KEEP_UNCOMPRESSED" != "1" ]]; then
  rm -rf "$BACKUP_DIR"
fi

echo "Backup complete"
echo "$ARCHIVE"

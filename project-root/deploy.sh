#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE="$ROOT_DIR/.env.example"
LOG_FILE="$ROOT_DIR/deploy.log"
RAW_DEPLOY_DOMAIN="${1:-}"
DEPLOY_DOMAIN="$(printf '%s' "$RAW_DEPLOY_DOMAIN" | tr '[:upper:]' '[:lower:]')"

mkdir -p "$ROOT_DIR/backups"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

on_exit() {
  local code="$1"
  if [[ "$code" -eq 0 ]]; then
    log "Completion status: success"
  else
    log "Completion status: failed with exit code $code"
  fi
}
trap 'on_exit $?' EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

usage() {
  cat <<'EOF'
Usage:
  ./deploy.sh <domain>

Example:
  ./deploy.sh hrInventory.company.com
EOF
}

validate_domain() {
  local domain="$1"
  [[ -n "$domain" ]] || {
    usage
    fail "DOMAIN argument is required"
  }
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
    || fail "Invalid domain: $domain"
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64
    printf '\n'
  fi
}

env_get() {
  local key="$1"
  if [[ -f "$ENV_FILE" ]]; then
    grep -E "^${key}=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- || true
  fi
}

env_set() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "$ENV_FILE" ]]; then
    awk -v key="$key" -v value="$value" '
      BEGIN { found = 0 }
      $0 ~ "^" key "=" {
        print key "=" value
        found = 1
        next
      }
      { print }
      END {
        if (found == 0) {
          print key "=" value
        }
      }
    ' "$ENV_FILE" >"$tmp"
  else
    printf '%s=%s\n' "$key" "$value" >"$tmp"
  fi

  mv "$tmp" "$ENV_FILE"
}

prepare_env() {
  [[ -f "$ENV_FILE" ]] || {
    [[ -f "$ENV_EXAMPLE" ]] || fail ".env.example not found"
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  }

  env_set DOMAIN "$DEPLOY_DOMAIN"

  local postgres_password
  postgres_password="$(env_get POSTGRES_PASSWORD)"
  if [[ -z "$postgres_password" || "$postgres_password" == "replace-with-a-long-random-postgres-password" ]]; then
    env_set POSTGRES_PASSWORD "$(generate_secret)"
  fi

  local master_password
  master_password="$(env_get ODOO_MASTER_PASSWORD)"
  if [[ -z "$master_password" || "$master_password" == "replace-with-a-long-random-odoo-master-password" ]]; then
    env_set ODOO_MASTER_PASSWORD "$(generate_secret)"
  fi

  local letsencrypt_email
  letsencrypt_email="$(env_get LETSENCRYPT_EMAIL)"
  if [[ -z "$letsencrypt_email" || "$letsencrypt_email" == "admin@example.com" ]]; then
    env_set LETSENCRYPT_EMAIL "admin@${DEPLOY_DOMAIN}"
  fi

  local enable_ssl
  enable_ssl="$(env_get ENABLE_SSL)"
  [[ "$enable_ssl" =~ ^(true|false)$ ]] || enable_ssl="true"
  env_set ENABLE_SSL "$enable_ssl"

  local init_odoo_db
  init_odoo_db="$(env_get INIT_ODOO_DB)"
  [[ "$init_odoo_db" =~ ^(true|false)$ ]] || init_odoo_db="true"
  env_set INIT_ODOO_DB "$init_odoo_db"

  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-odoo18_prod}"
  export POSTGRES_DB="${POSTGRES_DB:-odoo_prod}"
  export POSTGRES_USER="${POSTGRES_USER:-odoo}"
  export CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-128m}"
  export ENABLE_SSL="${ENABLE_SSL:-true}"
  export LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-false}"
  export INIT_ODOO_DB="${INIT_ODOO_DB:-true}"

  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
  : "${ODOO_MASTER_PASSWORD:?ODOO_MASTER_PASSWORD is required}"
  : "${ODOO_DB_FILTER:?ODOO_DB_FILTER is required}"
  : "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL is required}"

  [[ "$POSTGRES_DB" =~ ^[A-Za-z0-9_]+$ ]] || fail "POSTGRES_DB may only contain letters, numbers, and underscores"
  [[ "$POSTGRES_USER" =~ ^[A-Za-z0-9_]+$ ]] || fail "POSTGRES_USER may only contain letters, numbers, and underscores"
}

render_nginx_template() {
  local template="$1"
  local output="$2"

  sed \
    -e "s|\${DOMAIN}|${DOMAIN}|g" \
    -e "s|\${CLIENT_MAX_BODY_SIZE}|${CLIENT_MAX_BODY_SIZE}|g" \
    "$template" >"$output"
}

resolve_domain_ips() {
  local domain="$1"
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$domain" | awk '{print $1}' | sort -u
  elif command -v dig >/dev/null 2>&1; then
    dig +short A "$domain" | grep -E '^[0-9.]+$' | sort -u
  elif command -v host >/dev/null 2>&1; then
    host "$domain" | awk '/has address/ {print $4}' | sort -u
  else
    fail "getent, dig, or host is required for DNS validation"
  fi
}

get_vm_public_ip() {
  local ip
  ip="$(curl -fsS --connect-timeout 2 --max-time 4 -H Metadata:true --noproxy '*' \
    'http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text' \
    2>/dev/null || true)"

  if [[ -z "$ip" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip="$(curl -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  fi

  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Unable to determine this VM public IP"
  printf '%s\n' "$ip"
}

validate_dns_points_to_vm() {
  log "DNS validation: resolving ${DOMAIN}"

  local dns_ips
  dns_ips="$(resolve_domain_ips "$DOMAIN" || true)"
  [[ -n "$dns_ips" ]] || fail "DNS validation failed: ${DOMAIN} has no A record"

  local vm_ip
  vm_ip="$(get_vm_public_ip)"

  log "DNS A record IP(s): $(printf '%s' "$dns_ips" | paste -sd ',' -)"
  log "Azure VM public IP: ${vm_ip}"

  if ! printf '%s\n' "$dns_ips" | grep -Fxq "$vm_ip"; then
    cat >&2 <<EOF

DNS validation failed.

Domain: ${DOMAIN}
DNS A record IP(s):
$(printf '  - %s\n' $dns_ips)

Current Azure VM public IP:
  - ${vm_ip}

Fix the DNS A record so ${DOMAIN} points to ${vm_ip}, wait for propagation, then run:
  ./deploy.sh ${DOMAIN}

EOF
    fail "DNS A record does not match this Azure VM public IP"
  fi
}

wait_for_health() {
  local service="$1"
  local timeout="${2:-300}"
  local start
  start="$(date +%s)"
  log "Health check: waiting for ${service}"

  while true; do
    local cid
    cid="$(docker compose ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      local status
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
      if [[ "$status" == "healthy" ]]; then
        log "Health check passed: ${service}"
        return 0
      fi
      if [[ "$status" == "running" && "$service" == "certbot" ]]; then
        log "Health check passed: ${service} is running"
        return 0
      fi
      if [[ "$status" == "unhealthy" || "$status" == "exited" || "$status" == "dead" ]]; then
        docker compose logs --tail=100 "$service" >&2 || true
        fail "${service} is ${status}"
      fi
    fi

    if (( "$(date +%s)" - start > timeout )); then
      docker compose logs --tail=160 "$service" >&2 || true
      fail "Timed out waiting for ${service} health"
    fi

    sleep 5
  done
}

initialize_odoo_database() {
  [[ "${INIT_ODOO_DB}" == "true" ]] || {
    log "Odoo database initialization skipped"
    return 0
  }

  local database_exists
  database_exists="$(docker compose exec -T db psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}';" | tr -d '[:space:]')"
  if [[ "$database_exists" != "1" ]]; then
    log "Creating PostgreSQL database ${POSTGRES_DB}"
    docker compose exec -T db psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 \
      -c "CREATE DATABASE \"${POSTGRES_DB}\" OWNER \"${POSTGRES_USER}\";"
  fi

  local initialized
  initialized="$(docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT to_regclass('public.ir_module_module') IS NOT NULL;" | tr -d '[:space:]')"

  if [[ "$initialized" == "t" ]]; then
    log "Odoo database already initialized"
    return 0
  fi

  log "Initializing Odoo database ${POSTGRES_DB}"
  docker compose run --rm --no-deps odoo \
    odoo \
      -d "$POSTGRES_DB" \
      --db_host=db \
      --db_port=5432 \
      --db_user="$POSTGRES_USER" \
      --db_password="$POSTGRES_PASSWORD" \
      --admin-passwd="$ODOO_MASTER_PASSWORD" \
      --without-demo=all \
      -i base \
      --stop-after-init
}

cert_exists() {
  docker compose run --rm --no-deps --entrypoint sh certbot \
    -c "[ -s /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ] && [ -s /etc/letsencrypt/live/${DOMAIN}/privkey.pem ]" \
    >/dev/null 2>&1
}

configure_ssl() {
  [[ "$ENABLE_SSL" == "true" ]] || {
    log "SSL disabled by ENABLE_SSL=false"
    return 0
  }

  validate_dns_points_to_vm

  log "SSL generation: preparing HTTP challenge endpoint"
  render_nginx_template nginx/default.conf.template nginx/default.conf
  docker compose up -d nginx
  wait_for_health nginx 180

  if cert_exists; then
    log "SSL generation: existing certificate found for ${DOMAIN}"
  else
    local staging_args=()
    if [[ "$LETSENCRYPT_STAGING" == "true" ]]; then
      staging_args+=(--staging)
    fi

    log "SSL generation: requesting Let's Encrypt certificate for ${DOMAIN}"
    docker compose run --rm --no-deps certbot \
      certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        --email "$LETSENCRYPT_EMAIL" \
        --agree-tos \
        --no-eff-email \
        --rsa-key-size 4096 \
        --keep-until-expiring \
        --non-interactive \
        "${staging_args[@]}" \
        -d "$DOMAIN"
  fi

  log "SSL generation: enabling HTTPS nginx configuration"
  render_nginx_template nginx/ssl.conf.template nginx/default.conf
  docker compose up -d nginx certbot
  docker compose exec -T nginx nginx -s reload
  wait_for_health nginx 180
  wait_for_health certbot 60
}

verify_https() {
  [[ "$ENABLE_SSL" == "true" ]] || return 0

  log "SSL validation: verifying https://${DOMAIN}"

  local status=""
  local attempt
  for attempt in $(seq 1 12); do
    status="$(curl -sS -L --connect-timeout 10 --max-time 30 -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" || true)"
    if [[ "$status" == "200" ]]; then
      log "SSL validation passed: https://${DOMAIN} returned HTTP 200"
      return 0
    fi
    log "SSL validation attempt ${attempt}/12 returned HTTP ${status:-000}"
    sleep 5
  done

  cat >&2 <<EOF

HTTPS validation failed for https://${DOMAIN}

Expected: HTTP 200
Actual:   HTTP ${status:-000}

Troubleshooting:
  - Confirm DNS A record points to this VM public IP.
  - Confirm Azure NSG allows inbound TCP 80 and 443.
  - Confirm Ubuntu firewall allows 80/tcp and 443/tcp.
  - Check nginx logs: docker compose logs --tail=200 nginx
  - Check certbot logs: docker compose logs --tail=200 certbot
  - Check Odoo logs: docker compose logs --tail=200 odoo

EOF
  docker compose ps || true
  docker compose logs --tail=80 nginx || true
  fail "SSL validation failed"
}

configure_backup_schedule() {
  if ! command -v crontab >/dev/null 2>&1; then
    log "Backup scheduling: crontab command not available; skipping host cron setup"
    return 0
  fi

  local marker="# odoo18-prod-backup:${ROOT_DIR}"
  local job="15 2 * * * cd ${ROOT_DIR} && ./backup.sh >> ${ROOT_DIR}/backups/backup.log 2>&1 ${marker}"
  local current
  current="$(crontab -l 2>/dev/null | grep -vF "$marker" || true)"
  printf '%s\n%s\n' "$current" "$job" | sed '/^$/N;/^\n$/D' | crontab -
  log "Backup scheduling: daily backup cron installed at 02:15 UTC"
}

print_summary() {
  cat <<EOF

==================================================
ODOO DEPLOYMENT COMPLETED
=========================

Domain:
https://${DOMAIN}

Containers:
✓ nginx
✓ odoo
✓ postgres
✓ certbot

Database:
${POSTGRES_DB}

Backup Location:
${ROOT_DIR}/backups

Log File:
deploy.log
EOF
}

main() {
  validate_domain "$DEPLOY_DOMAIN"
  log "=================================================="
  log "Starting Odoo deployment for ${DEPLOY_DOMAIN}"

  require_command docker
  require_command curl
  require_command awk
  require_command sed

  prepare_env

  mkdir -p nginx odoo/addons odoo/config backups
  chmod +x deploy.sh backup.sh restore.sh scripts/*.sh

  log "Docker startup: validating compose configuration"
  docker compose config -q

  log "Docker startup: starting PostgreSQL"
  docker compose up -d db
  wait_for_health db 240

  initialize_odoo_database

  log "Docker startup: starting Odoo"
  render_nginx_template nginx/default.conf.template nginx/default.conf
  docker compose up -d odoo
  wait_for_health odoo 420

  configure_ssl

  log "Docker startup: ensuring full stack is running"
  docker compose up -d
  wait_for_health db 180
  wait_for_health odoo 300
  wait_for_health nginx 180
  wait_for_health certbot 60

  verify_https
  configure_backup_schedule

  log "Deployment completed successfully"
  print_summary
}

main "$@"

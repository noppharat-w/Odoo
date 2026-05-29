#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env"
DOMAIN_ARG="${1:-}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

env_set() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"

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

  mv "$tmp" "$ENV_FILE"
}

render_nginx_template() {
  local template="$1"
  local output="$2"

  sed \
    -e "s|\${DOMAIN}|${DOMAIN}|g" \
    -e "s|\${CLIENT_MAX_BODY_SIZE}|${CLIENT_MAX_BODY_SIZE}|g" \
    "$template" >"$output"
}

cert_exists() {
  docker compose run --rm --no-deps --entrypoint sh certbot \
    -c "[ -s /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ] && [ -s /etc/letsencrypt/live/${DOMAIN}/privkey.pem ]" \
    >/dev/null 2>&1
}

[[ -f "$ENV_FILE" ]] || {
  [[ -f .env.example ]] || fail ".env not found and .env.example is missing"
  cp .env.example "$ENV_FILE"
}

if [[ -n "$DOMAIN_ARG" ]]; then
  [[ "$DOMAIN_ARG" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
    || fail "Invalid domain: $DOMAIN_ARG"
  env_set DOMAIN "$(printf '%s' "$DOMAIN_ARG" | tr '[:upper:]' '[:lower:]')"
fi

set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

: "${DOMAIN:?DOMAIN is required. Use ./scripts/init-letsencrypt.sh example.com or ./deploy.sh example.com}"

CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-128m}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-false}"

if [[ -z "${LETSENCRYPT_EMAIL:-}" || "$LETSENCRYPT_EMAIL" == "admin@example.com" ]]; then
  LETSENCRYPT_EMAIL="admin@${DOMAIN}"
  env_set LETSENCRYPT_EMAIL "$LETSENCRYPT_EMAIL"
fi

render_nginx_template nginx/default.conf.template nginx/default.conf
docker compose up -d nginx

if cert_exists; then
  echo "Existing certificate found for ${DOMAIN}"
else
  staging_args=()
  if [[ "$LETSENCRYPT_STAGING" == "true" ]]; then
    staging_args+=(--staging)
  fi

  echo "Requesting Let's Encrypt certificate for ${DOMAIN}"
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

render_nginx_template nginx/ssl.conf.template nginx/default.conf
docker compose up -d nginx certbot
docker compose exec -T nginx nginx -s reload

echo "Let's Encrypt SSL is configured for ${DOMAIN}"

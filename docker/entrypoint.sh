#!/usr/bin/env bash
set -euo pipefail

export DB_HOST="${DB_HOST:-db}"
export DB_PORT="${DB_PORT:-5432}"
export DB_USER="${DB_USER:-odoo}"
export DB_PASSWORD="${DB_PASSWORD:-odoo}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
export ADDONS_PATH="${ADDONS_PATH:-/opt/odoo/addons,/opt/odoo/odoo/addons}"
export HTTP_PORT="${HTTP_PORT:-8069}"
export PROXY_MODE="${PROXY_MODE:-False}"
export WORKERS="${WORKERS:-0}"
export MAX_CRON_THREADS="${MAX_CRON_THREADS:-1}"

envsubst < /etc/odoo/odoo.conf.template > /etc/odoo/odoo.conf

python - <<'PY'
import os
import sys
import time

import psycopg2

host = os.environ["DB_HOST"]
port = os.environ["DB_PORT"]
user = os.environ["DB_USER"]
password = os.environ["DB_PASSWORD"]

for attempt in range(60):
    try:
        conn = psycopg2.connect(
            host=host,
            port=port,
            user=user,
            password=password,
            dbname="postgres",
            connect_timeout=3,
        )
        conn.close()
        break
    except psycopg2.OperationalError as exc:
        if attempt == 59:
            print(f"PostgreSQL is not ready: {exc}", file=sys.stderr)
            raise
        time.sleep(2)
PY

exec python /opt/odoo/odoo-bin -c /etc/odoo/odoo.conf "$@"

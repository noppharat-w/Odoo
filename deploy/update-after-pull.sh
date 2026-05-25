#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ODOO_SERVICE="${ODOO_SERVICE:-odoo}"
ODOO_CONFIG_FILE="${ODOO_CONFIG_FILE:-/etc/odoo/odoo.conf}"
ODOO_USER="${ODOO_USER:-odoo}"
ODOO_GROUP="${ODOO_GROUP:-odoo}"
UPDATE_DB="${UPDATE_DB:-}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo bash deploy/update-after-pull.sh"
    exit 1
fi

cd "${REPO_DIR}"

echo "Installing or updating Python dependencies..."
"${REPO_DIR}/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
"${REPO_DIR}/.venv/bin/pip" install -r "${REPO_DIR}/requirements.txt"

chown -R "${ODOO_USER}:${ODOO_GROUP}" "${REPO_DIR}/.venv"

if [[ -n "${UPDATE_DB}" ]]; then
    echo "Updating Odoo modules in database ${UPDATE_DB}..."
    systemctl stop "${ODOO_SERVICE}"
    runuser -u "${ODOO_USER}" -- "${REPO_DIR}/.venv/bin/python" "${REPO_DIR}/odoo-bin" \
        -c "${ODOO_CONFIG_FILE}" \
        -d "${UPDATE_DB}" \
        -u all \
        --stop-after-init
else
    echo "UPDATE_DB is empty; skipping module update."
fi

echo "Restarting ${ODOO_SERVICE}..."
systemctl restart "${ODOO_SERVICE}"
systemctl --no-pager --full status "${ODOO_SERVICE}" || true

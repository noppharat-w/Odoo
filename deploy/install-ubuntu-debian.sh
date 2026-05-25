#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this installer as root: sudo bash deploy/install-ubuntu-debian.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ODOO_USER="${ODOO_USER:-odoo}"
ODOO_GROUP="${ODOO_GROUP:-odoo}"
ODOO_HOME="${ODOO_HOME:-/opt/odoo}"
ODOO_CONFIG_DIR="${ODOO_CONFIG_DIR:-/etc/odoo}"
ODOO_CONFIG_FILE="${ODOO_CONFIG_FILE:-${ODOO_CONFIG_DIR}/odoo.conf}"
ODOO_DATA_DIR="${ODOO_DATA_DIR:-/var/lib/odoo}"
ODOO_LOG_DIR="${ODOO_LOG_DIR:-/var/log/odoo}"
ODOO_SERVICE="${ODOO_SERVICE:-odoo}"
ODOO_HTTP_PORT="${ODOO_HTTP_PORT:-8069}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -hex 24)}"

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This installer supports Debian/Ubuntu servers with apt-get."
    exit 1
fi

echo "Installing system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    fontconfig \
    fonts-dejavu-core \
    git \
    gettext \
    libevent-dev \
    libffi-dev \
    libfreetype6-dev \
    libfribidi-dev \
    libharfbuzz-dev \
    libjpeg-dev \
    libldap2-dev \
    libmagic1 \
    libopenjp2-7-dev \
    libpq-dev \
    libsasl2-dev \
    libssl-dev \
    libtiff-dev \
    libwebp-dev \
    libxcb1-dev \
    libxml2-dev \
    libxslt1-dev \
    node-less \
    nodejs \
    npm \
    openssl \
    postgresql \
    postgresql-client \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    zlib1g-dev

if apt-cache show wkhtmltopdf >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wkhtmltopdf
else
    echo "wkhtmltopdf is not available from this apt repository. PDF reports may need a manual wkhtmltopdf install."
fi

if ! command -v rtlcss >/dev/null 2>&1; then
    npm install -g rtlcss
fi

echo "Creating Odoo user and directories..."
if ! getent group "${ODOO_GROUP}" >/dev/null; then
    groupadd --system "${ODOO_GROUP}"
fi
if ! id "${ODOO_USER}" >/dev/null 2>&1; then
    useradd --system --home "${ODOO_HOME}" --gid "${ODOO_GROUP}" --shell /bin/bash "${ODOO_USER}"
fi
if ! id -nG "${ODOO_USER}" | tr ' ' '\n' | grep -qx "${ODOO_GROUP}"; then
    usermod -a -G "${ODOO_GROUP}" "${ODOO_USER}"
fi

mkdir -p "${ODOO_HOME}" "${ODOO_CONFIG_DIR}" "${ODOO_DATA_DIR}" "${ODOO_LOG_DIR}"
chmod 755 "${ODOO_HOME}"
chown -R "${ODOO_USER}:${ODOO_GROUP}" "${ODOO_DATA_DIR}" "${ODOO_LOG_DIR}"
chown "root:${ODOO_GROUP}" "${ODOO_CONFIG_DIR}"
chmod 750 "${ODOO_CONFIG_DIR}"

if ! runuser -u "${ODOO_USER}" -- test -r "${REPO_DIR}/odoo-bin"; then
    echo "The ${ODOO_USER} user cannot read ${REPO_DIR}/odoo-bin."
    echo "Move the repository to a readable path such as /opt/odoo/odoo, or fix directory permissions."
    exit 1
fi

echo "Ensuring PostgreSQL role exists..."
systemctl enable --now postgresql
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${ODOO_USER}'" | grep -q 1; then
    runuser -u postgres -- createuser --createdb "${ODOO_USER}"
fi

echo "Preparing Python virtual environment..."
python3 -m venv "${REPO_DIR}/.venv"
"${REPO_DIR}/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
"${REPO_DIR}/.venv/bin/pip" install -r "${REPO_DIR}/requirements.txt"
chown -R "${ODOO_USER}:${ODOO_GROUP}" "${REPO_DIR}/.venv"

if [[ ! -f "${ODOO_CONFIG_FILE}" ]]; then
    echo "Writing ${ODOO_CONFIG_FILE}..."
    cat > "${ODOO_CONFIG_FILE}" <<EOF_CONF
[options]
admin_passwd = ${ADMIN_PASSWORD}
addons_path = ${REPO_DIR}/addons,${REPO_DIR}/odoo/addons
data_dir = ${ODOO_DATA_DIR}
db_host = False
db_port = False
db_user = ${ODOO_USER}
db_password = False
http_interface = 0.0.0.0
http_port = ${ODOO_HTTP_PORT}
logfile = ${ODOO_LOG_DIR}/odoo.log
proxy_mode = True
workers = 2
max_cron_threads = 1
limit_time_cpu = 600
limit_time_real = 1200
EOF_CONF
else
    echo "${ODOO_CONFIG_FILE} already exists; leaving it unchanged."
fi
chown "${ODOO_USER}:${ODOO_GROUP}" "${ODOO_CONFIG_FILE}"
chmod 640 "${ODOO_CONFIG_FILE}"

echo "Installing systemd service..."
cat > "/etc/systemd/system/${ODOO_SERVICE}.service" <<EOF_SERVICE
[Unit]
Description=Odoo Server
Documentation=https://www.odoo.com/documentation
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=${ODOO_USER}
Group=${ODOO_GROUP}
WorkingDirectory=${REPO_DIR}
ExecStart=${REPO_DIR}/.venv/bin/python ${REPO_DIR}/odoo-bin -c ${ODOO_CONFIG_FILE}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable --now "${ODOO_SERVICE}"

echo "Odoo service is installed."
echo "Config: ${ODOO_CONFIG_FILE}"
echo "Service: systemctl status ${ODOO_SERVICE}"
echo "URL: http://SERVER_IP:${ODOO_HTTP_PORT}"
echo "Master password: ${ADMIN_PASSWORD}"

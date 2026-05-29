# Odoo 18 Community Docker Deployment

Production Docker Compose deployment for Odoo 18 Community on Ubuntu 24.04 / Azure VM.

The deployment includes:

- Odoo 18 Community
- PostgreSQL
- Nginx reverse proxy
- Let's Encrypt SSL with automatic renewal
- Docker health checks
- Persistent PostgreSQL, Odoo filestore, custom addons, and SSL certificate storage
- Automated timestamped backup and restore scripts
- Idempotent one-command deployment
- Daily backup cron scheduling from `deploy.sh`

## First-Time Installation

```bash
git clone <repo>
cd <repo>
./deploy.sh hrInventory.company.com
```

`deploy.sh` creates `.env` automatically, sets `DOMAIN`, generates missing production secrets, starts Docker Compose, requests SSL, validates HTTPS, and writes `deploy.log`.

## DNS Setup

Create a DNS A record that points the deployment domain to the Azure VM public IP before running `deploy.sh`.

Example:

```text
Type: A
Name: hrInventory
Value: 20.50.10.25
TTL: 300
```

Verify DNS:

```bash
dig +short hrInventory.company.com
```

The deployment stops before SSL creation if the domain A record does not match the current Azure VM public IP.

## Azure VM Firewall Rules

Azure Network Security Group inbound rules:

```text
Priority  Name   Port  Protocol  Source   Destination  Action
1000      SSH    22    TCP       Your IP  Any          Allow
1010      HTTP   80    TCP       Any      Any          Allow
1020      HTTPS  443   TCP       Any      Any          Allow
```

Ubuntu firewall:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

## Docker Installation On Ubuntu 24.04

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
newgrp docker
docker version
docker compose version
```

## Deployment Command

```bash
./deploy.sh hrInventory.company.com
```

Successful output:

```text
==================================================
ODOO DEPLOYMENT COMPLETED
=========================

Domain:
https://hrinventory.company.com

Containers:
✓ nginx
✓ odoo
✓ postgres
✓ certbot

Database:
odoo_prod

Backup Location:
/path/to/project/backups

Log File:
deploy.log
```

The command is safe to run multiple times for the same domain.

## What Deploy Does

- Validates the domain argument
- Creates `.env` from `.env.example` when needed
- Updates `DOMAIN` in `.env`
- Generates missing PostgreSQL and Odoo secrets
- Renders `nginx/default.conf`
- Starts PostgreSQL and waits for health
- Initializes the Odoo database when needed
- Starts Odoo and waits for health
- Validates DNS against the Azure VM public IP
- Requests or reuses a Let's Encrypt certificate
- Enables HTTPS redirect
- Reloads Nginx
- Verifies `https://DOMAIN` returns HTTP 200
- Installs an idempotent daily backup cron entry
- Logs all deployment actions to `deploy.log`

## Logs

Deployment log:

```bash
tail -f deploy.log
```

Container logs:

```bash
docker compose logs -f --tail=200 nginx
docker compose logs -f --tail=200 odoo
docker compose logs -f --tail=200 db
docker compose logs -f --tail=200 certbot
```

## SSL

Let's Encrypt certificates are stored in the persistent `letsencrypt` Docker volume. ACME challenge files are stored in the persistent `certbot_www` Docker volume.

Certbot renewal runs every 12 hours. Nginx reloads periodically and also reloads during deployment after HTTPS configuration is rendered.

## Backups

Create a backup manually:

```bash
./backup.sh
```

Backup output:

```text
backups/odoo-odoo_prod-YYYYMMDDTHHMMSSZ.tar.gz
backups/odoo-odoo_prod-YYYYMMDDTHHMMSSZ.tar.gz.sha256
```

The backup contains:

- PostgreSQL custom-format dump
- Odoo filestore archive
- Backup manifest

`deploy.sh` installs a daily backup cron entry at `02:15 UTC`:

```cron
15 2 * * * cd <project> && ./backup.sh >> <project>/backups/backup.log 2>&1
```

## Restore

Interactive restore:

```bash
./restore.sh backups/odoo-odoo_prod-YYYYMMDDTHHMMSSZ.tar.gz
```

Non-interactive restore:

```bash
./restore.sh backups/odoo-odoo_prod-YYYYMMDDTHHMMSSZ.tar.gz --yes
```

The restore script validates the backup, restores PostgreSQL, replaces the Odoo filestore, and restarts the stack.

## Custom Addons

Place custom addons in:

```text
odoo/addons/
```

Restart Odoo:

```bash
docker compose restart odoo
```

## Upgrade Procedure

Create a backup first:

```bash
./backup.sh
```

Pull and restart updated images:

```bash
docker compose pull
docker compose up -d
```

Run Odoo module updates after image upgrades within the same Odoo major version:

```bash
set -a
source .env
set +a

docker compose run --rm odoo \
  odoo \
    -d "$POSTGRES_DB" \
    --db_host=db \
    --db_port=5432 \
    --db_user="$POSTGRES_USER" \
    --db_password="$POSTGRES_PASSWORD" \
    -u all \
    --stop-after-init

docker compose restart odoo
```

Do not upgrade to a new Odoo major version by only changing the image tag. Major Odoo upgrades require database migration and custom module compatibility review.

PostgreSQL major upgrades require a planned dump-and-restore or `pg_upgrade` process. Do not point a new PostgreSQL major version at an existing data volume.

## Operations

Status:

```bash
docker compose ps
```

Restart:

```bash
docker compose restart
```

Stop:

```bash
docker compose down
```

Stop and remove persistent data:

```bash
docker compose down -v
```

## Security Notes

- PostgreSQL is not exposed publicly.
- Odoo is reachable only through Nginx.
- HTTP redirects to HTTPS after certificate issuance.
- Odoo database listing is disabled.
- Odoo runs behind proxy mode.
- Containers use `restart: always`.
- Containers use Docker health checks.
- Containers use `no-new-privileges`.
- Nginx uses security headers and read-only filesystem mode.
- Docker logs are rotated.
- Secrets are stored in `.env`; protect this file with normal server file permissions.
- Restrict SSH to trusted IP addresses in Azure.
- Keep Ubuntu, Docker, Odoo, PostgreSQL, Nginx, and Certbot images patched.

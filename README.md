# Odoo Docker Deployment

Deploy Odoo ด้วย Docker Compose และเปิดใช้งานผ่าน HTTPS บนพอร์ต `8069`

URL หลัง deploy:

```text
https://10.110.23.90:8069/
```

## Deploy บน Server

รันแค่ 3 คำสั่งนี้:

```bash
git pull
chmod +x deploy/generate-self-signed-cert.sh
./deploy/generate-self-signed-cert.sh 10.110.23.90
docker compose build --no-cache --progress=plain odoo
docker compose up -d --force-recreate
```

ตรวจสอบสถานะ:

```bash
docker compose ps
```

ดู log:

```bash
docker compose logs -f odoo
docker compose logs -f https
```

ทดสอบ HTTPS:

```bash
curl -vk https://10.110.23.90:8069/web/login
```

## HTTPS Port 8069

Stack นี้ใช้ `caddy` เป็น HTTPS reverse proxy:

- Host port `8069` เปิดเป็น HTTPS
- Odoo container รัน HTTP ภายใน Docker network ที่พอร์ต `8069`
- Odoo ไม่ถูก publish ออก host โดยตรง
- `proxy_mode` เปิดใช้งานเป็นค่า default
- Certificate ใช้ไฟล์จาก `deploy/certs/fullchain.pem` และ `deploy/certs/privkey.pem`

ถ้ายังไม่มี certificate ให้สร้าง self-signed certificate ที่มี SAN เป็น IP server:

```bash
./deploy/generate-self-signed-cert.sh 10.110.23.90
```

ถ้าเข้าเว็บครั้งแรกแล้ว browser แจ้งเตือน certificate ให้กดยอมรับ certificate ได้ เพราะ certificate เป็น self-signed สำหรับ internal testing

## Firewall

เปิดพอร์ต 8069 บน server:

```bash
sudo ufw allow 8069/tcp
sudo ufw status
```

ถ้าเป็น Azure VM ให้เปิด inbound rule ที่ Network Security Group:

```text
Port: 8069
Protocol: TCP
Source: IP ของผู้ใช้งาน หรือ Any ถ้าจำเป็น
Action: Allow
```

## Environment

ถ้าต้องการ override ค่า default ให้สร้าง `.env` จาก `env.example`:

```bash
cp env.example .env
```

ค่าที่ใช้บ่อย:

```env
POSTGRES_USER=odoo
POSTGRES_PASSWORD=odoo
ODOO_ADMIN_PASSWORD=admin
ODOO_HTTPS_PORT=8069
ODOO_PROXY_MODE=True
ODOO_WORKERS=0
ODOO_MAX_CRON_THREADS=1
```

หลังแก้ `.env` ให้รัน:

```bash
docker compose up -d
```

## Database Commands

ดูรายชื่อ database:

```bash
docker compose exec db psql -U odoo -d postgres -c "\l"
```

ตัวอย่าง update module:

```bash
docker compose stop odoo
docker compose run --rm odoo -d KCG_ODOO -u hr_admin_role --stop-after-init
docker compose up -d
```

## Backup และ Restore

Backup:

```bash
./backup.sh
```

Restore:

```bash
./restore.sh /absolute/path/to/odoo-backup-YYYYMMDDTHHMMSSZ.tar.gz
```

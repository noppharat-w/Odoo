# Run Odoo ด้วย Docker Compose

ใช้ไฟล์ชุดนี้เมื่อ server มี Docker และ Docker Compose แล้ว ต้องการ `git pull` แล้วสั่งรัน Odoo ได้ทันที

## ติดตั้งครั้งแรก

```bash
git clone <YOUR_GIT_URL> /opt/odoo/odoo
cd /opt/odoo/odoo
cp env.example .env
docker compose up -d --build
```

เปิดใช้งาน:

```text
http://SERVER_IP:8069
```

ค่าเริ่มต้นใน `env.example`:

- PostgreSQL user/password: `odoo` / `odoo`
- Odoo master password: `admin`
- Port: `8069`

ควรแก้ `.env` บน server ก่อนใช้งานจริง โดยเฉพาะ `POSTGRES_PASSWORD` และ `ODOO_ADMIN_PASSWORD`

## หลังจาก pull git

```bash
cd /opt/odoo/odoo
git pull
docker compose up -d --build
```

ถ้าเปลี่ยนเฉพาะ custom addon หรือ source code ปกติ container ใช้ bind mount จาก repo อยู่แล้ว แต่ใช้ `--build` ไว้จะครอบคลุมกรณี `requirements.txt` หรือ Dockerfile เปลี่ยนด้วย

## คำสั่งที่ใช้บ่อย

```bash
docker compose ps
docker compose logs -f odoo
docker compose restart odoo
docker compose down
```

ลบข้อมูลทั้งหมดรวม database และ filestore:

```bash
docker compose down -v
```

## Update module ใน database

แทน `your_database_name` ด้วยชื่อ database จริง:

```bash
docker compose stop odoo
docker compose run --rm odoo -d your_database_name -u all --stop-after-init
docker compose up -d
```

## Reverse proxy

ถ้าใช้ Nginx/Traefik หน้า container ให้ตั้งใน `.env`:

```env
ODOO_PROXY_MODE=True
```

จากนั้น restart:

```bash
docker compose up -d
```

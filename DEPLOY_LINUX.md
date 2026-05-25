# Deploy Odoo บน Linux Server

คู่มือนี้ทำให้ server clone หรือ pull repo นี้แล้วรัน Odoo เป็น `systemd` service ได้ทันที เหมาะกับ Ubuntu 24.04 หรือ Debian 12 ขึ้นไป

## ติดตั้งครั้งแรก

บน server ให้ clone repo ไปไว้ที่ `/opt/odoo/odoo`:

```bash
sudo mkdir -p /opt/odoo
sudo chown "$USER:$USER" /opt/odoo
git clone <YOUR_GIT_URL> /opt/odoo/odoo
cd /opt/odoo/odoo
sudo bash deploy/install-ubuntu-debian.sh
```

หลังติดตั้งเปิดใช้งานได้ที่:

```text
http://SERVER_IP:8069
```

คำสั่ง installer จะสร้าง:

- Linux user: `odoo`
- PostgreSQL role: `odoo` พร้อมสิทธิ์สร้าง database
- Python venv: `/opt/odoo/odoo/.venv`
- Config: `/etc/odoo/odoo.conf`
- Data dir: `/var/lib/odoo`
- Log: `/var/log/odoo/odoo.log`
- Service: `odoo.service`

## หลังจาก pull git

```bash
cd /opt/odoo/odoo
git pull
sudo bash deploy/update-after-pull.sh
```

ถ้าต้องการ update module ทั้งหมดใน database หลัง pull:

```bash
cd /opt/odoo/odoo
git pull
sudo UPDATE_DB=your_database_name bash deploy/update-after-pull.sh
```

## คำสั่งใช้งานประจำ

```bash
sudo systemctl status odoo
sudo systemctl restart odoo
sudo journalctl -u odoo -f
sudo tail -f /var/log/odoo/odoo.log
```

## Reverse proxy ด้วย Nginx

คัดลอกตัวอย่าง config แล้วแก้ `server_name`:

```bash
sudo apt-get install -y nginx
sudo cp deploy/nginx-odoo.conf.example /etc/nginx/sites-available/odoo
sudo ln -s /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/odoo
sudo nginx -t
sudo systemctl reload nginx
```

ถ้าใช้ Nginx ให้คงค่า `proxy_mode = True` ใน `/etc/odoo/odoo.conf`

## Config สำคัญ

ไฟล์ `/etc/odoo/odoo.conf` ถูกสร้างครั้งแรกโดย installer และจะไม่ถูกเขียนทับเมื่อรันใหม่ ค่า `admin_passwd` คือ master password สำหรับจัดการ database ควรเก็บไว้ให้ดีและเปลี่ยนเป็นรหัสยาว

ถ้าต้องเปลี่ยน port:

```ini
http_port = 8069
```

แล้ว restart:

```bash
sudo systemctl restart odoo
```

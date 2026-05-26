# Odoo

Odoo with docker

บน server รัน:
cd ~/Odoo
git pull
docker compose build --no-cache --progress=plain odoo
docker compose up -d

ถ้าผ่านแล้วดูสถานะ:
docker compose ps
docker compose logs -f odoo

เข้าเว็บได้ที่:
http://10.110.23.90:8069

หรือถ้าเปิดจากเครื่อง server เอง:
http://localhost:8069

ถ้าเข้าเว็บจากข้างนอกไม่ได้ ให้เปิด firewall:
sudo ufw allow 8069/tcp
sudo ufw status

ดู container:
docker compose ps

ดู log ต่อ:
docker compose logs -f odoo

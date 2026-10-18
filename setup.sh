#!/usr/bin/env bash
# Panel kurulumu (root olarak):  bash setup.sh
#
# Ortam değişkenleri (hepsi isteğe bağlı):
#   PANEL_ADDR            Panelin dinleyeceği adres (varsayılan 127.0.0.1:8080)
#   PANEL_ADMIN_PASSWORD  İlk admin şifresi (yoksa rastgele üretilir ve ekrana yazılır).
#                         Yalnızca ilk kullanıcı oluşturulurken kullanılır, servise kaydedilmez.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Root olarak çalıştır: sudo bash setup.sh"; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SRC/panel" ] || { echo "panel dosyası bulunamadı ($SRC)"; exit 1; }

ADDR="${PANEL_ADDR:-127.0.0.1:8080}"
APP=/opt/panel

echo "==> Python kuruluyor (panelden ekleyeceğin botlar için)"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y python3 python3-pip
elif command -v yum >/dev/null 2>&1; then
  yum install -y python3 python3-pip
else
  echo "UYARI: paket yöneticisi bulunamadı, python3 elle kurulmalı."
fi

echo "==> Kullanıcı ve klasör"
if ! id panel >/dev/null 2>&1; then
  if command -v adduser >/dev/null 2>&1 && adduser --help 2>&1 | grep -q -- "--system"; then
    adduser --system --group --home "$APP" panel
  else
    useradd --system --user-group --home-dir "$APP" --shell /usr/sbin/nologin panel
  fi
fi
mkdir -p "$APP"

echo "==> Panel kopyalanıyor"
systemctl stop panel 2>/dev/null || true
install -m 755 "$SRC/panel" "$APP/panel"
chown -R panel:panel "$APP"

# İlk admin şifresi verildiyse, servis başlamadan hesabı o şifreyle oluştur.
# (Servise kalıcı yazılmaz: PANEL_ADMIN_PASSWORD her başlatmada şifreyi sıfırlar.)
if [ -n "${PANEL_ADMIN_PASSWORD:-}" ] && [ ! -f "$APP/data/users.json" ]; then
  echo "==> Admin hesabı belirlediğin şifreyle oluşturuluyor"
  ENVF="$(mktemp)"; chmod 600 "$ENVF"
  printf 'PANEL_ADMIN_PASSWORD=%q\n' "$PANEL_ADMIN_PASSWORD" > "$ENVF"
  (
    set -a; . "$ENVF"; set +a
    cd "$APP"
    # Geçici örnek: boş bir portta açılıp hesabı yazar, 4 sn sonra kapanır.
    runuser -u panel -- env PANEL_ADMIN_PASSWORD="$PANEL_ADMIN_PASSWORD" PANEL_ADDR=127.0.0.1:0 \
      timeout 4 "$APP/panel" >/dev/null 2>&1 || true
  )
  rm -f "$ENVF"
  [ -f "$APP/data/users.json" ] || echo "UYARI: users.json oluşmadı; şifre ilk açılışta rastgele üretilecek."
fi

echo "==> Servis yazılıyor"
cat > /etc/systemd/system/panel.service <<UNIT
[Unit]
Description=Bot Paneli
After=network.target

[Service]
User=panel
WorkingDirectory=$APP
Environment=PANEL_ADDR=$ADDR
ExecStart=$APP/panel
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable panel >/dev/null 2>&1
systemctl restart panel
sleep 3

echo
echo "================ KURULUM TAMAM ================"
if systemctl is-active --quiet panel; then
  echo "panel servisi: çalışıyor"
else
  echo "UYARI: panel çalışmıyor, journalctl -u panel ile bak"
fi
echo "Dinleme adresi: $ADDR"
echo
if journalctl -u panel --no-pager 2>/dev/null | grep -q "İlk kurulum"; then
  echo "Giriş bilgileri (ilk kurulumda üretildi):"
  journalctl -u panel --no-pager | grep -A4 "İlk kurulum" | tail -5
  echo
fi
echo "Panele girmek için bilgisayarında:  ssh -L 8080:127.0.0.1:8080 root@SUNUCU_IP"
echo "Sonra tarayıcıda:                   http://localhost:8080"
echo "API anahtarı:                       cat $APP/data/api_key.txt"
echo "Loglar:                             journalctl -u panel -f"

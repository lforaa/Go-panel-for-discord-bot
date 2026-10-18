#!/usr/bin/env bash
# Panele alan adsız, doğrudan IP ile erişim ekler (Caddy).
#   bash ip.sh          -> https://IP  (şifreli, tarayıcı bir kez "güvenli değil" uyarısı verir)
#   bash ip.sh http     -> http://IP   (şifresiz, önerilmez)
#   bash ip.sh https 1.2.3.4   -> IP'yi elle ver (otomatik bulunamazsa)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Root olarak çalıştır: sudo bash ip.sh"; exit 1; }

MODE="${1:-https}"
case "$MODE" in https|http) ;; *) echo "Kullanım: bash ip.sh [https|http] [IP]"; exit 1 ;; esac

systemctl list-unit-files panel.service >/dev/null 2>&1 || { echo "panel servisi yok, önce setup.sh çalıştır."; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y caddy curl

IP="${2:-$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)}"
if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Sunucu IP'si bulunamadı. Elle ver:  bash ip.sh $MODE 1.2.3.4"; exit 1
fi

echo "==> Caddy ayarı yazılıyor ($MODE, $IP)"
[ -f /etc/caddy/Caddyfile ] && cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%s)"
if [ "$MODE" = "https" ]; then
  cat > /etc/caddy/Caddyfile <<CADDY
https://$IP {
    tls internal
    reverse_proxy 127.0.0.1:8080
}
CADDY
else
  cat > /etc/caddy/Caddyfile <<'CADDY'
:80 {
    reverse_proxy 127.0.0.1:8080
}
CADDY
fi
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || { echo "Caddy ayarı geçersiz!"; exit 1; }

echo "==> Panele proxy ayarı veriliyor"
mkdir -p /etc/systemd/system/panel.service.d
cat > /etc/systemd/system/panel.service.d/proxy.conf <<'UNIT'
[Service]
Environment=PANEL_TRUST_PROXY=1
UNIT

systemctl daemon-reload
systemctl restart panel
systemctl enable caddy >/dev/null 2>&1
systemctl restart caddy

# ufw aktifse 22 ve 80/443 aç (aktif değilse dokunma)
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "==> ufw: 22, 80, 443 açılıyor"
  ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
fi

sleep 2
echo
echo "================ TAMAM ================"
echo "panel : $(systemctl is-active panel)"
echo "caddy : $(systemctl is-active caddy)"
echo
if [ "$MODE" = "https" ]; then
  echo "Adres: https://$IP"
  echo "İlk girişte tarayıcı 'güvenli değil' uyarısı verir: Gelişmiş -> Devam et."
  echo "(Sertifika kendi imzalı, trafik yine de şifreli.)"
else
  echo "Adres: http://$IP"
  echo "UYARI: HTTP şifresizdir, giriş şifreleri ağda açık gider."
fi
echo
echo "Açılmazsa sağlayıcının (DeHost vb.) güvenlik duvarında 80 ve 443 açık olmalı."
echo "Loglar: journalctl -u caddy -n 30 --no-pager"
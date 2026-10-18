#!/usr/bin/env bash
# Bot Paneli — tek komutla kurulum (menülü). Sunucuda root olarak çalıştır:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/lforaa/Go-panel-for-discord-bot/main/install.sh)
#
# İsteğe bağlı ortam değişkenleri:
#   REPO_URL, REPO_BRANCH     Kaynak repo / dal
#   PANEL_ADMIN_PASSWORD      Admin şifresi (en az 8 karakter; verilmezse sorulur, boşsa rastgele üretilir)
#   DRY_RUN=1                 Hiçbir şey kurmaz, sadece yapılacakları yazar (deneme için)
#   PANEL_INPUT               Cevapların okunacağı dosya (varsayılan /dev/tty)
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/lforaa/Go-panel-for-discord-bot.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
APP=/opt/panel
GO_VERSION=1.24.7   # bootstrap; go.mod'un istediği sürümü GOTOOLCHAIN=auto indirir
DRY_RUN="${DRY_RUN:-0}"
INPUT="${PANEL_INPUT:-/dev/tty}"
TMP=""

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mUYARI:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mHATA:\033[0m %s\n' "$*" >&2; exit 1; }
dry()  { [ "$DRY_RUN" = 1 ]; }
run()  { if dry; then echo "[dry-run] $*"; else "$@"; fi; }
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT

# ---- Girdi yardımcıları (curl | bash ile de çalışsın diye /dev/tty'den okunur) ----
HAVE_IN=0
if [ -r "$INPUT" ]; then exec 3<"$INPUT"; HAVE_IN=1; fi   # bir kez aç, satır satır oku

# Not: yerel değişken adları _ ile başlar; çağıranın değişkenini (ör. "a") gölgelemesin diye.
ask() { # ask DEĞİŞKEN "Soru" "varsayılan"
  local _v="$1" _q="$2" _d="${3:-}" _a=""
  printf '%s%s: ' "$_q" "${_d:+ [$_d]}" >&2
  if [ "$HAVE_IN" = 1 ]; then read -r _a <&3 || true; fi
  if [ ! -t 3 ]; then echo >&2; fi
  printf -v "$_v" '%s' "${_a:-$_d}"
}
ask_secret() { # ask_secret DEĞİŞKEN "Soru"
  local _v="$1" _q="$2" _a=""
  printf '%s: ' "$_q" >&2
  if [ "$HAVE_IN" = 1 ]; then
    if [ -t 3 ]; then read -rs _a <&3 || true; else read -r _a <&3 || true; fi
  fi
  echo >&2
  printf -v "$_v" '%s' "$_a"
}
confirm() { # confirm "Soru" [varsayılan e|h]
  local a; ask a "$1 (e/h)" "${2:-h}"
  case "${a,,}" in e|evet|y|yes) return 0 ;; *) return 1 ;; esac
}

# ---- Ön kontroller ----
[ "$(id -u)" -eq 0 ] || die "Root olarak çalıştır:  sudo -i  yazıp betiği tekrar başlat."
[ "$(uname -s)" = Linux ] || die "Yalnızca Linux desteklenir."
command -v systemctl >/dev/null 2>&1 || die "systemd bulunamadı; panel servisi systemd ile kuruluyor."
case "$(uname -m)" in
  x86_64|amd64) GOARCH=amd64 ;;
  aarch64|arm64) GOARCH=arm64 ;;
  *) die "Desteklenmeyen işlemci mimarisi: $(uname -m)" ;;
esac
if   command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf     >/dev/null 2>&1; then PM=dnf
elif command -v yum     >/dev/null 2>&1; then PM=yum
else die "Desteklenen paket yöneticisi yok (apt, dnf, yum)."; fi

pkg_install() {
  case "$PM" in
    apt) export DEBIAN_FRONTEND=noninteractive; run apt-get update -y; run apt-get install -y "$@" ;;
    dnf) run dnf install -y "$@" ;;
    yum) run yum install -y "$@" ;;
  esac
}

# ---- Kurulum adımları ----
ensure_tools() {
  say "Gerekli araçlar kuruluyor (curl, git, tar)"
  pkg_install curl git tar ca-certificates
}

ensure_go() {
  if [ -x /usr/local/go/bin/go ]; then say "Go zaten kurulu"; return; fi
  say "Go $GO_VERSION kuruluyor"
  if dry; then echo "[dry-run] go.dev'den go$GO_VERSION.linux-$GOARCH.tar.gz indirilip /usr/local'a açılır"; return; fi
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -o "$TMP/go.tgz" \
    || die "Go indirilemedi (go.dev'e erişim var mı?)"
  tar -C /usr/local -xzf "$TMP/go.tgz"
}

get_source() {
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [ -n "$here" ] && [ -f "$here/main.go" ] && [ -f "$here/setup.sh" ] && [ -d "$here/web" ]; then
    SRC="$here"; say "Kaynak kod: $SRC"; return
  fi
  SRC="$TMP/src"
  say "Kaynak kod indiriliyor ($REPO_URL, dal: $REPO_BRANCH)"
  if dry; then echo "[dry-run] git clone --depth 1 -b $REPO_BRANCH $REPO_URL"; return; fi
  git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$SRC" || die "Repo indirilemedi: $REPO_URL"
}

build_panel() {
  say "Panel derleniyor (ilk seferde Go araç zinciri ve modüller indirilir, birkaç dakika sürebilir)"
  if dry; then echo "[dry-run] CGO_ENABLED=0 go build -o $SRC/panel ."; return; fi
  ( cd "$SRC" && GOTOOLCHAIN=auto CGO_ENABLED=0 /usr/local/go/bin/go build -ldflags '-s -w' -o panel . ) \
    || die "Derleme başarısız oldu (yukarıdaki çıktıya bak)."
}

run_setup() { # PANEL_ADDR ve PANEL_ADMIN_PASSWORD ortamdan gider
  say "Panel kuruluyor (Python, servis, otomatik başlatma)"
  if dry; then echo "[dry-run] PANEL_ADDR=$PANEL_ADDR bash setup.sh"; return; fi
  ( cd "$SRC" && PANEL_ADDR="$PANEL_ADDR" bash ./setup.sh ) || die "setup.sh hata verdi."
}

open_ports() { # open_ports 80 443 ...
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    say "ufw: 22 ve $* açılıyor"
    run ufw allow 22/tcp; for p in "$@"; do run ufw allow "$p/tcp"; done
  fi
}

proxy_dropin() {
  run mkdir -p /etc/systemd/system/panel.service.d
  if dry; then echo "[dry-run] PANEL_TRUST_PROXY=1 drop-in yazılır"; return; fi
  printf '[Service]\nEnvironment=PANEL_TRUST_PROXY=1\n' > /etc/systemd/system/panel.service.d/proxy.conf
}

setup_domain() {
  [ "$PM" = apt ] || die "Alan adı (Let's Encrypt) kurulumu şimdilik yalnızca Debian/Ubuntu'da otomatik. Diğer dağıtımlarda IP seçeneğini kullan."
  say "Caddy ve $DOMAIN için HTTPS ayarlanıyor"
  local myip dnsip
  myip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  dnsip="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [ -n "$myip" ] && [ "$dnsip" != "$myip" ]; then
    warn "$DOMAIN şu an ${dnsip:-çözümlenmiyor}; bu sunucunun IP'si $myip. DNS A kaydı bu IP'yi göstermiyorsa sertifika alınamaz."
    confirm "Yine de devam edilsin mi?" h || die "İptal edildi. DNS'i düzeltip tekrar çalıştır."
  fi
  pkg_install caddy
  if ! dry; then
    command -v caddy >/dev/null 2>&1 || die "Caddy kurulamadı."
    [ -f /etc/caddy/Caddyfile ] && cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%s)"
    printf '%s {\n    reverse_proxy 127.0.0.1:8080\n}\n' "$DOMAIN" > /etc/caddy/Caddyfile
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || die "Caddy ayarı geçersiz."
  else
    echo "[dry-run] /etc/caddy/Caddyfile: $DOMAIN -> 127.0.0.1:8080"
  fi
  proxy_dropin
  run systemctl daemon-reload
  run systemctl restart panel
  run systemctl enable caddy
  run systemctl restart caddy
  open_ports 80 443
  ACCESS_URL="https://$DOMAIN"
}

setup_ip_https() {
  say "IP üzerinden HTTPS (kendi imzalı sertifika) ayarlanıyor"
  if dry; then echo "[dry-run] bash domain.sh https"; ACCESS_URL="https://SUNUCU_IP"; return; fi
  ( cd "$SRC" && bash ./domain.sh https ) || die "IP erişimi kurulamadı."
  ACCESS_URL="https://$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo SUNUCU_IP)"
}

# ---- Menü işlemleri ----
do_install() {
  local mode pw1 pw2
  echo
  echo "Panele nasıl erişeceksin?"
  echo "  1) Yalnızca SSH tüneliyle (en güvenli, ek kurulum yok)"
  echo "  2) Alan adı + otomatik HTTPS (Let's Encrypt)   — DNS A kaydı bu sunucuyu göstermeli"
  echo "  3) Sunucu IP'si ile HTTPS (kendi imzalı sertifika, tarayıcı bir kez uyarır)"
  echo "  4) Açık HTTP, port 8080 (ŞİFRESİZ — önerilmez)"
  ask mode "Seçim" 1
  DOMAIN=""; ACCESS_URL=""; PANEL_ADDR="127.0.0.1:8080"
  case "$mode" in
    1|3) ;;
    2) ask DOMAIN "Alan adı (ör. panel.ornek.com)" ""; [ -n "$DOMAIN" ] || die "Alan adı gerekli."
       [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Geçersiz alan adı: $DOMAIN" ;;
    4) PANEL_ADDR="0.0.0.0:8080"; warn "HTTP şifresizdir; giriş şifren ağda açık gider." ;;
    *) die "Geçersiz seçim: $mode" ;;
  esac

  PANEL_ADMIN_PASSWORD="${PANEL_ADMIN_PASSWORD:-}"
  if [ -z "$PANEL_ADMIN_PASSWORD" ] && [ ! -f "$APP/data/users.json" ]; then
    echo
    echo "Admin şifresi (en az 8 karakter). Boş bırakırsan rastgele üretilir ve kurulum sonunda gösterilir."
    ask_secret pw1 "Şifre"
    if [ -n "$pw1" ]; then
      [ "${#pw1}" -ge 8 ] || die "Şifre en az 8 karakter olmalı."
      ask_secret pw2 "Şifre (tekrar)"
      [ "$pw1" = "$pw2" ] || die "Şifreler aynı değil."
      PANEL_ADMIN_PASSWORD="$pw1"
    fi
  fi
  if [ -n "$PANEL_ADMIN_PASSWORD" ] && [ "${#PANEL_ADMIN_PASSWORD}" -lt 8 ]; then die "Şifre en az 8 karakter olmalı."; fi
  export PANEL_ADMIN_PASSWORD

  TMP="$(mktemp -d)"
  ensure_tools
  ensure_go
  get_source
  build_panel
  run_setup
  case "$mode" in
    2) setup_domain ;;
    3) setup_ip_https ;;
    4) open_ports 8080; ACCESS_URL="http://SUNUCU_IP:8080" ;;
  esac

  say "Bitti"
  [ -n "$ACCESS_URL" ] && echo "Adres: $ACCESS_URL"
  [ "$mode" = 1 ] && echo "SSH tüneli (kendi bilgisayarında):  ssh -L 8080:127.0.0.1:8080 root@SUNUCU_IP   →   http://localhost:8080"
  [ -n "$PANEL_ADMIN_PASSWORD" ] && echo "Admin: kullanıcı 'admin', şifre senin belirlediğin şifre."
  echo "Loglar: journalctl -u panel -f"
}

do_status() {
  say "Panel durumu"
  systemctl is-active panel 2>/dev/null | sed 's/^/servis: /' || true
  systemctl is-enabled panel 2>/dev/null | sed 's/^/açılışta başlar: /' || true
  [ -f "$APP/data/api_key.txt" ] && echo "API anahtarı: $APP/data/api_key.txt dosyasında"
  journalctl -u panel --no-pager -n 5 2>/dev/null || true
}

do_uninstall() {
  confirm "Panel servisi kaldırılsın mı?" h || { echo "İptal edildi."; return; }
  say "Servis durduruluyor ve kaldırılıyor"
  run systemctl disable --now panel
  run rm -f /etc/systemd/system/panel.service
  run rm -rf /etc/systemd/system/panel.service.d
  run systemctl daemon-reload
  if confirm "$APP klasörü (hesaplar, botlar, veritabanı) da SİLİNSİN mi? Geri alınamaz" h; then
    run rm -rf "$APP"; echo "$APP silindi."
  else
    echo "$APP korundu."
  fi
  echo "Caddy kurulduysa ayrıca kaldırılmadı."
}

# ---- Ana menü ----
echo
echo "================ Bot Paneli Kurulum ================"
echo "  1) Paneli kur / güncelle"
echo "  2) Durumu göster"
echo "  3) Paneli kaldır"
echo "  0) Çık"
ask choice "Seçim" 1
case "$choice" in
  1) do_install ;;
  2) do_status ;;
  3) do_uninstall ;;
  0) exit 0 ;;
  *) die "Geçersiz seçim: $choice" ;;
esac

# Go — Bot Paneli

Python botlarını web arayüzünden yöneten küçük Go paneli (`go run .` → http://127.0.0.1:8080).

Dinleme adresi varsayılan olarak `127.0.0.1:8080`'dir; değiştirmek için `PANEL_ADDR` ortam değişkenini kullan
(ör. `PANEL_ADDR=0.0.0.0:8080`). Dışarıya açarsan trafik şifresiz olur; `https` için aşağıdaki `--ip-access` seçeneğini kullan.

## Tek komutla kurulum (sunucunun içinde)

Sunucuya SSH ile girip **root** olarak şunu çalıştır:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lforaa/Go-panel-for-discord-bot/main/install.sh)
```

Menü açılır: paneli kur/güncelle, durumu göster, kaldır. Kurarken erişim şeklini seçersin:
SSH tüneli (varsayılan), alan adı + otomatik HTTPS (Let's Encrypt), IP ile HTTPS ya da açık HTTP.
Betik Go'yu, Python'u ve paneli kurar, servisi açılışta otomatik başlayacak şekilde ayarlar.
Aynı komutu tekrar çalıştırmak paneli günceller; hesaplar ve botlar silinmez.

`DRY_RUN=1 bash install.sh` yazarsan hiçbir şey kurmadan yapılacakları listeler.

## Otomatik kurulum (kendi bilgisayarından, SSH ile)

Bu bilgisayarda Python 3 yeterli; sunucuda systemd olan bir Linux (Debian/Ubuntu, Fedora/RHEL…) gerekir.

```bash
pip install -r installer/requirements.txt

python3 installer/install.py                  # sorularla ilerler
python3 installer/install.py --web            # tarayıcıda yerel kurulum paneli (http://127.0.0.1:9090)
python3 installer/install.py --host 1.2.3.4 --user root --ip-access
python3 installer/install.py --host 1.2.3.4 --key ~/.ssh/id_ed25519 --admin-password 'en-az-8-karakter'
```

Araç şunları yapar: SSH ile bağlanır → paneli Linux için derler (bu bilgisayarda Go varsa orada, yoksa ya da
başarısız olursa sunucuda; Go gerekirse sunucuya kurulur) → `setup.sh` ile Python, `panel` kullanıcısı ve
`systemd` servisini kurar → servisi başlatır ve **açılışta otomatik başlayacak** şekilde etkinleştirir →
admin giriş bilgilerini gösterir. Aynı komut tekrar çalıştırılırsa paneli günceller; mevcut hesaplar ve botlar silinmez.

| Seçenek | Anlamı |
|---|---|
| `--admin-password` | İlk admin şifresi (en az 8 karakter). Verilmezse rastgele üretilip kurulum sonunda gösterilir |
| `--ip-access` | Caddy ile `https://SUNUCU_IP` erişimi ekler (kendi imzalı sertifika, tarayıcı bir kez uyarır) |
| `--addr` | Panelin dinleme adresi (varsayılan `127.0.0.1:8080`) |
| `--build auto\|local\|remote` | Derlemenin nerede yapılacağı |

`--ip-access` kullanmazsan panele SSH tüneliyle girersin: `ssh -L 8080:127.0.0.1:8080 root@SUNUCU_IP` → http://localhost:8080.
Sunucu loglarına bakmak için: `journalctl -u panel -f`.

> `paket/` ve `paket.tar.gz` eski elle kurulum yöntemidir (`paketle.ps1`); otomatik kurulum bunları kullanmaz.
> Sabit IP ile derlenmiş eski ikili dosyaları kullanma, `paketle.ps1`'i yeniden çalıştır.

## Giriş ve hesaplar

İlk çalıştırmada `admin` hesabı oluşturulur ve rastgele şifresi terminale **bir kez** yazılır.
Kendin belirlemek ya da unuttuğun admin şifresini sıfırlamak için:

```bash
PANEL_ADMIN_PASSWORD='en-az-8-karakter' go run .
```

Hesaplar `data/users.json` içinde (PBKDF2 ile hashlenmiş şifre) tutulur; dosya `.gitignore`'dadır, repoya gitmez.

### Yetkiler

| Yetki | Anlamı |
|---|---|
| `bots.view` | Botları ve konsol çıktısını görür |
| `bots.control` | Başlat / durdur / yeniden başlat / komut gönder |
| `bots.create` / `bots.edit` / `bots.delete` | Bot oluştur / düzenle / sil |
| `files.view` | Dosyaları listele, oku, indir |
| `files.write` | Dosya düzenle/oluştur, klasör aç, yeniden adlandır |
| `files.upload` | Dosya yükle |
| `files.delete` | Dosya/klasör sil |
| `db.view` / `db.write` | Veritabanı salt okunur / yazma |
| `users.create` / `users.delete` | Alt hesap oluştur / sil |
| `perms.grant` | Yetki ver, dosya engelini kaldır |
| `perms.revoke` | Yetki al, dosya erişimini engelle |

### Kurallar

- **Admin** her şeyi yapar, silinemez ve başka biri tarafından değiştirilemez.
- Herkes yalnızca **kendi oluşturduğu hesapları** (ve onların altındakileri) yönetir; kendini, üstünü ya da yan hesapları yönetemez.
- **Yetki verirken**: yetkiyi veren kişide *ve* hesabın üst hesabında da o yetki olmalı.
  Örneğin `perms.grant` var ama `perms.revoke` yoksa, kimseye `perms.revoke` veremez.
- Alt hesap üst hesabından fazla yetkiye sahip olamaz. Bir hesaptan yetki alınırsa altındakilerden de alınır.
- Yetki verme yetkisi olmayan biri, başlangıç yetkisi olan hesap oluşturamaz (yetkisiz oluşturur).
- Hesap silinince altındaki hesaplar da silinir ve oturumları kapanır.

### Dosya engelleri

Bir hesap için bir bot içindeki (ya da tüm botlardaki) belirli bir yol engellenebilir. Engelli yol listede görünmez;
okunamaz, indirilemez, değiştirilemez, silinemez, üzerine yüklenemez. Engeller alt hesaplara **miras kalır**.
Engel eklemek `perms.revoke`, kaldırmak `perms.grant` ister; kimse kendisine de uygulanan bir engeli başkası için kaldıramaz.

> ⚠ **Önemli:** Dosya engelleri panel arayüzünde uygulanır, işletim sistemi seviyesinde değil.
> `bots.control` + (`files.write` veya `files.upload`) yetkileri birleşince bir hesap sunucuda Python kodu
> çalıştırabilir; bu da engelleri, `data/users.json` dosyasını ve diğer botların dosyalarını okuyabilmek demektir.
> Bu yetkileri yalnızca güvendiğin hesaplara ver.

Yetki ile ilgili tüm işlemler terminale `[yetki] ...` satırıyla kaydedilir.

#!/usr/bin/env python3
"""
Bot Paneli — otomatik kurulum aracı.

Linux sunucuya SSH ile bağlanır, paneli derler/yükler, systemd servisi olarak
kurar ve başlatır. Sunucu açılışında panel kendiliğinden başlar.

Kullanım:
    pip install -r installer/requirements.txt

    python3 installer/install.py                      # soru-cevap ile
    python3 installer/install.py --host 1.2.3.4 --user root
    python3 installer/install.py --web                # tarayıcıda yerel kurulum paneli

Örnekler:
    python3 installer/install.py --host 1.2.3.4 --key ~/.ssh/id_ed25519 --ip-access
    python3 installer/install.py --host 1.2.3.4 --admin-password 'en-az-8-karakter'
"""
from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable, Optional

try:
    import paramiko
except ImportError:  # kurulum bilgisi main() içinde verilir
    paramiko = None

SRC_DEFAULT = Path(__file__).resolve().parent.parent
GO_BOOTSTRAP = "1.24.7"  # sunucuda yoksa kurulan Go; go.mod'un istediği sürümü GOTOOLCHAIN=auto indirir


# --------------------------------------------------------------------------- #
# Ayarlar
# --------------------------------------------------------------------------- #
@dataclass
class Config:
    host: str
    port: int = 22
    user: str = "root"
    password: str = ""
    key_file: str = ""
    admin_password: str = ""   # boşsa panel rastgele üretir ve kurulum sonunda gösterilir
    addr: str = "127.0.0.1:8080"
    ip_access: bool = False    # Caddy ile https://SUNUCU_IP üzerinden erişim
    build: str = "auto"        # auto | local | remote
    src: Path = SRC_DEFAULT


@dataclass
class Result:
    ok: bool
    admin_user: str = ""
    admin_password: str = ""
    url: str = ""
    tunnel: str = ""
    message: str = ""


class InstallError(Exception):
    pass


# --------------------------------------------------------------------------- #
# Kurulum
# --------------------------------------------------------------------------- #
class Installer:
    def __init__(self, cfg: Config, log: Callable[[str], None]):
        self.cfg = cfg
        self.log = log
        self.client = None
        self.sftp = None
        self.wd = ""

    # ---- SSH yardımcıları ------------------------------------------------- #
    def connect(self) -> None:
        c = self.cfg
        self.log(f"==> {c.user}@{c.host}:{c.port} adresine bağlanılıyor")
        client = paramiko.SSHClient()
        client.load_system_host_keys()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(
                c.host, port=c.port, username=c.user,
                password=c.password or None,
                key_filename=c.key_file or None,
                timeout=20, banner_timeout=30, auth_timeout=30,
                allow_agent=not c.password, look_for_keys=not c.password,
            )
        except paramiko.AuthenticationException:
            raise InstallError("SSH girişi reddedildi: kullanıcı adı, şifre veya anahtar hatalı.")
        except Exception as e:
            raise InstallError(f"Sunucuya bağlanılamadı: {e}")
        self.client = client
        key = client.get_transport().get_remote_server_key()
        fp = base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")
        self.log(f"    Sunucu parmak izi: SHA256:{fp}")
        self.sftp = client.open_sftp()

    def run(self, script: str, *, sudo: bool = True, quiet: bool = False) -> tuple[int, str]:
        """Betiği sunucuda bash ile çalıştırır, çıktıyı satır satır loglar."""
        body = "exec </dev/null\n" + script
        cmd = "bash -c " + shlex.quote(body)
        use_sudo = sudo and self.cfg.user != "root"
        if use_sudo:
            cmd = "sudo -S -p '' " + cmd
        chan = self.client.get_transport().open_session()
        chan.set_combine_stderr(True)
        chan.exec_command(cmd)
        if use_sudo and self.cfg.password:
            chan.send(self.cfg.password + "\n")
        collected: list[str] = []
        buf = ""
        while True:
            data = chan.recv(4096)
            if not data:
                break
            buf += data.decode("utf-8", "replace")
            parts = re.split(r"[\r\n]+", buf)
            buf = parts.pop()
            for line in parts:
                if line.strip():
                    collected.append(line)
                    if not quiet:
                        self.log("    " + line)
        if buf.strip():
            collected.append(buf)
            if not quiet:
                self.log("    " + buf)
        return chan.recv_exit_status(), "\n".join(collected)

    def put_text(self, remote: str, text: str, mode: int = 0o644) -> None:
        with self.sftp.open(remote, "wb") as f:
            f.write(text.encode("utf-8"))
        self.sftp.chmod(remote, mode)

    def put_file(self, local: Path, remote: str, mode: Optional[int] = None) -> None:
        self.sftp.put(str(local), remote)
        if mode is not None:
            self.sftp.chmod(remote, mode)

    # ---- Ön kontroller ---------------------------------------------------- #
    def check_remote(self) -> str:
        code, out = self.run("uname -s; uname -m; command -v systemctl >/dev/null && echo SYSTEMD",
                             sudo=False, quiet=True)
        lines = out.splitlines()
        if code != 0 or not lines or lines[0].strip() != "Linux":
            raise InstallError("Sunucu Linux görünmüyor; yalnızca Linux desteklenir.")
        if "SYSTEMD" not in lines:
            raise InstallError("Sunucuda systemd yok; panel servisi systemd ile kuruluyor.")
        arch = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(lines[1].strip())
        if not arch:
            raise InstallError(f"Desteklenmeyen işlemci mimarisi: {lines[1].strip()}")
        if self.cfg.user != "root":
            code, _ = self.run("true", quiet=True)
            if code != 0:
                raise InstallError("Kullanıcı sudo kullanamıyor. root ile bağlan ya da sudo yetkisi ver.")
        self.log(f"    Linux / {arch}")
        return arch

    # ---- Derleme ---------------------------------------------------------- #
    def build_local(self, arch: str, out: Path) -> bool:
        go = shutil.which("go")
        if not go:
            self.log("    Bu bilgisayarda Go yok.")
            return False
        self.log("==> Panel bu bilgisayarda Linux için derleniyor")
        env = dict(os.environ, GOOS="linux", GOARCH=arch, CGO_ENABLED="0")
        try:
            r = subprocess.run([go, "build", "-ldflags", "-s -w", "-o", str(out), "."],
                               cwd=self.cfg.src, env=env, capture_output=True, text=True, timeout=900)
        except Exception as e:
            self.log(f"    Yerel derleme çalıştırılamadı: {e}")
            return False
        if r.returncode != 0:
            tail = (r.stdout + r.stderr).strip().splitlines()[-6:]
            self.log("    Yerel derleme başarısız:")
            for line in tail:
                self.log("      " + line)
            return False
        self.log(f"    Derlendi ({out.stat().st_size // 1024} KB)")
        return True

    def build_remote(self, tmp: Path) -> None:
        self.log("==> Kaynak kod sunucuya yükleniyor, orada derlenecek")
        tar_path = tmp / "src.tar.gz"
        src = self.cfg.src
        with tarfile.open(tar_path, "w:gz") as tf:
            for p in sorted(src.glob("*.go")):
                tf.add(p, arcname=p.name)
            for name in ("go.mod", "go.sum"):
                if (src / name).exists():
                    tf.add(src / name, arcname=name)
            tf.add(src / "web", arcname="web")
        self.put_file(tar_path, f"{self.wd}/src.tar.gz")
        script = f"""set -e
cd {self.wd}
mkdir -p src && tar -xzf src.tar.gz -C src
GO=/usr/local/go/bin/go
if [ ! -x "$GO" ]; then
  echo "==> Go kuruluyor"
  if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y curl ca-certificates
    elif command -v dnf >/dev/null 2>&1; then dnf install -y curl ca-certificates
    elif command -v yum >/dev/null 2>&1; then yum install -y curl ca-certificates
    fi
  fi
  case "$(uname -m)" in x86_64|amd64) GA=amd64;; aarch64|arm64) GA=arm64;; *) echo "desteklenmeyen mimari"; exit 1;; esac
  curl -fsSL "https://go.dev/dl/go{GO_BOOTSTRAP}.linux-$GA.tar.gz" -o go.tgz
  tar -C /usr/local -xzf go.tgz
fi
cd src
echo "==> Panel derleniyor (ilk seferde Go araç zinciri ve modüller indirilir)"
GOTOOLCHAIN=auto CGO_ENABLED=0 "$GO" build -ldflags '-s -w' -o ../panel .
echo "derleme tamam"
"""
        code, _ = self.run(script)
        if code != 0:
            raise InstallError("Sunucuda derleme başarısız oldu (yukarıdaki çıktıya bak). "
                               "Sunucunun internete (go.dev, proxy.golang.org) erişebildiğinden emin ol.")

    # ---- Ana akış --------------------------------------------------------- #
    def install(self) -> Result:
        cfg = self.cfg
        for need in ("main.go", "go.mod", "setup.sh", "web"):
            if not (cfg.src / need).exists():
                raise InstallError(f"Proje klasöründe '{need}' bulunamadı: {cfg.src}")
        if paramiko is None:
            raise InstallError("paramiko kurulu değil:  pip install -r installer/requirements.txt")

        self.connect()
        try:
            arch = self.check_remote()
            self.wd = f"/tmp/panel-install-{secrets.token_hex(4)}"
            code, _ = self.run(f"mkdir -p {self.wd} && chmod 700 {self.wd}", sudo=False, quiet=True)
            if code != 0:
                raise InstallError("Sunucuda geçici klasör oluşturulamadı.")

            with tempfile.TemporaryDirectory() as t:
                tmp = Path(t)
                binary = tmp / "panel"
                built = False
                if cfg.build in ("auto", "local"):
                    built = self.build_local(arch, binary)
                    if not built and cfg.build == "local":
                        raise InstallError("Yerel derleme istendi ama başarısız oldu.")
                if built:
                    self.log("==> Panel sunucuya yükleniyor")
                    self.put_file(binary, f"{self.wd}/panel", 0o755)
                else:
                    self.build_remote(tmp)

            # setup.sh (CRLF -> LF) ve isteğe bağlı ip.sh
            setup = (cfg.src / "setup.sh").read_text(encoding="utf-8").replace("\r\n", "\n")
            self.put_text(f"{self.wd}/setup.sh", setup, 0o755)
            if cfg.ip_access:
                dom = (cfg.src / "domain.sh").read_text(encoding="utf-8").replace("\r\n", "\n")
                self.put_text(f"{self.wd}/ip.sh", dom, 0o755)

            env = f"PANEL_ADDR={shlex.quote(cfg.addr)}\n"
            if cfg.admin_password:
                env += f"PANEL_ADMIN_PASSWORD={shlex.quote(cfg.admin_password)}\n"
            self.put_text(f"{self.wd}/.env", env, 0o600)

            self.log("==> Kurulum çalıştırılıyor (Python, servis, otomatik başlatma)")
            code, out = self.run(f"""set -e
cd {self.wd}
set -a; . ./.env; set +a
rm -f .env
bash ./setup.sh
""")
            if code != 0:
                raise InstallError("setup.sh hata verdi (yukarıdaki çıktıya bak).")

            result = Result(ok=True)
            m_user = re.search(r"Kullanıcı adı:\s*(\S+)", out)
            m_pass = re.search(r"Şifre\s*:\s*(.+)", out)
            if cfg.admin_password:
                result.admin_user, result.admin_password = "admin", cfg.admin_password
            elif m_user and m_pass and "ortam değişkeninden" not in m_pass.group(1):
                result.admin_user, result.admin_password = m_user.group(1), m_pass.group(1).strip()
            elif m_user:
                result.admin_user = m_user.group(1)
            else:
                result.message = ("Panel daha önce kurulmuş; mevcut admin hesabı korundu. "
                                  "Şifreyi sıfırlamak için --admin-password ile yeniden kur.")

            if cfg.ip_access:
                self.log("==> HTTPS (Caddy) üzerinden IP erişimi ekleniyor")
                ip_arg = cfg.host if re.fullmatch(r"(\d{1,3}\.){3}\d{1,3}", cfg.host) else ""
                code, _ = self.run(f"cd {self.wd} && bash ./ip.sh https {ip_arg}")
                if code != 0:
                    self.log("    UYARI: IP erişimi kurulamadı; panel SSH tüneliyle yine de kullanılabilir.")
                else:
                    result.url = f"https://{ip_arg or cfg.host}"

            host_part, _, port_part = cfg.addr.rpartition(":")
            local_host = "127.0.0.1" if host_part in ("", "0.0.0.0") else host_part
            if not result.url and host_part in ("0.0.0.0", ""):
                result.url = f"http://{cfg.host}:{port_part} (şifresiz HTTP!)"
            result.tunnel = (f"ssh -L 8080:{local_host}:{port_part} {cfg.user}@{cfg.host}"
                             + (f" -p {cfg.port}" if cfg.port != 22 else "") + "   →   http://localhost:8080")

            self.log("==> Servis doğrulanıyor")
            code, out = self.run(
                "systemctl is-active panel; systemctl is-enabled panel;"
                f" curl -s -o /dev/null -w 'HTTP %{{http_code}}' http://{local_host}:{port_part}/ || true",
                sudo=False, quiet=True)
            self.log("    " + out.replace("\n", " | "))
            if out.split("\n")[0].strip() != "active":
                raise InstallError("Panel servisi çalışmıyor: sunucuda  journalctl -u panel -n 50  ile bak.")
            return result
        finally:
            try:
                self.run(f"rm -rf {self.wd}", quiet=True)
            except Exception:
                pass
            try:
                self.client.close()
            except Exception:
                pass


def run_install(cfg: Config, log: Callable[[str], None]) -> Result:
    try:
        return Installer(cfg, log).install()
    except InstallError as e:
        log(f"HATA: {e}")
        return Result(ok=False, message=str(e))
    except Exception as e:  # beklenmeyen
        log(f"BEKLENMEYEN HATA: {type(e).__name__}: {e}")
        return Result(ok=False, message=str(e))


def print_summary(res: Result, cfg: Config) -> None:
    print()
    if not res.ok:
        print("Kurulum BAŞARISIZ:", res.message)
        return
    print("=" * 56)
    print(" KURULUM TAMAM — panel çalışıyor ve açılışta kendiliğinden başlar")
    print("=" * 56)
    if res.admin_user:
        print(f" Kullanıcı adı : {res.admin_user}")
    if res.admin_password:
        print(f" Şifre         : {res.admin_password}")
        print(" (Giriş yaptıktan sonra şifreyi değiştir.)")
    if res.message:
        print(" Not           :", res.message)
    if res.url:
        print(f" Adres         : {res.url}")
    print(f" SSH tüneli    : {res.tunnel}")
    print(f" Loglar        : ssh {cfg.user}@{cfg.host}  →  journalctl -u panel -f")


# --------------------------------------------------------------------------- #
# Yerel mini web paneli (--web)
# --------------------------------------------------------------------------- #
PAGE = """<!doctype html><html lang="tr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Panel Kurulum</title>
<style>
:root{color-scheme:light dark;--bg:#f5f6f8;--card:#fff;--fg:#1c1f24;--mut:#667;--bd:#d9dce1;--ac:#2f6feb}
@media (prefers-color-scheme:dark){:root{--bg:#14161a;--card:#1c1f24;--fg:#e8eaed;--mut:#9aa0a6;--bd:#33373d;--ac:#5b8def}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px system-ui,sans-serif}
main{max-width:720px;margin:0 auto;padding:24px 16px}h1{font-size:22px;margin:0 0 4px}
p.s{color:var(--mut);margin:0 0 18px}.card{background:var(--card);border:1px solid var(--bd);border-radius:10px;padding:16px;margin-bottom:16px}
.g{display:grid;grid-template-columns:1fr 1fr;gap:12px}@media(max-width:560px){.g{grid-template-columns:1fr}}
label{display:block;font-size:13px;color:var(--mut);margin-bottom:4px}
input[type=text],input[type=password],input[type=number],select{width:100%;padding:9px 10px;border:1px solid var(--bd);border-radius:7px;background:transparent;color:var(--fg);font:inherit}
.full{grid-column:1/-1}.chk{display:flex;gap:8px;align-items:center}.chk label{margin:0;color:var(--fg)}
button{background:var(--ac);color:#fff;border:0;border-radius:8px;padding:10px 18px;font:inherit;cursor:pointer}
button:disabled{opacity:.5;cursor:default}
pre{margin:0;background:#0d1014;color:#cfd6df;padding:12px;border-radius:8px;max-height:360px;overflow:auto;font:12.5px/1.5 ui-monospace,monospace;white-space:pre-wrap}
.res{display:none}.res b{display:inline-block;min-width:110px}.err{color:#d93025}.ok{color:#1e8e3e}
</style></head><body><main>
<h1>Bot Paneli — Otomatik Kurulum</h1>
<p class="s">Linux sunucuna SSH ile bağlanır; paneli kurar ve açılışta otomatik başlayacak şekilde ayarlar.</p>
<form id="f" class="card"><div class="g">
<div><label>Sunucu IP / alan adı</label><input type="text" name="host" required></div>
<div><label>SSH portu</label><input type="number" name="port" value="22"></div>
<div><label>Kullanıcı</label><input type="text" name="user" value="root"></div>
<div><label>SSH şifresi</label><input type="password" name="password" autocomplete="off"></div>
<div class="full"><label>veya SSH anahtar dosyası yolu (bu bilgisayarda, isteğe bağlı)</label><input type="text" name="key_file" placeholder="~/.ssh/id_ed25519"></div>
<div><label>Panel admin şifresi (boşsa rastgele üretilir)</label><input type="password" name="admin_password" autocomplete="new-password"></div>
<div><label>Derleme</label><select name="build"><option value="auto">Otomatik</option><option value="local">Bu bilgisayarda</option><option value="remote">Sunucuda</option></select></div>
<div class="full chk"><input type="checkbox" id="ip" name="ip_access"><label for="ip">https://SUNUCU_IP ile erişim ekle (Caddy, kendi imzalı sertifika)</label></div>
</div><p style="margin:14px 0 0"><button id="b" type="submit">Kurulumu başlat</button></p></form>
<div class="card res" id="res"></div>
<div class="card"><pre id="log">Hazır.</pre></div>
</main><script>
const T=new URLSearchParams(location.search).get("t");let n=0,timer=null;
const H={"X-Token":T,"Content-Type":"application/json"};const log=document.getElementById("log");
function esc(s){return String(s).replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]))}
document.getElementById("f").addEventListener("submit",async e=>{
 e.preventDefault();const fd=new FormData(e.target),o={};fd.forEach((v,k)=>o[k]=v);o.ip_access=!!fd.get("ip_access");
 const r=await fetch("/api/start",{method:"POST",headers:H,body:JSON.stringify(o)});
 if(!r.ok){log.textContent=await r.text();return}
 n=0;log.textContent="";document.getElementById("b").disabled=true;document.getElementById("res").style.display="none";
 timer=setInterval(poll,800)});
async function poll(){
 const r=await fetch("/api/log?since="+n,{headers:H});if(!r.ok)return;const d=await r.json();
 if(d.lines.length){log.textContent+=d.lines.join("\\n")+"\\n";log.scrollTop=log.scrollHeight;n=d.next}
 if(d.done){clearInterval(timer);document.getElementById("b").disabled=false;show(d.result)}}
function show(r){const e=document.getElementById("res");e.style.display="block";
 if(!r.ok){e.innerHTML='<b class="err">Başarısız:</b> '+esc(r.message);return}
 let h='<p class="ok"><b>Kurulum tamam</b> — panel çalışıyor, açılışta otomatik başlar.</p>';
 if(r.admin_user)h+="<p><b>Kullanıcı adı</b>"+esc(r.admin_user)+"</p>";
 if(r.admin_password)h+="<p><b>Şifre</b><code>"+esc(r.admin_password)+"</code></p>";
 if(r.message)h+="<p>"+esc(r.message)+"</p>";
 if(r.url)h+="<p><b>Adres</b>"+esc(r.url)+"</p>";
 h+="<p><b>SSH tüneli</b><code>"+esc(r.tunnel)+"</code></p>";e.innerHTML=h}
</script></body></html>"""

_job = {"lines": [], "done": True, "result": None, "lock": threading.Lock()}


def _start_job(cfg: Config) -> None:
    def log(line: str) -> None:
        with _job["lock"]:
            _job["lines"].append(line)

    def worker() -> None:
        res = run_install(cfg, log)
        with _job["lock"]:
            _job["result"] = {
                "ok": res.ok, "admin_user": res.admin_user, "admin_password": res.admin_password,
                "url": res.url, "tunnel": res.tunnel, "message": res.message,
            }
            _job["done"] = True

    with _job["lock"]:
        _job.update(lines=[], done=False, result=None)
    threading.Thread(target=worker, daemon=True).start()


def serve_web(src: Path, port: int) -> None:
    token = secrets.token_urlsafe(16)
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):  # sessiz
            pass

        def _ok(self) -> bool:
            if self.headers.get("Host", "") not in allowed_hosts:
                self.send_error(403, "geçersiz Host")
                return False
            return True

        def _send(self, code: int, body: bytes, ctype: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if not self._ok():
                return
            u = self.path.split("?", 1)
            if u[0] == "/":
                if f"t={token}" not in (u[1] if len(u) > 1 else ""):
                    return self._send(403, "Adresi terminalde yazılan bağlantıdan aç.".encode(), "text/plain; charset=utf-8")
                return self._send(200, PAGE.encode(), "text/html; charset=utf-8")
            if u[0] == "/api/log":
                if self.headers.get("X-Token") != token:
                    return self._send(403, b"yetkisiz", "text/plain")
                since = int(re.search(r"since=(\d+)", u[1]).group(1)) if len(u) > 1 and "since=" in u[1] else 0
                with _job["lock"]:
                    lines = _job["lines"][since:]
                    out = {"lines": lines, "next": since + len(lines), "done": _job["done"], "result": _job["result"]}
                return self._send(200, json.dumps(out).encode(), "application/json")
            self._send(404, b"yok", "text/plain")

        def do_POST(self):
            if not self._ok():
                return
            if self.path != "/api/start" or self.headers.get("X-Token") != token:
                return self._send(403, b"yetkisiz", "text/plain")
            with _job["lock"]:
                if not _job["done"]:
                    return self._send(409, "Kurulum zaten çalışıyor.".encode(), "text/plain; charset=utf-8")
            try:
                d = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
                host = str(d.get("host", "")).strip()
                if not host:
                    return self._send(400, "Sunucu adresi gerekli.".encode(), "text/plain; charset=utf-8")
                cfg = Config(
                    host=host, port=int(d.get("port") or 22), user=str(d.get("user") or "root").strip(),
                    password=str(d.get("password") or ""),
                    key_file=os.path.expanduser(str(d.get("key_file") or "").strip()),
                    admin_password=str(d.get("admin_password") or ""),
                    ip_access=bool(d.get("ip_access")),
                    build=d.get("build") if d.get("build") in ("auto", "local", "remote") else "auto",
                    src=src,
                )
                if cfg.admin_password and len(cfg.admin_password) < 8:
                    return self._send(400, "Admin şifresi en az 8 karakter olmalı.".encode(), "text/plain; charset=utf-8")
            except Exception as e:
                return self._send(400, f"Geçersiz istek: {e}".encode(), "text/plain; charset=utf-8")
            _start_job(cfg)
            self._send(200, b"{}", "application/json")

    httpd = ThreadingHTTPServer(("127.0.0.1", port), H)
    url = f"http://127.0.0.1:{port}/?t={token}"
    print("Kurulum paneli (yalnızca bu bilgisayardan erişilir):")
    print("  ", url)
    print("Kapatmak için Ctrl+C")
    try:
        webbrowser.open(url)
    except Exception:
        pass
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nKapatıldı.")


# --------------------------------------------------------------------------- #
# Komut satırı
# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description="Bot Paneli otomatik kurulum aracı (SSH ile Linux sunucuya)")
    ap.add_argument("--host", help="Sunucu IP veya alan adı")
    ap.add_argument("--port", type=int, default=22, help="SSH portu (varsayılan 22)")
    ap.add_argument("--user", default="root", help="SSH kullanıcısı (varsayılan root)")
    ap.add_argument("--password", help="SSH şifresi (verilmezse sorulur; geçmişe düşmemesi için sormasını tercih et)")
    ap.add_argument("--key", dest="key_file", help="SSH özel anahtar dosyası")
    ap.add_argument("--admin-password", help="Panel admin şifresi (en az 8 karakter; boşsa rastgele üretilir)")
    ap.add_argument("--addr", default="127.0.0.1:8080", help="Panelin dinleme adresi (varsayılan 127.0.0.1:8080)")
    ap.add_argument("--ip-access", action="store_true", help="Caddy ile https://SUNUCU_IP erişimi ekle")
    ap.add_argument("--build", choices=("auto", "local", "remote"), default="auto",
                    help="Derleme yeri: auto (önce bu bilgisayar, olmazsa sunucu), local, remote")
    ap.add_argument("--src", type=Path, default=SRC_DEFAULT, help="Panel proje klasörü")
    ap.add_argument("--web", action="store_true", help="Tarayıcıda yerel kurulum paneli aç")
    ap.add_argument("--web-port", type=int, default=9090, help="--web için yerel port (varsayılan 9090)")
    a = ap.parse_args()

    if paramiko is None:
        print("paramiko kurulu değil. Şunu çalıştır:  pip install -r installer/requirements.txt")
        return 2

    if a.web:
        serve_web(a.src.resolve(), a.web_port)
        return 0

    host = a.host or input("Sunucu IP / alan adı: ").strip()
    if not host:
        print("Sunucu adresi gerekli.")
        return 2
    password = a.password
    if password is None and not a.key_file:
        password = getpass.getpass(f"{a.user}@{host} SSH şifresi (anahtar kullanacaksan boş bırak): ")
    admin_pw = a.admin_password or ""
    if admin_pw and len(admin_pw) < 8:
        print("Admin şifresi en az 8 karakter olmalı.")
        return 2

    cfg = Config(host=host, port=a.port, user=a.user, password=password or "",
                 key_file=os.path.expanduser(a.key_file or ""), admin_password=admin_pw,
                 addr=a.addr, ip_access=a.ip_access, build=a.build, src=a.src.resolve())
    res = run_install(cfg, print)
    print_summary(res, cfg)
    return 0 if res.ok else 1


if __name__ == "__main__":
    sys.exit(main())

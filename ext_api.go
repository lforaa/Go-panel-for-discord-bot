package main

// Harici (Discord botu vb.) servisler için API anahtarlı uç noktalar.
//
//   GET  /api/ext/bots                 -> tüm botlar ve durumları
//   GET  /api/ext/bot/<id>/status      -> tek bot durumu
//   POST /api/ext/bot/<id>/start       -> botu başlat (gövde opsiyonel, aşağıya bak)
//   POST /api/ext/bot/<id>/stop        -> botu durdur
//
// Kimlik doğrulama: "X-API-Key: <anahtar>" başlığı.
// Anahtar: PANEL_API_KEY ortam değişkeni, yoksa data/api_key.txt (ilk çalıştırmada üretilir).
//
// Start gövdesi (opsiyonel JSON): {"guild_id":"..","user_id":"..","duration_minutes":10}
// Bot sürecine TRIAL_GUILD_ID, TRIAL_USER_ID, TRIAL_MINUTES ortam değişkenleri olarak geçer.

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
)

var extKey string

var idRe = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
var numRe = regexp.MustCompile(`^[0-9]{1,32}$`)

const extKeyFile = "data/api_key.txt"

func initExtKey() {
	if k := strings.TrimSpace(os.Getenv("PANEL_API_KEY")); k != "" {
		extKey = k
		return
	}
	if data, err := os.ReadFile(extKeyFile); err == nil && strings.TrimSpace(string(data)) != "" {
		extKey = strings.TrimSpace(string(data))
		return
	}
	extKey = randomToken(32)
	if err := os.WriteFile(extKeyFile, []byte(extKey+"\n"), 0600); err != nil {
		fmt.Println("[ext] api_key.txt yazılamadı:", err)
	}
	fmt.Println("[ext] Yeni API anahtarı üretildi:", extKey, "(data/api_key.txt)")
}

func extAuthorized(r *http.Request) bool {
	got := r.Header.Get("X-API-Key")
	if got == "" || extKey == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(extKey)) == 1
}

// Harici API işlemlerini denetim günlüğüne yazar (security.go)
func extAudit(r *http.Request, action, detail string) {
	writeAudit(AuditEntry{Level: "info", IP: clientIP(r), User: "api", Action: action, Detail: detail})
}

func registerExt() {
	initExtKey()

	http.HandleFunc("/api/ext/bots", func(w http.ResponseWriter, r *http.Request) {
		list := []BotInfo{}
		for _, b := range mgr.all() {
			list = append(list, b.info())
		}
		writeJSON(w, list)
	})

	http.HandleFunc("/api/ext/bot/", func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/ext/bot/"), "/"), "/")
		if len(parts) != 2 || !idRe.MatchString(parts[0]) {
			http.Error(w, "geçersiz yol: /api/ext/bot/<id>/<start|stop|status>", http.StatusBadRequest)
			return
		}
		b := mgr.get(parts[0])
		if b == nil {
			http.Error(w, "bot bulunamadı", http.StatusNotFound)
			return
		}

		switch parts[1] {
		case "status":
			writeJSON(w, b.info())

		case "start":
			if r.Method != http.MethodPost {
				http.Error(w, "sadece POST", http.StatusMethodNotAllowed)
				return
			}
			var in struct {
				GuildID  string `json:"guild_id"`
				UserID   string `json:"user_id"`
				Duration int    `json:"duration_minutes"`
			}
			if body, _ := io.ReadAll(io.LimitReader(r.Body, 4096)); len(body) > 0 {
				if err := json.Unmarshal(body, &in); err != nil {
					http.Error(w, "geçersiz JSON", http.StatusBadRequest)
					return
				}
			}
			if (in.GuildID != "" && !numRe.MatchString(in.GuildID)) || (in.UserID != "" && !numRe.MatchString(in.UserID)) {
				http.Error(w, "guild_id/user_id sadece rakam olmalı", http.StatusBadRequest)
				return
			}
			if b.isRunning() {
				writeJSON(w, map[string]any{"ok": true, "status": "already_running"})
				return
			}
			env := []string{}
			if in.GuildID != "" {
				env = append(env, "TRIAL_GUILD_ID="+in.GuildID)
			}
			if in.UserID != "" {
				env = append(env, "TRIAL_USER_ID="+in.UserID)
			}
			if in.Duration > 0 && in.Duration <= 1440 {
				env = append(env, fmt.Sprintf("TRIAL_MINUTES=%d", in.Duration))
			}
			if err := b.startWithEnv(env); err != nil {
				b.addLog("[api] Başlatma hatası: " + err.Error())
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			b.addLog("[api] Harici istekle başlatıldı")
			extAudit(r, "bot başlattı (api)", fmt.Sprintf("id=%s guild=%s user=%s", b.ID, in.GuildID, in.UserID))
			writeJSON(w, map[string]any{"ok": true, "status": "started"})

		case "stop":
			if r.Method != http.MethodPost {
				http.Error(w, "sadece POST", http.StatusMethodNotAllowed)
				return
			}
			if !b.isRunning() {
				writeJSON(w, map[string]any{"ok": true, "status": "already_stopped"})
				return
			}
			b.Stop()
			b.addLog("[api] Harici istekle durduruldu")
			extAudit(r, "bot durdurdu (api)", "id="+b.ID)
			writeJSON(w, map[string]any{"ok": true, "status": "stopped"})

		default:
			http.Error(w, "bilinmeyen işlem", http.StatusNotFound)
		}
	})
}

package main

// Bot başlarken requirements.txt varsa venv'i oluşturur ve paketleri kurar.
// requirements.txt değişmediyse tekrar kurmaz (venv/.req.sha256 içinde özet tutulur).

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const depsTimeout = 10 * time.Minute

func venvPython(dir string) string {
	for _, p := range []string{
		filepath.Join(dir, "venv", "Scripts", "python.exe"),
		filepath.Join(dir, "venv", "bin", "python"),
	} {
		if _, err := os.Stat(p); err == nil {
			abs, _ := filepath.Abs(p) // cmd.Dir ayarlıyken göreli yol bozulur
			return abs
		}
	}
	return ""
}

// runLogged komutu çalıştırır, çıktısını satır satır bot loguna yazar.
func (b *Bot) runLogged(ctx context.Context, dir, prefix string, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "PYTHONUTF8=1", "PYTHONIOENCODING=utf-8",
		"PIP_DISABLE_PIP_VERSION_CHECK=1", "PIP_NO_INPUT=1")
	out, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return err
	}
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		if line := strings.TrimSpace(sc.Text()); line != "" {
			b.addLog(prefix + line)
		}
	}
	return cmd.Wait()
}

func (b *Bot) ensureDeps() error {
	b.depMu.Lock()
	defer b.depMu.Unlock()

	dir := botDir(b.ID)
	data, err := os.ReadFile(filepath.Join(dir, "requirements.txt"))
	if err != nil {
		return nil // requirements.txt yok: yapılacak bir şey yok
	}
	sum := sha256.Sum256(data)
	want := hex.EncodeToString(sum[:])
	stamp := filepath.Join(dir, "venv", ".req.sha256")

	vpy := venvPython(dir)
	if vpy != "" {
		if got, err := os.ReadFile(stamp); err == nil && strings.TrimSpace(string(got)) == want {
			return nil // zaten kurulu
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), depsTimeout)
	defer cancel()

	if vpy == "" {
		sys, err := findPython(dir)
		if err != nil {
			return fmt.Errorf("Python bulunamadı: %v", err)
		}
		b.addLog("[panel] venv oluşturuluyor...")
		if err := b.runLogged(ctx, dir, "[venv] ", sys, "-m", "venv", "--clear", "venv"); err != nil {
			return fmt.Errorf("venv oluşturulamadı (Linux'ta python3-venv paketi gerekir): %v", err)
		}
		if vpy = venvPython(dir); vpy == "" {
			return fmt.Errorf("venv oluşturuldu ama python bulunamadı")
		}
	}

	b.addLog("[panel] requirements.txt kuruluyor, bu birkaç dakika sürebilir...")
	if err := b.runLogged(ctx, dir, "[pip] ", vpy, "-m", "pip", "install", "-r", "requirements.txt"); err != nil {
		return fmt.Errorf("paketler kurulamadı: %v (loga bak)", err)
	}
	os.WriteFile(stamp, []byte(want+"\n"), 0644)
	b.addLog("[panel] Paketler kuruldu")
	return nil
}
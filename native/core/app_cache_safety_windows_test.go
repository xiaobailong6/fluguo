//go:build windows

package core

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestNativeCacheClearRejectsJunction(t *testing.T) {
	engine := cacheMaintenanceFixture(t)
	outside := t.TempDir()
	path := filepath.Join(outside, "valuable")
	if err := os.WriteFile(path, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	junction := filepath.Join(engine.cacheRoot(), "covers-v1", "junction")
	if output, err := exec.Command("cmd", "/c", "mklink", "/J", junction, outside).CombinedOutput(); err != nil {
		t.Skipf("junction unavailable: %v %s", err, output)
	}
	t.Cleanup(func() { _ = os.Remove(junction) })
	if !nativeCacheReparsePoint(junction) {
		t.Fatal("junction not recognized")
	}
	if result, err := engine.clearCache(context.Background()); err == nil || result != nil {
		t.Fatal(result, err)
	}
	if body, err := os.ReadFile(path); err != nil || string(body) != "keep" {
		t.Fatal("junction target changed", err)
	}
}

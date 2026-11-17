package core

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func legacyCacheFixture(t *testing.T, directory string, offset int) []byte {
	t.Helper()
	state := &hongguoCatalogState{Version: 1, DeviceID: "1001", InstallID: "1002", Registered: true,
		HelperDeviceID: "2001", HelperInstallID: "2002", HelperRegistered: true,
		Feeds: map[string]hongguoCatalogCursor{"short_play": {Offset: offset, Initialized: true}}}
	body, err := json.Marshal(nativeCatalogDisk{Version: 3, HongguoApp: state,
		Catalogs: map[string][]nativeDrama{sourceHongguo: {{ID: "hongguo:101", Source: sourceHongguo, Title: "合成缓存"}}},
		States:   map[string]nativeCatalogState{sourceHongguo: {Page: 1, HasMore: true}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "catalogs.json"), body, 0600); err != nil {
		t.Fatal(err)
	}
	return body
}

func newCacheTestEngine(t *testing.T, directory, cache string) *nativeEngine {
	t.Helper()
	engine, err := newNativeEngine(directory, "", cache)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	t.Cleanup(engine.downloader.client.CloseIdleConnections)
	return engine
}

func TestNativeCacheMigrationAndDeviceSurvival(t *testing.T) {
	directory, cache := t.TempDir(), t.TempDir()
	original := legacyCacheFixture(t, directory, 18)
	if err := os.Mkdir(filepath.Join(directory, "covers-v1"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "covers-v1", "fixture"), []byte("cover"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "rankings.json"), []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	engine := newCacheTestEngine(t, directory, cache)
	if !engine.separateCache() || len(engine.catalogs[sourceHongguo]) != 1 {
		t.Fatal("catalog was not migrated")
	}
	state := engine.downloader.hongguoCatalogSnapshot()
	if state.DeviceID != "1001" || state.HelperDeviceID != "2001" || state.Feeds["short_play"].Offset != 18 {
		t.Fatal("device or cursor lost")
	}
	backup, err := os.ReadFile(filepath.Join(directory, "catalogs.pre-cache-v1.json"))
	if err != nil || !bytes.Equal(backup, original) {
		t.Fatal("recovery copy lost", err)
	}
	var disk nativeCatalogDisk
	raw, err := os.ReadFile(filepath.Join(cache, "catalogs.json"))
	if err != nil || json.Unmarshal(raw, &disk) != nil || disk.HongguoApp.DeviceID != "" || disk.HongguoApp.Feeds["short_play"].Offset != 18 {
		t.Fatal("cached identity/cursor separation failed", err)
	}
	for _, name := range []string{"covers-v1", "rankings.json"} {
		if _, err := os.Stat(filepath.Join(cache, name)); err != nil {
			t.Fatal("cache item not moved", name, err)
		}
	}
	engine.downloads.close()
	if err := os.RemoveAll(cache); err != nil {
		t.Fatal(err)
	}
	restarted := newCacheTestEngine(t, directory, cache)
	state = restarted.downloader.hongguoCatalogSnapshot()
	if state.DeviceID != "1001" || !state.Registered || state.HelperDeviceID != "2001" || !state.HelperRegistered {
		t.Fatal("cache clearing lost device identity")
	}
	if len(state.Feeds) != 0 || len(restarted.catalogs) != 0 {
		t.Fatal("cache clearing resurrected stale cursors")
	}
}

func TestNativeCacheMigrationFailurePreservesAndRetries(t *testing.T) {
	directory, cache := t.TempDir(), t.TempDir()
	original := legacyCacheFixture(t, directory, 18)
	blocked := filepath.Join(cache, "catalogs.json")
	if err := os.Mkdir(blocked, 0700); err != nil {
		t.Fatal(err)
	}
	engine := newCacheTestEngine(t, directory, cache)
	if engine.separateCache() {
		t.Fatal("failed migration switched directories")
	}
	kept, err := os.ReadFile(filepath.Join(directory, "catalogs.json"))
	if err != nil || !bytes.Equal(kept, original) {
		t.Fatal("failed migration changed source", err)
	}
	if _, err := os.Stat(filepath.Join(directory, nativeCacheMigrationFile)); !os.IsNotExist(err) {
		t.Fatal("failed migration marked complete")
	}
	engine.downloads.close()
	if err := os.Remove(blocked); err != nil {
		t.Fatal(err)
	}
	legacyCacheFixture(t, directory, 36)
	restarted := newCacheTestEngine(t, directory, cache)
	if !restarted.separateCache() || restarted.downloader.hongguoCatalogSnapshot().Feeds["short_play"].Offset != 36 {
		t.Fatal("retry did not use latest legacy state")
	}
}

func TestNativeCacheSaveFailureDoesNotAdvanceDurableCursor(t *testing.T) {
	directory, cache := t.TempDir(), t.TempDir()
	legacyCacheFixture(t, directory, 18)
	engine := newCacheTestEngine(t, directory, cache)
	path := filepath.Join(cache, "catalogs.json")
	if err := os.Rename(path, path+".saved"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	cursor := engine.hongguoCatalog.Feeds["short_play"]
	cursor.Offset = 36
	engine.hongguoCatalog.Feeds["short_play"] = cursor
	if err := engine.writeCatalogDiskLocked(); err == nil {
		t.Fatal("write failure lost")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path+".saved", path); err != nil {
		t.Fatal(err)
	}
	engine.downloads.close()
	restarted := newCacheTestEngine(t, directory, cache)
	if restarted.downloader.hongguoCatalogSnapshot().Feeds["short_play"].Offset != 18 {
		t.Fatal("restart resumed unsaved cursor")
	}
}

func TestNativeCacheMigrationProtectsIdentityFailureAndOverlap(t *testing.T) {
	t.Run("device write failure", func(t *testing.T) {
		directory, cache := t.TempDir(), t.TempDir()
		original := legacyCacheFixture(t, directory, 18)
		if err := os.Mkdir(filepath.Join(directory, nativeDeviceStateFile), 0700); err != nil {
			t.Fatal(err)
		}
		engine := newCacheTestEngine(t, directory, cache)
		kept, err := os.ReadFile(filepath.Join(directory, "catalogs.json"))
		if engine.separateCache() || err != nil || !bytes.Equal(kept, original) {
			t.Fatal("identity failure lost source", err)
		}
	})
	t.Run("overlap", func(t *testing.T) {
		directory := t.TempDir()
		for _, cache := range []string{filepath.Join(directory, "store"), filepath.Join(directory, "downloads"), filepath.Dir(directory)} {
			if engine, err := newNativeEngine(directory, "", cache); err == nil {
				engine.downloads.close()
				t.Fatal("unsafe cache overlap accepted", cache)
			}
		}
		engine := newCacheTestEngine(t, directory, filepath.Join(directory, "cache"))
		if !engine.separateCache() {
			t.Fatal("portable cache was not separated")
		}
	})
	t.Run("missing device file after migration", func(t *testing.T) {
		directory, cache := t.TempDir(), t.TempDir()
		engine := newCacheTestEngine(t, directory, cache)
		engine.downloads.close()
		if err := os.Remove(filepath.Join(directory, nativeDeviceStateFile)); err != nil {
			t.Fatal(err)
		}
		if restarted, err := newNativeEngine(directory, "", cache); err == nil {
			restarted.downloads.close()
			t.Fatal("missing device state silently replaced")
		}
	})
}

func TestNativeCacheInterruptedMigrationRefreshesIntermediateFiles(t *testing.T) {
	directory, cache := t.TempDir(), t.TempDir()
	legacyCacheFixture(t, directory, 18)
	engine := &nativeEngine{directory: directory, cacheDirectory: directory}
	blocked := filepath.Join(directory, "blocked-marker")
	if err := os.Mkdir(blocked, 0700); err != nil {
		t.Fatal(err)
	}
	if err := engine.migrateCacheFiles(cache, blocked); err == nil {
		t.Fatal("marker failure was ignored")
	}
	legacyCacheFixture(t, directory, 36)
	engine = newCacheTestEngine(t, directory, cache)
	if engine.downloader.hongguoCatalogSnapshot().Feeds["short_play"].Offset != 36 {
		t.Fatal("migration retry reused stale intermediate cache")
	}
}

func TestNativeCacheUnavailableAfterMigrationDoesNotFallBack(t *testing.T) {
	directory, cache := t.TempDir(), filepath.Join(t.TempDir(), "cache")
	legacyCacheFixture(t, directory, 18)
	engine := newCacheTestEngine(t, directory, cache)
	engine.downloads.close()
	if err := os.RemoveAll(cache); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cache, []byte("occupied"), 0600); err != nil {
		t.Fatal(err)
	}
	if restarted, err := newNativeEngine(directory, "", cache); err == nil {
		restarted.downloads.close()
		t.Fatal("unavailable migrated cache silently changed identity")
	}
	if _, err := os.Stat(filepath.Join(directory, nativeDeviceStateFile)); err != nil {
		t.Fatal("device state removed", err)
	}
}

func TestNativeCacheOldInitializerUsesCommittedLayout(t *testing.T) {
	directory, cache := t.TempDir(), t.TempDir()
	legacyCacheFixture(t, directory, 18)
	engine := newCacheTestEngine(t, directory, cache)
	engine.downloads.close()
	restarted, err := newNativeEngine(directory, "")
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.downloads.close()
	if !restarted.separateCache() || restarted.downloader.hongguoCatalogSnapshot().DeviceID != "1001" ||
		restarted.downloader.hongguoCatalogSnapshot().Feeds["short_play"].Offset != 18 {
		t.Fatal("legacy initializer ignored committed cache layout")
	}
}

func TestNativeCacheDeviceChangeDoesNotReuseOldCursor(t *testing.T) {
	directory, cache := t.TempDir(), t.TempDir()
	legacyCacheFixture(t, directory, 18)
	engine := newCacheTestEngine(t, directory, cache)
	path := engine.catalogCachePath()
	if err := os.Rename(path, path+".saved"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	engine.hongguoCatalog.DeviceID, engine.hongguoCatalog.InstallID = "3001", "3002"
	if err := engine.writeCatalogDiskLocked(); err == nil {
		t.Fatal("catalog write failure ignored")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path+".saved", path); err != nil {
		t.Fatal(err)
	}
	engine.downloads.close()
	restarted := newCacheTestEngine(t, directory, cache)
	state := restarted.downloader.hongguoCatalogSnapshot()
	if state.DeviceID != "3001" || len(state.Feeds) != 0 || len(restarted.catalogs[sourceHongguo]) != 0 {
		t.Fatal("old cursor attached to new device")
	}
}

func TestNativeCacheForeignDirectoryDoesNotAttachOtherIdentity(t *testing.T) {
	directory, cache, foreign := t.TempDir(), t.TempDir(), t.TempDir()
	legacyCacheFixture(t, directory, 18)
	engine := newCacheTestEngine(t, directory, cache)
	engine.downloads.close()
	disk := nativeCatalogDisk{Version: 3, DeviceIdentity: "other-device",
		HongguoApp: &hongguoCatalogState{Version: 1, Feeds: map[string]hongguoCatalogCursor{"short_play": {Offset: 90, Initialized: true}}},
		Catalogs: map[string][]nativeDrama{
			sourceHongguo: {{ID: "hongguo:999", Source: sourceHongguo}},
			"fanguo":      {{ID: "fanguo:1", Source: "fanguo"}},
		},
		States: map[string]nativeCatalogState{sourceHongguo: {Page: 5}},
	}
	body, err := json.Marshal(disk)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(foreign, "catalogs.json"), body, 0600); err != nil {
		t.Fatal(err)
	}
	restarted := newCacheTestEngine(t, directory, foreign)
	state := restarted.downloader.hongguoCatalogSnapshot()
	if state.DeviceID != "1001" || len(state.Feeds) != 0 || len(restarted.catalogs[sourceHongguo]) != 0 ||
		len(restarted.catalogs["fanguo"]) != 1 || restarted.catalogStates[sourceHongguo].Page != 0 {
		t.Fatal("foreign device cache restored or unrelated catalog dropped")
	}
}

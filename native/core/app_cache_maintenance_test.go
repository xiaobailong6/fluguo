package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func cacheMaintenanceFixture(t *testing.T) *nativeEngine {
	t.Helper()
	directory, cache := t.TempDir(), t.TempDir()
	legacyCacheFixture(t, directory, 18)
	engine := newCacheTestEngine(t, directory, cache)
	for path, body := range map[string]string{
		filepath.Join(cache, "rankings.json"):                                                                      "{}",
		filepath.Join(cache, "covers-v1", strings.Repeat("a", 64)+".img"):                                          "image",
		filepath.Join(cache, "covers-v1", "compatible-v1", strings.Repeat("a", 64)+"-1700000000000000-5.jpg"):      "jpeg",
		filepath.Join(cache, "covers-v1", "compatible-v1", strings.Repeat("a", 64)+"-1700000000000000-5.jpg.part"): "converting",
		filepath.Join(cache, "covers-v1", "compatible-v1", "user.jpg"):                                             "keep jpeg",
		filepath.Join(cache, "covers-v1", ".decode-in-use.hevc"):                                                   "decoding",
		filepath.Join(cache, "covers-v1", "user-note"):                                                             "keep",
		filepath.Join(cache, "store.json"):                                                                         "user data",
		filepath.Join(directory, "accounts.json"):                                                                  "account data",
		filepath.Join(engine.downloads.root, "movie.mp4"):                                                          "downloaded video",
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return engine
}

func TestNativeCacheStatsClearAndRebuild(t *testing.T) {
	engine := cacheMaintenanceFixture(t)
	before, err := engine.storage()
	if err != nil || before.CacheWarning != "" || before.CacheFiles != 4 || before.CacheBytes <= 11 {
		t.Fatal(before, err)
	}
	devicePath := filepath.Join(engine.directory, nativeDeviceStateFile)
	identity, _ := os.ReadFile(devicePath)
	backupPath := filepath.Join(engine.directory, "catalogs.pre-cache-v1.json")
	backup, _ := os.ReadFile(backupPath)
	engine.seasons = map[string]nativeSeasonCacheEntry{"101": {expires: time.Now().Add(time.Hour)}}
	engine.recommendations = map[string]nativeRecommendationState{"short_play": {Page: 1}}
	engine.categoryOptions = map[string][]nativeCategory{sourceHongguo: {{ID: "x"}}}
	engine.downloader.rankings.pages = map[string]rankingPage{"old": {Page: 1}}
	engine.covers.entries = map[string]nativeCoverEntry{"old": {size: 5}}
	engine.covers.size = 5
	playback, cancel := context.WithCancel(context.Background())
	defer cancel()
	engine.playbackCancel = cancel
	downloadCtx, downloadCancel := context.WithCancel(context.Background())
	defer downloadCancel()
	engine.downloads.mu.Lock()
	engine.downloads.jobs["active-fixture"] = &nativeDownloadRecord{nativeDownloadJob: nativeDownloadJob{ID: "active-fixture", State: "downloading"}}
	engine.downloads.active["active-fixture"] = downloadCancel
	engine.downloads.mu.Unlock()
	result, err := engine.clearCache(context.Background())
	if err != nil || result["clearedBytes"] != before.CacheBytes || result["remainingBytes"] != 0 {
		t.Fatal(result, err)
	}
	if playback.Err() != nil {
		t.Fatal("cache clearing canceled playback")
	}
	engine.downloads.mu.Lock()
	untouched := engine.downloads.jobs["active-fixture"].State == "downloading"
	delete(engine.downloads.jobs, "active-fixture")
	delete(engine.downloads.active, "active-fixture")
	engine.downloads.mu.Unlock()
	if downloadCtx.Err() != nil || !untouched {
		t.Fatal("cache clearing paused or canceled download")
	}
	after, err := engine.storage()
	if err != nil || after.CacheBytes != 0 || after.CacheFiles != 0 || after.Bytes != before.Bytes || after.Files != before.Files {
		t.Fatal(after, err)
	}
	encoded, _ := json.Marshal(after)
	var fields map[string]any
	if err := json.Unmarshal(encoded, &fields); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"bytes", "free", "files", "cacheBytes", "cacheFiles", "cacheDirectory", "cacheFree"} {
		if _, found := fields[key]; !found {
			t.Fatal("missing IPC storage field", key)
		}
	}
	for path, want := range map[string][]byte{
		devicePath: identity,
		backupPath: backup,
		filepath.Join(engine.cacheRoot(), "store.json"):                                                                         []byte("user data"),
		filepath.Join(engine.cacheRoot(), "covers-v1", ".decode-in-use.hevc"):                                                   []byte("decoding"),
		filepath.Join(engine.cacheRoot(), "covers-v1", "compatible-v1", strings.Repeat("a", 64)+"-1700000000000000-5.jpg.part"): []byte("converting"),
		filepath.Join(engine.cacheRoot(), "covers-v1", "compatible-v1", "user.jpg"):                                             []byte("keep jpeg"),
	} {
		got, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(got, want) {
			t.Fatal("user data changed", path, err)
		}
	}
	state := engine.downloader.hongguoCatalogSnapshot()
	if state.DeviceID != "1001" || state.HelperDeviceID != "2001" || len(state.Feeds) != 0 || len(engine.catalogs) != 0 || len(engine.catalogStates) != 0 || len(engine.categoryOptions) != 0 || len(engine.recommendations) != 0 || len(engine.seasons) != 0 || len(engine.downloader.rankings.pages) != 0 || len(engine.covers.entries) != 0 {
		t.Fatal("memory caches or identity incorrect")
	}
	resultCache := nativeCatalogResult{Items: []nativeDrama{{ID: "hongguo:901", Source: sourceHongguo, Title: "rebuilt"}}, Page: 1, HasMore: true, hongguo: state}
	if err := engine.saveCatalogCache(sourceHongguo, &resultCache); err != nil {
		t.Fatal(err)
	}
	engine.downloads.close()
	restarted := newCacheTestEngine(t, engine.directory, engine.cacheRoot())
	if len(restarted.catalogs[sourceHongguo]) != 1 || restarted.catalogs[sourceHongguo][0].ID != "hongguo:901" || restarted.downloader.hongguoCatalogSnapshot().DeviceID != "1001" {
		t.Fatal("cache rebuild failed")
	}
}

func TestNativeCacheClearRefusesUnsafeStateAndLinks(t *testing.T) {
	for _, kind := range []string{"unmigrated", "device-missing", "device-corrupt", "device-invalid", "marker-invalid", "download-overlap", "catalog-directory", "cover-link", "compatible-link", "compatible-file-link", "file-link", "root-link"} {
		t.Run(kind, func(t *testing.T) {
			engine := cacheMaintenanceFixture(t)
			outside := filepath.Join(t.TempDir(), "valuable")
			if err := os.WriteFile(outside, []byte("keep"), 0600); err != nil {
				t.Fatal(err)
			}
			root := engine.cacheRoot()
			switch kind {
			case "unmigrated":
				engine.cacheDirectory = engine.directory
			case "device-missing":
				if err := os.Remove(filepath.Join(engine.directory, nativeDeviceStateFile)); err != nil {
					t.Fatal(err)
				}
			case "device-corrupt":
				if err := os.WriteFile(filepath.Join(engine.directory, nativeDeviceStateFile), []byte("broken"), 0600); err != nil {
					t.Fatal(err)
				}
			case "device-invalid":
				if err := os.WriteFile(filepath.Join(engine.directory, nativeDeviceStateFile), []byte(`{"version":1,"hongguo":{"version":1,"deviceId":"0","installId":"0"}}`), 0600); err != nil {
					t.Fatal(err)
				}
			case "marker-invalid":
				if err := os.WriteFile(filepath.Join(engine.directory, nativeCacheMigrationFile), []byte("{}"), 0600); err != nil {
					t.Fatal(err)
				}
			case "download-overlap":
				engine.downloads.root = root
			case "catalog-directory":
				if err := os.Remove(filepath.Join(root, "catalogs.json")); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(filepath.Join(root, "catalogs.json"), 0700); err != nil {
					t.Fatal(err)
				}
			case "cover-link", "compatible-link", "compatible-file-link", "file-link", "root-link":
				path := filepath.Join(root, "covers-v1", "outside")
				target := outside
				if kind == "compatible-link" {
					path = filepath.Join(root, "covers-v1", "compatible-v1")
					if err := os.RemoveAll(path); err != nil {
						t.Fatal(err)
					}
					target = filepath.Dir(outside)
				} else if kind == "compatible-file-link" {
					path = filepath.Join(root, "covers-v1", "compatible-v1", strings.Repeat("b", 64)+"-1700000000000000-5.jpg")
				}
				if kind == "file-link" {
					path = filepath.Join(root, "rankings.json")
					if err := os.Remove(path); err != nil {
						t.Fatal(err)
					}
				} else if kind == "root-link" {
					path = filepath.Join(t.TempDir(), "linked-cache")
					target = root
					engine.cacheDirectory = path
				}
				if err := os.Symlink(target, path); err != nil {
					t.Skip("symlink permission unavailable", err)
				}
			}
			if result, err := engine.clearCache(context.Background()); err == nil || result != nil {
				t.Fatal("unsafe clear succeeded", result, err)
			}
			info, err := engine.storage()
			if err == nil && info.CacheWarning == "" {
				t.Fatal("unsafe statistics omitted warning", info)
			}
			if body, err := os.ReadFile(outside); err != nil || string(body) != "keep" {
				t.Fatal("external file touched", err)
			}
			if len(engine.catalogs) == 0 {
				t.Fatal("failed preflight erased memory")
			}
		})
	}
}

func TestNativeCacheClearPartialFailureReportsError(t *testing.T) {
	engine := cacheMaintenanceFixture(t)
	identity, _ := os.ReadFile(filepath.Join(engine.directory, nativeDeviceStateFile))
	calls := 0
	result, err := engine.clearCacheFiles(context.Background(), func(path string) error {
		calls++
		if calls == 2 {
			return errors.New("synthetic permission failure")
		}
		return os.Remove(path)
	})
	if err == nil || result != nil || !strings.Contains(err.Error(), "未完成") {
		t.Fatal("partial failure reported success", result, err)
	}
	if _, err := os.Stat(filepath.Join(engine.cacheRoot(), "rankings.json")); err != nil {
		t.Fatal("remaining cache removed", err)
	}
	if current, _ := os.ReadFile(filepath.Join(engine.directory, nativeDeviceStateFile)); !bytes.Equal(identity, current) {
		t.Fatal("identity changed on failure")
	}
	if _, err := engine.clearCache(context.Background()); err != nil {
		t.Fatal("clear retry failed", err)
	}
}

func TestNativeCacheMaintenanceWaitsForOldReadAndBlocksNewRead(t *testing.T) {
	engine := cacheMaintenanceFixture(t)
	_, finish, err := engine.beginCacheRead(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := engine.clearCache(ctx); done <- err }()
	deadline := time.Now().Add(time.Second)
	for engine.cacheClearPending.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if engine.cacheClearPending.Load() == 0 {
		finish()
		t.Fatal("clear did not start")
	}
	if _, release, err := engine.beginCacheRead(context.Background()); err == nil {
		release()
		finish()
		t.Fatal("new cache read admitted during maintenance")
	}
	// 模拟旧目录请求最后落盘：清理必须等它提交后再删除。
	if err := engine.saveCatalogCache(sourceHongguo, &nativeCatalogResult{Items: []nativeDrama{{ID: "hongguo:old"}}, Page: 1}); err != nil {
		finish()
		t.Fatal(err)
	}
	finish()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if len(engine.catalogs) != 0 {
		t.Fatal("old read repopulated cache")
	}
	if _, err := os.Stat(engine.catalogCachePath()); !os.IsNotExist(err) {
		t.Fatal("old disk cache survived", err)
	}
	_, release, err := engine.beginCacheRead(context.Background())
	if err != nil {
		t.Fatal("new reads cannot rebuild", err)
	}
	release()
}

func TestNativeCacheClearFencesDetachedCover(t *testing.T) {
	engine := cacheMaintenanceFixture(t)
	started, release := make(chan struct{}), make(chan struct{})
	engine.downloader.client = &http.Client{Transport: sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		close(started)
		<-release
		return sourceFixtureResponse(request, 200, "\xff\xd8\xfffixture"), nil
	})}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := engine.covers.loadAddress(ctx, nativeDrama{ID: "hongguo:101", Source: sourceHongguo, Cover: "https://fixture.invalid/cover"}, false)
		done <- err
	}()
	<-started
	engine.covers.mu.Lock()
	var call *nativeCoverCall
	for _, pending := range engine.covers.pending {
		call = pending
	}
	engine.covers.mu.Unlock()
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		close(release)
		t.Fatal(err)
	}
	if _, err := engine.clearCache(context.Background()); err != nil {
		close(release)
		t.Fatal(err)
	}
	close(release)
	select {
	case <-call.done:
	case <-time.After(time.Second):
		t.Fatal("detached cover did not finish")
	}
	if !errors.Is(call.err, context.Canceled) || len(engine.covers.entries) != 0 {
		t.Fatal("old cover repopulated cache", call.err)
	}
	info, err := engine.storage()
	if err != nil || info.CacheBytes != 0 {
		t.Fatal("old cover reached disk", info, err)
	}
}

func TestNativeCacheClearCancellationPreservesData(t *testing.T) {
	engine := cacheMaintenanceFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if result, err := engine.clearCache(ctx); !errors.Is(err, context.Canceled) || result != nil {
		t.Fatal(result, err)
	}
	if _, err := os.Stat(engine.catalogCachePath()); err != nil {
		t.Fatal("cancelled clear deleted cache", err)
	}
}

func TestNativeCacheClearDrainsCatalogAndAllowsFreshRebuild(t *testing.T) {
	engine := cacheMaintenanceFixture(t)
	started, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	engine.downloader.limiter = newRequestLimiter(3, 0)
	engine.downloader.cfg.Retries = 1
	engine.downloader.client.Transport = sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		if calls.Add(1) == 1 {
			close(started)
			select {
			case <-release:
			case <-request.Context().Done():
				return nil, request.Context().Err()
			}
		}
		return sourceFixtureResponse(request, 200, `{"code":0,"data":{"video_info":[{"series_id":"808","series_title":"重建目录"}],"has_more":false,"offset":1}}`), nil
	})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	input := nativeInput{Source: sourceHongguo, Category: "tag:cate_96", Page: 1, Force: true}
	readDone := make(chan error, 1)
	go func() { _, err := engine.nativeCatalog(ctx, input); readDone <- err }()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	clearDone := make(chan error, 1)
	go func() { _, err := engine.clearCache(ctx); clearDone <- err }()
	for engine.cacheClearPending.Load() == 0 && ctx.Err() == nil {
		time.Sleep(time.Millisecond)
	}
	close(release)
	if err := <-readDone; err != nil {
		t.Fatal(err)
	}
	if err := <-clearDone; err != nil {
		t.Fatal(err)
	}
	if len(engine.catalogs) != 0 || len(engine.downloader.hongguoClient().tagCursors) != 0 {
		t.Fatal("old request restored cleared data")
	}
	result, err := engine.nativeCatalog(ctx, input)
	if err != nil || len(result.Items) != 1 || calls.Load() != 2 {
		t.Fatal("fresh catalog did not rebuild", result, err)
	}
}

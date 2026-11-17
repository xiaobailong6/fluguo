package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const categoryFixtureHTML = `<a href="/videos?category=2">合成分类</a>`

// 所有请求均经过内存 transport；测试不访问真实站源、媒体或 DNS。
func categoryRevisionFixture(t *testing.T, transport sourceFixtureTransport) *nativeEngine {
	t.Helper()
	engine := sourceFixtureEngine(t, transport)
	engine.downloader.cfg.HuangguoVideoURL = "https://categories.invalid"
	return engine
}

func saveCategoryFixture(t *testing.T, engine *nativeEngine, disk nativeCatalogDisk) {
	t.Helper()
	body, err := json.Marshal(disk)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(engine.catalogCachePath(), body, 0600); err != nil {
		t.Fatal(err)
	}
	engine.loadCatalogCache()
}

func readCategoryFixture(t *testing.T, engine *nativeEngine) nativeCatalogDisk {
	t.Helper()
	body, err := os.ReadFile(engine.catalogCachePath())
	if err != nil {
		t.Fatal(err)
	}
	var disk nativeCatalogDisk
	if err := json.Unmarshal(body, &disk); err != nil {
		t.Fatal(err)
	}
	return disk
}

func TestNativeCategoryRevisionLegacyUpgradeAndRestart(t *testing.T) {
	for _, version := range []int{2, 3} {
		t.Run(string(rune('0'+version)), func(t *testing.T) {
			calls := 0
			engine := categoryRevisionFixture(t, func(request *http.Request) (*http.Response, error) {
				calls++
				return sourceFixtureResponse(request, 200, categoryFixtureHTML), nil
			})
			old := []nativeCategory{{Name: "全部"}, {ID: "1", Name: "旧分类"}}
			saveCategoryFixture(t, engine, nativeCatalogDisk{Version: version,
				Categories: map[string][]nativeCategory{sourceHuangguoVideo: old},
				Catalogs:   map[string][]nativeDrama{sourceHuangguoVideo: {{ID: "huangguovideo:historic", Title: "保留"}}}})
			got, err := engine.nativeCategories(context.Background(), sourceHuangguoVideo, false)
			if err != nil || calls != 1 || len(got) != 2 || got[1].ID != "2" {
				t.Fatal("unversioned cache did not refresh", got, calls, err)
			}
			disk := readCategoryFixture(t, engine)
			if disk.Version != 3 || disk.CategoryRevisions[sourceHuangguoVideo] != nativeCategoryRevision(sourceHuangguoVideo) || disk.Catalogs[sourceHuangguoVideo][0].ID != "huangguovideo:historic" {
				t.Fatal("revision not persisted or historic ID changed", disk)
			}
			// 重新创建内存状态并从磁盘读取，命中时不会调用 transport。
			restarted := &nativeEngine{directory: engine.directory, downloader: engine.downloader}
			restarted.loadCatalogCache()
			again, err := restarted.nativeCategories(context.Background(), sourceHuangguoVideo, false)
			if err != nil || calls != 1 || !reflect.DeepEqual(got, again) {
				t.Fatal("restart did not hit persisted revision", again, calls, err)
			}
		})
	}
}

func TestNativeCategoryRevisionIsSourceLocalAndForceStillRefreshes(t *testing.T) {
	calls := 0
	engine := categoryRevisionFixture(t, func(request *http.Request) (*http.Response, error) {
		calls++
		if request.URL.Path != "/videos" {
			t.Error("another source fetched", request.URL)
		}
		return sourceFixtureResponse(request, 200, categoryFixtureHTML), nil
	})
	other := []nativeCategory{{Name: "全部"}, {ID: "kept", Name: "其他源"}}
	saveCategoryFixture(t, engine, nativeCatalogDisk{Version: 3,
		Categories: map[string][]nativeCategory{
			sourceHuangguoVideo: {{Name: "全部"}, {ID: "1", Name: "旧分类"}}, sourceCloudFront: other,
		},
		CategoryRevisions: map[string]string{sourceHuangguoVideo: "previous-revision", sourceCloudFront: nativeCategoryRevision(sourceCloudFront)},
	})
	for _, force := range []bool{false, false, true} {
		if _, err := engine.nativeCategories(context.Background(), sourceHuangguoVideo, force); err != nil {
			t.Fatal(err)
		}
	}
	got, err := engine.nativeCategories(context.Background(), sourceCloudFront, false)
	disk := readCategoryFixture(t, engine)
	if err != nil || calls != 2 || !reflect.DeepEqual(got, other) || !reflect.DeepEqual(disk.Categories[sourceCloudFront], other) || disk.CategoryRevisions[sourceCloudFront] != nativeCategoryRevision(sourceCloudFront) {
		t.Fatal("source-local invalidation or force failed", calls, got, err)
	}
}

func TestNativeCategoryRevisionFailureKeepsFallbackAndRetries(t *testing.T) {
	for _, body := range []string{"network-failure", "<html>no category links</html>"} {
		t.Run(body, func(t *testing.T) {
			calls := 0
			engine := categoryRevisionFixture(t, func(request *http.Request) (*http.Response, error) {
				calls++
				if body == "network-failure" {
					return nil, errors.New("offline fixture")
				}
				return sourceFixtureResponse(request, 200, body), nil
			})
			for _, revision := range []string{"", "previous-revision"} {
				saveCategoryFixture(t, engine, nativeCatalogDisk{Version: 3,
					Categories: map[string][]nativeCategory{sourceHuangguoVideo: {
						{Name: "全部"}, {ID: "7", Name: "保留"}, {ID: "../invalid", Name: "删除"}, {ID: "7", Name: "重复"}, {ID: "9", Name: " "},
					}}, CategoryRevisions: map[string]string{sourceHuangguoVideo: revision}})
				before, _ := os.ReadFile(engine.catalogCachePath())
				for range 2 {
					previousCalls := calls
					got, err := engine.nativeCategories(context.Background(), sourceHuangguoVideo, false)
					if err != nil || calls <= previousCalls || !reflect.DeepEqual(got, []nativeCategory{{Name: "全部"}, {ID: "7", Name: "保留"}}) {
						t.Fatal("failed refresh lost valid fallback or stopped retrying", got, err)
					}
				}
				after, _ := os.ReadFile(engine.catalogCachePath())
				if !bytes.Equal(before, after) || engine.categoryRevisions[sourceHuangguoVideo] != revision {
					t.Fatal("failed fetch upgraded revision or rewrote disk")
				}
			}
			engine.categoryOptions = nil
			got, err := engine.nativeCategories(context.Background(), sourceHuangguoVideo, true)
			if err != nil || !reflect.DeepEqual(got, []nativeCategory{{Name: "全部"}}) {
				t.Fatal("base fallback missing", got, err)
			}
		})
	}
}

func TestNativeCategoryRevisionDiskFailureDoesNotUpgrade(t *testing.T) {
	engine := categoryRevisionFixture(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, categoryFixtureHTML), nil
	})
	// 用同名目录制造确定性的落盘失败，不依赖宿主权限设置。
	if err := os.Mkdir(engine.catalogCachePath(), 0700); err != nil {
		t.Fatal(err)
	}
	got, err := engine.nativeCategories(context.Background(), sourceHuangguoVideo, false)
	if err != nil || len(got) != 2 || engine.categoryRevisions[sourceHuangguoVideo] != "" || engine.catalogSaveError == nil {
		t.Fatal("disk failure was marked as an upgrade", got, err)
	}
}

func hongguoCategoryBaseFixture() []nativeCategory {
	base := []nativeCategory{{Name: "全部"}}
	for _, genre := range hongguoAppGenres {
		base = append(base, nativeCategory{ID: genre.key, Name: genre.name})
	}
	return base
}

func TestNativeCategoryRevisionHongguoRequiresGenresAndTags(t *testing.T) {
	base := hongguoCategoryBaseFixture()
	for _, kind := range []string{"tags-without-genres", "genres-without-tags", "duplicates-and-invalid"} {
		t.Run(kind, func(t *testing.T) {
			calls, fail := 0, true
			engine := categoryRevisionFixture(t, func(request *http.Request) (*http.Response, error) {
				calls++
				if request.URL.Path != hongguoTagLandingPath {
					t.Error("unexpected request", request.URL)
				}
				if fail {
					return nil, errors.New("offline fixture")
				}
				return sourceFixtureResponse(request, 200, `{"code":0,"data":{"selector":{"rows":[{"type":"dialog_bottom","items":[{"selector_item_id":"cate_96","show_name":"甜宠"}]}]}}}`), nil
			})
			old := []nativeCategory{{Name: "全部"}, {ID: "tag:cate_1", Name: "旧题材"}, {ID: "tag:cate_2", Name: "旧题材二"}, {ID: "tag:cate_3", Name: "旧题材三"}, {ID: "tag:cate_4", Name: "旧题材四"}}
			if kind == "genres-without-tags" {
				old = base
			} else if kind == "duplicates-and-invalid" {
				old = append(append([]nativeCategory{}, base...), nativeCategory{ID: "short_play", Name: "重复"}, nativeCategory{ID: "tag:cate_1", Name: "旧题材"}, nativeCategory{ID: "tag:bad", Name: "无效"})
			}
			saveCategoryFixture(t, engine, nativeCatalogDisk{Version: 3,
				Categories: map[string][]nativeCategory{sourceHongguo: old}, CategoryRevisions: map[string]string{sourceHongguo: nativeCategoryRevision(sourceHongguo)}})
			got, err := engine.nativeCategories(context.Background(), sourceHongguo, false)
			if err != nil || calls == 0 || len(got) < len(base) || !reflect.DeepEqual(got[:len(base)], base) {
				t.Fatal("length-only cache accepted or base genres lost", got, calls, err)
			}
			seen := map[string]bool{}
			for _, entry := range got {
				if seen[entry.ID] || !validNativeCategory(sourceHongguo, entry.ID) {
					t.Fatal("duplicate/invalid fallback", got)
				}
				seen[entry.ID] = true
			}
			if !reflect.DeepEqual(engine.categoryOptions[sourceHongguo], old) {
				t.Fatal("failed fetch overwrote old cache with repaired fallback")
			}
			fail = false
			want := append(append([]nativeCategory{}, base...), nativeCategory{ID: "tag:cate_96", Name: "甜宠"})
			got, err = engine.nativeCategories(context.Background(), sourceHongguo, false)
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatal("recovery failed", got, err)
			}
			previousCalls := calls
			if _, err = engine.nativeCategories(context.Background(), sourceHongguo, false); err != nil || calls != previousCalls {
				t.Fatal("complete cache not reused", calls, err)
			}
			if _, err = engine.nativeCategories(context.Background(), sourceHongguo, true); err != nil || calls <= previousCalls {
				t.Fatal("Hongguo force ignored", calls, err)
			}
		})
	}
}

func TestNativeCategoryRevisionClearWaitsForFetchAndRevokesMetadata(t *testing.T) {
	engine := cacheMaintenanceFixture(t)
	engine.downloader.cfg.HuangguoVideoURL = "https://categories.invalid"
	engine.downloader.cfg.Retries = 1
	engine.downloader.limiter = newRequestLimiter(3, 0)
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	var calls atomic.Int32
	engine.downloader.client.Transport = sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		if calls.Add(1) == 1 {
			close(started)
			select {
			case <-release:
			case <-request.Context().Done():
				return nil, request.Context().Err()
			}
		}
		return sourceFixtureResponse(request, 200, categoryFixtureHTML), nil
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	defer once.Do(func() { close(release) })
	fetched := make(chan error, 1)
	go func() { _, err := engine.nativeCategories(ctx, sourceHuangguoVideo, false); fetched <- err }()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("category request did not start")
	}
	cleared := make(chan error, 1)
	go func() { _, err := engine.clearCache(ctx); cleared <- err }()
	for engine.cacheClearPending.Load() == 0 && ctx.Err() == nil {
		time.Sleep(time.Millisecond)
	}
	if ctx.Err() != nil {
		t.Fatal("clear did not start")
	}
	if _, err := engine.nativeCategories(ctx, sourceHuangguoVideo, false); err == nil {
		t.Fatal("new category read bypassed maintenance fence")
	}
	select {
	case err := <-cleared:
		t.Fatal("clear did not wait for fetch", err)
	default:
	}
	once.Do(func() { close(release) })
	if err := <-fetched; err != nil {
		t.Fatal(err)
	}
	if err := <-cleared; err != nil {
		t.Fatal(err)
	}
	if len(engine.categoryRevisions) != 0 || len(engine.categoryOptions) != 0 {
		t.Fatal("old fetch repopulated categories/revisions after clear")
	}
	if _, err := os.Stat(engine.catalogCachePath()); !os.IsNotExist(err) {
		t.Fatal("cleared revisions survived on disk", err)
	}
	if _, err := engine.nativeCategories(ctx, sourceHuangguoVideo, false); err != nil || calls.Load() != 2 {
		t.Fatal("clear did not invalidate revision", calls.Load(), err)
	}
	for _, path := range []string{filepath.Join(engine.directory, "accounts.json"), filepath.Join(engine.downloads.root, "movie.mp4")} {
		if _, err := os.Stat(path); err != nil {
			t.Fatal("user data removed", path, err)
		}
	}
}

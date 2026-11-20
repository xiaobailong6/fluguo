package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"sync"
	"testing"
	"time"
)

func TestNativeCatalogSnapshotOwnsNestedData(t *testing.T) {
	vip := true
	engine := &nativeEngine{
		catalogs:          map[string][]nativeDrama{sourceHongguo: {{ID: "1", VIP: &vip, Tags: []string{"old"}}}},
		catalogStates:     map[string]nativeCatalogState{sourceHongguo: {Page: 1}},
		categoryOptions:   map[string][]nativeCategory{sourceHongguo: {{ID: "old"}}},
		categoryRevisions: map[string]string{sourceHongguo: "old"},
		hongguoCatalog:    &hongguoCatalogState{Feeds: map[string]hongguoCatalogCursor{"old": {Offset: 18}}},
		recommendations:   map[string]nativeRecommendationState{"old": {Query: hongguoRecommendationQuery{Seen: []string{"old"}}}},
	}
	engine.mu.Lock()
	snapshot := engine.catalogSnapshotLocked()
	engine.catalogs[sourceHongguo][0].Tags[0] = "new"
	*engine.catalogs[sourceHongguo][0].VIP = false
	engine.catalogs[sourceHongguo][0].Title = "new"
	engine.catalogStates[sourceHongguo] = nativeCatalogState{Page: 2}
	engine.categoryOptions[sourceHongguo][0].ID = "new"
	engine.categoryRevisions[sourceHongguo] = "new"
	engine.hongguoCatalog.Feeds["old"] = hongguoCatalogCursor{Offset: 36}
	engine.recommendations["old"].Query.Seen[0] = "new"
	engine.mu.Unlock()
	if snapshot.Catalogs[sourceHongguo][0].Tags[0] != "old" || !*snapshot.Catalogs[sourceHongguo][0].VIP || snapshot.Catalogs[sourceHongguo][0].Title != "" || snapshot.States[sourceHongguo].Page != 1 || snapshot.Categories[sourceHongguo][0].ID != "old" || snapshot.CategoryRevisions[sourceHongguo] != "old" || snapshot.HongguoApp.Feeds["old"].Offset != 18 || snapshot.Recommendations["old"].Query.Seen[0] != "old" {
		t.Fatal("snapshot retained mutable references")
	}
}

func TestNativeCatalogSerialWritesReleaseEngineLockAndClearFence(t *testing.T) {
	engine := cacheMaintenanceFixture(t)
	engine.rememberCategories(sourceHongguo, []nativeCategory{{ID: "before-clear"}})
	if len(engine.catalogDurableRevisions) == 0 {
		t.Fatal("missing initial durable revision")
	}
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	var writes []nativeCatalogDisk
	engine.catalogWriteFile = func(path string, body []byte) error {
		var disk nativeCatalogDisk
		if err := json.Unmarshal(body, &disk); err != nil {
			return err
		}
		writes = append(writes, disk)
		if len(writes) == 1 {
			close(entered)
			<-release
		}
		return writeNativeCacheFile(path, body)
	}
	save := func(title string) <-chan error {
		done := make(chan error, 1)
		_, finish, err := engine.beginCacheRead(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		go func() {
			defer finish()
			done <- engine.saveCatalogCache(sourceHongguo, &nativeCatalogResult{Items: []nativeDrama{{ID: "hongguo:1", Source: sourceHongguo, Title: title}}, Page: 1})
		}()
		return done
	}
	first := save("old")
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("writer did not start")
	}
	read := make(chan nativeCatalogResult, 1)
	go func() { read <- engine.nativeCached(sourceHongguo) }()
	select {
	case result := <-read:
		if result.Items[0].Title != "old" {
			t.Fatal(result)
		}
	case <-time.After(time.Second):
		t.Fatal("disk I/O held engine.mu")
	}
	second := save("new")
	deadline := time.Now().Add(3 * time.Second)
	for engine.nativeCached(sourceHongguo).Items[0].Title != "new" && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if engine.nativeCached(sourceHongguo).Items[0].Title != "new" {
		t.Fatal("second mutation blocked on disk")
	}
	cleared := make(chan error, 1)
	go func() { _, err := engine.clearCache(context.Background()); cleared <- err }()
	for engine.cacheClearPending.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if _, finish, err := engine.beginCacheRead(context.Background()); err == nil {
		finish()
		t.Fatal("new reader passed clear fence")
	}
	once.Do(func() { close(release) })
	for _, done := range []<-chan error{first, second, cleared} {
		select {
		case err := <-done:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("write/clear deadlocked")
		}
	}
	if len(writes) != 2 || writes[0].Catalogs[sourceHongguo][0].Title != "old" || writes[1].Catalogs[sourceHongguo][0].Title != "new" {
		t.Fatal("writes committed out of order")
	}
	if _, err := os.Stat(engine.catalogCachePath()); !os.IsNotExist(err) {
		t.Fatal("clear resurrected disk", err)
	}
	if len(engine.nativeCached(sourceHongguo).Items) != 0 {
		t.Fatal("clear resurrected memory")
	}
	if len(engine.catalogDurableRevisions) != 0 {
		t.Fatal("clear retained durable category revisions")
	}
	if err := <-save("rebuilt"); err != nil {
		t.Fatal(err)
	}
}

func TestNativeCatalogQueuedWriteSeesRevisionRollback(t *testing.T) {
	engine := cacheMaintenanceFixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	var calls int
	engine.catalogWriteFile = func(path string, body []byte) error {
		calls++
		if calls == 1 {
			close(entered)
			<-release
			return errors.New("synthetic write failure")
		}
		return writeNativeCacheFile(path, body)
	}
	first := make(chan struct{})
	go func() {
		engine.rememberCategories(sourceHongguo, []nativeCategory{{ID: "short_play", Name: "真人剧"}})
		close(first)
	}()
	<-entered
	second := make(chan error, 1)
	go func() {
		second <- engine.saveCatalogCache(sourceHongguo, &nativeCatalogResult{Items: []nativeDrama{{ID: "1"}}, Page: 1})
	}()
	deadline := time.Now().Add(time.Second)
	for len(engine.nativeCached(sourceHongguo).Items) == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	once.Do(func() { close(release) })
	<-first
	if err := <-second; err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(engine.catalogCachePath())
	if err != nil {
		t.Fatal(err)
	}
	var disk nativeCatalogDisk
	if err := json.Unmarshal(body, &disk); err != nil {
		t.Fatal(err)
	}
	if disk.CategoryRevisions[sourceHongguo] != "" || engine.catalogSaveError != nil {
		t.Fatal("queued snapshot persisted failed revision or stale error")
	}
}

func TestNativeCatalogQueuedCategoryRetryRestoresRevision(t *testing.T) {
	for _, outcome := range [][2]bool{{true, false}, {true, true}, {false, true}, {false, false}} {
		failFirst, failRetry := outcome[0], outcome[1]
		t.Run(fmt.Sprint(outcome), func(t *testing.T) {
			engine := cacheMaintenanceFixture(t)
			entered, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			defer once.Do(func() { close(release) })
			calls := 0
			engine.catalogWriteFile = func(path string, body []byte) error {
				calls++
				if calls == 1 {
					close(entered)
					<-release
					if failFirst {
						return errors.New("first failure")
					}
				}
				if calls > 1 && failRetry {
					return errors.New("retry failure")
				}
				return writeNativeCacheFile(path, body)
			}
			first, second := make(chan struct{}), make(chan struct{})
			go func() { engine.rememberCategories(sourceHongguo, []nativeCategory{{ID: "first"}}); close(first) }()
			<-entered
			go func() { engine.rememberCategories(sourceHongguo, []nativeCategory{{ID: "second"}}); close(second) }()
			deadline := time.Now().Add(time.Second)
			for {
				engine.mu.Lock()
				ready := engine.categoryOptions[sourceHongguo][0].ID == "second"
				engine.mu.Unlock()
				if ready {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("second category write blocked engine")
				}
				time.Sleep(time.Millisecond)
			}
			once.Do(func() { close(release) })
			<-first
			<-second
			want := nativeCategoryRevision(sourceHongguo)
			if failFirst && failRetry {
				want = ""
			}
			if engine.categoryRevisions[sourceHongguo] != want {
				t.Fatal("failed revision leaked or successful revision lost", engine.categoryRevisions)
			}
			if !failRetry {
				body, err := os.ReadFile(engine.catalogCachePath())
				if err != nil {
					t.Fatal(err)
				}
				var disk nativeCatalogDisk
				if err := json.Unmarshal(body, &disk); err != nil {
					t.Fatal(err)
				}
				if disk.CategoryRevisions[sourceHongguo] != want {
					t.Fatal("disk revision differs")
				}
			}
		})
	}
}

func TestNativeCatalogConcurrentReadersWriters(t *testing.T) {
	engine := cacheMaintenanceFixture(t)
	var workers sync.WaitGroup
	for worker := 0; worker < 6; worker++ {
		workers.Add(1)
		go func(worker int) {
			defer workers.Done()
			for turn := 0; turn < 12; turn++ {
				if worker%2 == 0 {
					result := nativeCatalogResult{Items: []nativeDrama{{ID: fmt.Sprint(worker), Source: sourceHongguo, Title: fmt.Sprint(turn), Tags: []string{"tag"}}}, Page: 1}
					if err := engine.saveCatalogCache(sourceHongguo, &result); err != nil {
						t.Error(err)
						return
					}
					if _, err := json.Marshal(result); err != nil {
						t.Error(err)
					}
				} else {
					result := engine.nativeCachedQuery(sourceHongguo, "tag")
					if _, err := json.Marshal(result); err != nil {
						t.Error(err)
					}
				}
			}
		}(worker)
	}
	workers.Wait()
	body, err := os.ReadFile(engine.catalogCachePath())
	if err != nil {
		t.Fatal(err)
	}
	var disk nativeCatalogDisk
	if err := json.Unmarshal(body, &disk); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(disk.Catalogs, engine.catalogs) {
		t.Fatal("last durable snapshot differs from memory")
	}
}

func TestNativeCachedSearchSemantics(t *testing.T) {
	engine := &nativeEngine{catalogs: map[string][]nativeDrama{sourceHongguo: {
		{ID: "1", Source: sourceHongguo, Title: "ALPHA 城市", Description: "Brave", Tags: []string{"ROMANCE"}},
		{ID: "1", Source: sourceHongguo, Title: "duplicate"},
		{ID: "2", Source: sourceHongguo, Title: "alpha", Tags: []string{"other"}},
		{ID: "3", Source: "huangdou", Title: "alpha brave romance"},
		{ID: "4", Source: sourceHongguo, Title: "wrong"},
		{ID: "4", Source: sourceHongguo, Title: "alpha brave romance"},
	}}}
	for query, want := range map[string][]string{"  ALpha\tBrAVE\nRomance ": {"1"}, "城市 romance": {"1"}, "not-found": {}, " \t ": {"1", "2", "4"}} {
		got := []string{}
		for _, item := range engine.nativeCachedQuery(sourceHongguo, query).Items {
			got = append(got, item.ID)
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("query %q: %v, want %v", query, got, want)
		}
	}
}

func BenchmarkNativeCachedSearch(b *testing.B) {
	items := make([]nativeDrama, 5000)
	for i := range items {
		items[i] = nativeDrama{ID: fmt.Sprint(i), Source: sourceHongguo, Title: "ordinary title", Description: "description", Tags: []string{"urban"}}
	}
	items[42].Title = "rare match"
	engine := &nativeEngine{catalogs: map[string][]nativeDrama{sourceHongguo: items}}
	for _, query := range []string{"", "rare urban"} {
		b.Run(fmt.Sprintf("query=%q", query), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				result := engine.nativeCachedQuery(sourceHongguo, query)
				if _, err := json.Marshal(result); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

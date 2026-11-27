package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

func readDownloadDelta(t *testing.T, manager *nativeDownloads, since string) map[string]any {
	t.Helper()
	result, err := manager.snapshotChanges(since)
	if err != nil {
		t.Fatal(err)
	}
	// 生产入口还需要编码响应；同时验证没有不可序列化的数据。
	if _, err = json.Marshal(result); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestNativeDownloadDeltaProgressAndMultipleReaders(t *testing.T) {
	manager := batchTestManager(t)
	manager.lastAttempt = time.Now().Add(time.Hour)
	for i := 1; i <= 1000; i++ {
		batchTestJob(manager, i, "completed", false)
	}
	job := manager.jobs[nativeDownloadID("hongguo:9001", 1)]
	job.State = "downloading"
	first := readDownloadDelta(t, manager, "")
	base := first["fingerprint"].(string)
	if len(first["jobs"].([]nativeDownloadJob)) != 1000 {
		t.Fatal("missing initial jobs")
	}
	manager.progress(job.ID, 10, 100, .1)
	second := readDownloadDelta(t, manager, base)
	changed := second["changed"].([]nativeDownloadJob)
	if second["jobs"] != nil || len(changed) != 1 || changed[0].Bytes != 10 {
		t.Fatalf("progress transmitted full history: %+v", second)
	}
	next := second["fingerprint"].(string)
	manager.progress(job.ID, 20, 100, .2)
	third := readDownloadDelta(t, manager, next)
	lagging := readDownloadDelta(t, manager, base)
	if len(lagging["changed"].([]nativeDownloadJob)) != 1 || lagging["changed"].([]nativeDownloadJob)[0].Bytes != 20 {
		t.Fatal("lagging reader missed cumulative changes")
	}
	if changed[0].Bytes != 10 {
		t.Fatal("published response was mutated")
	}
	stable := readDownloadDelta(t, manager, third["fingerprint"].(string))
	if len(stable) != 1 {
		t.Fatal("idle polling transmitted jobs")
	}
}

func TestNativeDownloadDeltaRemovalRecreationRollback(t *testing.T) {
	manager := batchTestManager(t)
	job := batchTestJob(manager, 1, "completed", false)
	base := readDownloadDelta(t, manager, "")["fingerprint"].(string)
	manager.writeIndex = func(string, []byte) error { return errors.New("disk full") }
	if err := manager.control(job.ID, "archive"); err == nil {
		t.Fatal("expected rollback")
	}
	if result := readDownloadDelta(t, manager, base); len(result) != 1 {
		t.Fatal("rollback leaked")
	}
	manager.writeIndex = nil
	if err := manager.control(job.ID, "remove"); err != nil {
		t.Fatal(err)
	}
	removed := readDownloadDelta(t, manager, base)
	if ids := removed["removed"].([]string); len(ids) != 1 || ids[0] != job.ID {
		t.Fatal("missing tombstone")
	}
	recreated := batchTestJob(manager, 1, "completed", false)
	recreated.Created = 999
	manager.invalidateSnapshotLocked()
	result := readDownloadDelta(t, manager, base)
	if len(result["removed"].([]string)) != 0 || result["changed"].([]nativeDownloadJob)[0].Created != 999 {
		t.Fatal("same ID recreation was lost")
	}
}

func TestNativeDownloadDeltaHistoryBoundsAndForeignCursor(t *testing.T) {
	manager := batchTestManager(t)
	manager.lastAttempt = time.Now().Add(time.Hour)
	job := batchTestJob(manager, 1, "downloading", false)
	base := readDownloadDelta(t, manager, "")["fingerprint"].(string)
	cursor := base
	for i := 1; i <= downloadDeltaHistoryLimit+2; i++ {
		manager.progress(job.ID, int64(i), 100, float64(i)/100)
		cursor = readDownloadDelta(t, manager, cursor)["fingerprint"].(string)
	}
	for _, token := range []string{base, "foreign:1", manager.delta.token + "999999"} {
		if readDownloadDelta(t, manager, token)["jobs"] == nil {
			t.Fatal("invalid/expired cursor did not reset")
		}
	}
	for i := 2; i <= downloadDeltaIDLimit+2; i++ {
		batchTestJob(manager, i, "completed", false)
	}
	manager.invalidateSnapshotLocked()
	readDownloadDelta(t, manager, cursor)
	if len(manager.delta.history) > downloadDeltaHistoryLimit || manager.delta.ids > downloadDeltaIDLimit {
		t.Fatal("unbounded delta journal")
	}
	if readDownloadDelta(t, manager, cursor)["jobs"] == nil {
		t.Fatal("large change needs full reset")
	}
}

func TestNativeDownloadDeltaCopiesMutableMetadata(t *testing.T) {
	manager := batchTestManager(t)
	job := batchTestJob(manager, 1, "completed", false)
	job.Drama.Tags = []string{"old"}
	job.Chapter.CurrentEpisode = json.RawMessage(`1`)
	first := readDownloadDelta(t, manager, "")
	old := first["jobs"].([]nativeDownloadJob)[0]
	job.Drama.Tags[0] = "new"
	job.Chapter.CurrentEpisode[0] = '2'
	manager.invalidateSnapshotLocked()
	result := readDownloadDelta(t, manager, first["fingerprint"].(string))
	if old.Drama.Tags[0] != "old" || string(old.Chapter.CurrentEpisode) != "1" {
		t.Fatal("response aliases live data")
	}
	if result["changed"].([]nativeDownloadJob)[0].Drama.Tags[0] != "new" {
		t.Fatal("metadata missing")
	}
}

func TestNativeDownloadDeltaConcurrentProgressAndEncoding(t *testing.T) {
	manager := batchTestManager(t)
	manager.lastAttempt = time.Now().Add(time.Hour)
	job := batchTestJob(manager, 1, "downloading", false)
	id := job.ID
	var writers sync.WaitGroup
	writers.Add(1)
	go func() {
		defer writers.Done()
		for i := 1; i <= 200; i++ {
			manager.progress(id, int64(i), 200, float64(i)/200)
			manager.mu.Lock()
			job.Drama.Tags = []string{fmt.Sprint(i)}
			manager.invalidateSnapshotLocked()
			manager.mu.Unlock()
		}
	}()
	cursor := ""
	for i := 0; i < 100; i++ {
		result := readDownloadDelta(t, manager, cursor)
		cursor = result["fingerprint"].(string)
	}
	writers.Wait()
	final := readDownloadDelta(t, manager, "")["jobs"].([]nativeDownloadJob)[0]
	if final.Bytes != 200 || final.Drama.Tags[0] != "200" {
		t.Fatal("final update lost")
	}
}

// 同样包含进度更新、快照和完整响应编码，比较兼容全量路径与增量路径。
func BenchmarkNativeDownloadSync(b *testing.B) {
	for _, n := range []int{100, 1000} {
		for _, incremental := range []bool{false, true} {
			b.Run(fmt.Sprintf("N=%d/delta=%v", n, incremental), func(b *testing.B) {
				manager := &nativeDownloads{jobs: map[string]*nativeDownloadRecord{}, lastAttempt: time.Now().Add(time.Hour)}
				for i := 1; i <= n; i++ {
					batchTestJob(manager, i, "downloading", false)
				}
				id := nativeDownloadID("hongguo:9001", 1)
				read := manager.snapshotSince
				if incremental {
					read = manager.snapshotChanges
				}
				first, _ := read("")
				cursor := first["fingerprint"].(string)
				b.ReportAllocs()
				b.ResetTimer()
				var encodedBytes int
				for i := 0; i < b.N; i++ {
					manager.progress(id, int64(i), int64(b.N), .5)
					result, err := read(cursor)
					if err != nil {
						b.Fatal(err)
					}
					data, err := json.Marshal(result)
					if err != nil {
						b.Fatal(err)
					}
					encodedBytes = len(data)
					cursor = result["fingerprint"].(string)
				}
				b.ReportMetric(float64(encodedBytes), "wire-B/op")
			})
		}
	}
}

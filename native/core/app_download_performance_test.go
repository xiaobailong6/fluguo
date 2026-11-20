package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func downloadAwait(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("download operation blocked by unrelated I/O")
	}
}

func downloadQuick(t *testing.T, work func()) {
	t.Helper()
	done := make(chan struct{})
	go func() { defer close(done); work() }()
	downloadAwait(t, done)
}

func downloadFingerprint(t *testing.T, manager *nativeDownloads) string {
	t.Helper()
	result, err := manager.snapshotSince("")
	if err != nil {
		t.Fatal(err)
	}
	return result["fingerprint"].(string)
}

func TestNativeDownloadCheckpointFailureThrottled(t *testing.T) {
	manager := batchTestManager(t)
	job := batchTestJob(manager, 1, "downloading", false)
	var writes atomic.Int32
	manager.writeIndex = func(string, []byte) error { writes.Add(1); return errors.New("disk full") }
	manager.progress(job.ID, 1, 10000, .01)
	manager.checkpoints.Wait()
	attempt := manager.lastAttempt
	for i := 2; i < 1000; i++ {
		manager.progress(job.ID, int64(i), 10000, .1)
	}
	manager.checkpoints.Wait()
	if writes.Load() != 1 || manager.lastAttempt != attempt || !manager.lastSaved.IsZero() {
		t.Fatalf("failure retried on every progress: %d", writes.Load())
	}
	manager.mu.Lock()
	manager.lastAttempt = time.Now().Add(-2 * time.Second)
	manager.mu.Unlock()
	manager.progress(job.ID, 1000, 10000, .1)
	manager.checkpoints.Wait()
	if writes.Load() != 2 {
		t.Fatal("throttle never allowed retry")
	}
}

func TestNativeDownloadCheckpointDoesNotBlockOrOverwriteTransaction(t *testing.T) {
	for _, action := range []string{"pause", "remove", "failed-pause"} {
		t.Run(action, func(t *testing.T) {
			manager := batchTestManager(t)
			job := batchTestJob(manager, 1, "downloading", false)
			if err := manager.saveLocked(); err != nil {
				t.Fatal(err)
			}
			entered, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			defer once.Do(func() { close(release) })
			manager.writeIndex = func(name string, data []byte) error {
				if strings.HasPrefix(filepath.Base(name), ".download-checkpoint-") {
					close(entered)
					<-release
				}
				if action == "failed-pause" && filepath.Base(name) == "index.json" {
					return errors.New("transaction failed")
				}
				return nativeDownloadWrite(name, data)
			}
			manager.lastAttempt = time.Time{}
			manager.progress(job.ID, 64, 100, .64)
			downloadAwait(t, entered)
			downloadQuick(t, func() {
				if _, err := manager.snapshotSince(""); err != nil {
					t.Error(err)
				}
				manager.progress(job.ID, 65, 100, .65)
			})
			downloadQuick(t, func() {
				command := action
				if action == "failed-pause" {
					command = "pause"
				}
				err := manager.control(job.ID, command)
				if (action == "failed-pause") != (err != nil) {
					t.Errorf("transaction result: %v", err)
				}
			})
			once.Do(func() { close(release) })
			manager.checkpoints.Wait()
			saved := batchTestIndex(t, manager)
			switch action {
			case "pause":
				if saved[job.ID].State != "paused" || saved[job.ID].Bytes != 65 {
					t.Fatal("old checkpoint overwrote pause")
				}
			case "remove":
				if len(saved) != 0 {
					t.Fatal("old checkpoint resurrected deleted job")
				}
			case "failed-pause":
				if saved[job.ID].Bytes != 0 || job.State != "downloading" {
					t.Fatal("failed transaction permitted stale publication")
				}
			}
		})
	}
}

func TestNativeDownloadCheckpointBoundedCoalescing(t *testing.T) {
	manager := batchTestManager(t)
	job := batchTestJob(manager, 1, "downloading", false)
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	var writes, active, peak atomic.Int32
	manager.writeIndex = func(name string, data []byte) error {
		n := active.Add(1)
		if n > peak.Load() {
			peak.Store(n)
		}
		defer active.Add(-1)
		if writes.Add(1) == 1 {
			close(entered)
			<-release
		}
		return nativeDownloadWrite(name, data)
	}
	manager.progress(job.ID, 1, 100, .01)
	downloadAwait(t, entered)
	for i := 2; i <= 100; i++ {
		manager.mu.Lock()
		manager.lastAttempt = time.Time{}
		manager.mu.Unlock()
		manager.progress(job.ID, int64(i), 100, float64(i)/100)
	}
	once.Do(func() { close(release) })
	manager.checkpoints.Wait()
	if writes.Load() != 2 || peak.Load() != 1 || batchTestIndex(t, manager)[job.ID].Bytes != 100 {
		t.Fatalf("unbounded/nonmerged writer: writes=%d peak=%d", writes.Load(), peak.Load())
	}
}

func TestNativeDownloadSnapshotCacheInvalidation(t *testing.T) {
	manager := batchTestManager(t)
	job := batchTestJob(manager, 1, "completed", false)
	original := downloadFingerprint(t, manager)
	data := manager.snapshotData
	for i := 0; i < 20; i++ {
		result, err := manager.snapshotSince(original)
		if err != nil || result["jobs"] != nil || &data[0] != &manager.snapshotData[0] {
			t.Fatal("unchanged poll rebuilt snapshot")
		}
		_, _ = manager.snapshot()
	}
	if err := manager.control(job.ID, "archive"); err != nil {
		t.Fatal(err)
	}
	archived := downloadFingerprint(t, manager)
	if archived == original {
		t.Fatal("archive not invalidated")
	}
	manager.writeIndex = func(string, []byte) error { return errors.New("disk full") }
	if err := manager.control(job.ID, "restore"); err == nil {
		t.Fatal("expected rollback")
	}
	if downloadFingerprint(t, manager) != archived {
		t.Fatal("failed transaction leaked speculative view")
	}
	manager.writeIndex = nil
	if err := manager.control(job.ID, "restore"); err != nil {
		t.Fatal(err)
	}
	if downloadFingerprint(t, manager) != original {
		t.Fatal("restored visible state changed content fingerprint")
	}
	manager.mu.Lock()
	job.State = "downloading"
	manager.invalidateSnapshotLocked()
	manager.lastAttempt = time.Now()
	manager.mu.Unlock()
	before := downloadFingerprint(t, manager)
	manager.progress(job.ID, 7, 10, .7)
	after := downloadFingerprint(t, manager)
	if after == before {
		t.Fatal("progress not invalidated")
	}
	data = manager.snapshotData
	manager.progress(job.ID, 7, 10, .7)
	if downloadFingerprint(t, manager) != after || &data[0] != &manager.snapshotData[0] {
		t.Fatal("identical progress invalidated cache")
	}
	if err := manager.control(job.ID, "remove"); err != nil {
		t.Fatal(err)
	}
	if downloadFingerprint(t, manager) == after {
		t.Fatal("remove not invalidated")
	}
}

func TestNativeDownloadConversionHashAndCleanupDoNotBlock(t *testing.T) {
	for _, phase := range []string{"hash", "cleanup"} {
		t.Run(phase, func(t *testing.T) {
			manager := downloadTestManager(t)
			id := convertingFixture(t, manager, nativeDrama{ID: "hongguo:perf", Source: "hongguo", Title: "性能"}, 1, false)
			work, err := manager.beginConversion(id)
			if err != nil {
				t.Fatal(err)
			}
			normalizationWrite(t, work.Output, "converted-video")
			before := downloadFingerprint(t, manager)
			entered, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			defer once.Do(func() { close(release) })
			var hashes atomic.Int32
			manager.hashFile = func(name string) (string, int64, error) {
				hashes.Add(1)
				if phase == "hash" {
					close(entered)
					<-release
				}
				return nativeConversionIdentity(name)
			}
			manager.removeTree = func(name string) error {
				if phase == "cleanup" {
					close(entered)
					<-release
				}
				return os.RemoveAll(name)
			}
			done := make(chan struct{})
			var finishErr error
			go func() { defer close(done); finishErr = manager.finishConversion(id, "done") }()
			downloadAwait(t, entered)
			downloadQuick(t, func() {
				if _, err := manager.snapshotSince(before); err != nil {
					t.Error(err)
				}
				if _, err := manager.beginConversion(id); err == nil {
					t.Error("duplicate conversion during hash")
				}
				if err := manager.finishConversion(id, "cancel"); err == nil {
					t.Error("duplicate finish released occupied job")
				}
				if err := manager.engine.moveDownloads(context.Background(), t.TempDir()); err == nil {
					t.Error("migration during conversion")
				}
			})
			once.Do(func() { close(release) })
			downloadAwait(t, done)
			if finishErr != nil || hashes.Load() != 1 || manager.jobs[id].State != "completed" {
				t.Fatalf("normal conversion reread output: hashes=%d err=%v", hashes.Load(), finishErr)
			}
			if before == downloadFingerprint(t, manager) {
				t.Fatal("conversion not invalidated")
			}
		})
	}
}

func TestNativeDownloadRemoveDuringHash(t *testing.T) {
	for _, normalize := range []bool{false, true} {
		t.Run(fmt.Sprint(normalize), func(t *testing.T) {
			manager := downloadTestManager(t)
			var id string
			var expected *nativeDownloadIdentity
			var work nativeDownloadConversion
			var err error
			if normalize {
				id, _, expected = normalizationFixture(t, manager, 1)
				work, err = manager.beginNormalization(id, expected)
			} else {
				id = convertingFixture(t, manager, nativeDrama{ID: "hongguo:hash-remove", Source: "hongguo", Title: "删除"}, 1, false)
				work, err = manager.beginConversion(id)
			}
			if err != nil {
				t.Fatal(err)
			}
			normalizationWrite(t, work.Output, "converted-video")
			entered, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			defer once.Do(func() { close(release) })
			manager.hashFile = func(name string) (string, int64, error) {
				close(entered)
				<-release
				return nativeConversionIdentity(name)
			}
			done := make(chan struct{})
			var finishErr error
			go func() {
				defer close(done)
				if normalize {
					_, finishErr = manager.finishNormalization(id, expected, "done")
				} else {
					finishErr = manager.finishConversion(id, "done")
				}
			}()
			downloadAwait(t, entered)
			downloadQuick(t, func() {
				if err := manager.control(id, "remove"); err != nil {
					t.Error(err)
				}
				if _, err := manager.snapshotSince(""); err != nil {
					t.Error(err)
				}
			})
			if _, err := os.Stat(work.Input); err != nil {
				t.Fatal("removed input while hash occupied job")
			}
			once.Do(func() { close(release) })
			downloadAwait(t, done)
			if finishErr != nil || manager.jobs[id] != nil || manager.converting[id] {
				t.Fatalf("hash completion resurrected deleted job: %v", finishErr)
			}
		})
	}
}

func TestNativeDownloadRecoveryHashDoesNotBlock(t *testing.T) {
	manager := downloadTestManager(t)
	id := convertingFixture(t, manager, nativeDrama{ID: "hongguo:recover-perf", Source: "hongguo", Title: "恢复"}, 1, false)
	record := manager.jobs[id]
	record.Output = "恢复/第1集.mp4"
	target := manager.outputFile(record.Output)
	batchTestWriteFile(t, target)
	hash, size, err := nativeConversionIdentity(target)
	if err != nil {
		t.Fatal(err)
	}
	record.ConversionPending, record.ConversionSHA256, record.ConversionSize = true, hash, size
	if err := manager.saveLocked(); err != nil {
		t.Fatal(err)
	}
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	manager.hashFile = func(name string) (string, int64, error) {
		close(entered)
		<-release
		return nativeConversionIdentity(name)
	}
	done := make(chan struct{})
	var finishErr error
	go func() { defer close(done); finishErr = manager.finishConversion(id, "done") }()
	downloadAwait(t, entered)
	downloadQuick(t, func() {
		if _, err := manager.snapshotSince(""); err != nil {
			t.Error(err)
		}
	})
	once.Do(func() { close(release) })
	downloadAwait(t, done)
	if finishErr != nil || record.State != "completed" || record.ConversionPending {
		t.Fatalf("recovery failed: %v", finishErr)
	}
}

func TestNativeDownloadRenameUnknownIdentityRehashes(t *testing.T) {
	manager := downloadTestManager(t)
	id := convertingFixture(t, manager, nativeDrama{ID: "hongguo:identity", Source: "hongguo", Title: "身份"}, 1, false)
	work, err := manager.beginConversion(id)
	if err != nil {
		t.Fatal(err)
	}
	normalizationWrite(t, work.Output, "converted-video")
	var hashes int
	manager.hashFile = func(name string) (string, int64, error) { hashes++; return nativeConversionIdentity(name) }
	manager.renameFile = func(from, to string) error {
		info, err := os.Stat(from)
		if err != nil {
			return err
		}
		if err := os.WriteFile(to, []byte("obsolete-result"), 0600); err != nil {
			return err
		}
		return os.Chtimes(to, info.ModTime(), info.ModTime()) // 相同长度/mtime，不同文件对象。
	}
	if err := manager.finishConversion(id, "done"); err != nil {
		t.Fatal(err)
	}
	if hashes != 2 || manager.jobs[id].State == "completed" || manager.jobs[id].File == "" {
		t.Fatal("same path/size incorrectly reused digest")
	}
	if _, err := os.Stat(work.Input); err != nil {
		t.Fatal("unknown output deleted raw input")
	}
}

func TestDownloadMigrationCopyDoesNotHoldGlobalLocks(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		t.Run(fmt.Sprint(cancelled), func(t *testing.T) {
			engine, id := storageFixture(t)
			manager := engine.downloads
			old := manager.root
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			entered, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			defer once.Do(func() { close(release) })
			manager.copyTree = func(ctx context.Context, source, target string) error {
				close(entered)
				<-release
				return nativeCopyTree(ctx, source, target)
			}
			parent := t.TempDir()
			done := make(chan struct{})
			var moveErr error
			go func() { defer close(done); moveErr = engine.moveDownloads(ctx, parent) }()
			downloadAwait(t, entered)
			downloadQuick(t, func() {
				if _, err := manager.snapshotSince(""); err != nil {
					t.Error(err)
				}
				engine.mu.Lock()
				engine.mu.Unlock() // cancellation/playback release use this same lock.
				if _, err := engine.workLease("export", "start"); err == nil {
					t.Error("export accepted during copy")
				}
				if _, err := engine.workLease("merge", "start"); err == nil {
					t.Error("merge accepted during copy")
				}
				if err := manager.control(id, "remove"); err == nil {
					t.Error("delete accepted during copy")
				}
				if _, err := manager.beginConversion(id); err == nil {
					t.Error("conversion accepted during copy")
				}
				if _, _, err := manager.localPlan("hongguo:70001", 1); err == nil {
					t.Error("new local path escaped lease")
				}
				if err := engine.moveDownloads(context.Background(), t.TempDir()); err == nil {
					t.Error("parallel migration accepted")
				}
				if cancelled {
					cancel()
				}
			})
			once.Do(func() { close(release) })
			downloadAwait(t, done)
			if cancelled {
				if moveErr == nil || manager.root != old {
					t.Fatal("cancelled copy changed root")
				}
				normalizationContent(t, filepath.Join(old, id, "media.mp4"), "synthetic-video")
				normalizationAbsent(t, filepath.Join(parent, "zhenguojian-downloads"))
			} else {
				if moveErr != nil || manager.root == old {
					t.Fatalf("copy failed: %v", moveErr)
				}
				reopened := newNativeDownloads(engine)
				defer reopened.close()
				if reopened.loadErr != nil || reopened.jobs[id] == nil {
					t.Fatal("migration restart failed")
				}
			}
			if manager.moving {
				t.Fatal("migration lease leaked")
			}
		})
	}
}

// 本机微基准，不包括站源/网络/设备；changed 覆盖真实失效成本，stable 覆盖轮询热路径。
func BenchmarkNativeDownloadSnapshot(b *testing.B) {
	for _, n := range []int{100, 1000} {
		for _, changed := range []bool{false, true} {
			b.Run(fmt.Sprintf("N=%d/changed=%v", n, changed), func(b *testing.B) {
				manager := &nativeDownloads{jobs: map[string]*nativeDownloadRecord{}, lastAttempt: time.Now().Add(time.Hour)}
				for i := 1; i <= n; i++ {
					batchTestJob(manager, i, "downloading", false)
				}
				id := nativeDownloadID("hongguo:9001", 1)
				result, _ := manager.snapshotSince("")
				fingerprint := result["fingerprint"].(string)
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					if changed {
						manager.progress(id, int64(i), int64(b.N), .5)
					}
					result, err := manager.snapshotSince(fingerprint)
					if err != nil {
						b.Fatal(err)
					}
					fingerprint = result["fingerprint"].(string)
				}
			})
		}
	}
}

func BenchmarkNativeDownloadProgress(b *testing.B) {
	for _, n := range []int{100, 1000} {
		b.Run(fmt.Sprintf("N=%d", n), func(b *testing.B) {
			manager := &nativeDownloads{jobs: map[string]*nativeDownloadRecord{}, lastAttempt: time.Now().Add(time.Hour)}
			for i := 1; i <= n; i++ {
				batchTestJob(manager, i, "downloading", false)
			}
			id := nativeDownloadID("hongguo:9001", 1)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				manager.progress(id, int64(i), int64(b.N), .5)
			}
		})
	}
}

func BenchmarkNativeDownloadCheckpoint(b *testing.B) {
	for _, n := range []int{100, 1000} {
		b.Run(fmt.Sprintf("N=%d", n), func(b *testing.B) {
			manager := &nativeDownloads{root: b.TempDir(), jobs: map[string]*nativeDownloadRecord{}}
			for i := 1; i <= n; i++ {
				batchTestJob(manager, i, "downloading", false)
			}
			id := nativeDownloadID("hongguo:9001", 1)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				manager.mu.Lock()
				manager.lastAttempt = time.Time{}
				manager.mu.Unlock()
				manager.progress(id, int64(i), int64(b.N), .5)
				manager.checkpoints.Wait()
			}
		})
	}
}

func TestNativeDownloadSnapshotCachedBytesRemainImmutable(t *testing.T) {
	manager := batchTestManager(t)
	job := batchTestJob(manager, 1, "completed", false)
	result, err := manager.snapshotSince("")
	if err != nil {
		t.Fatal(err)
	}
	old := result["jobs"].(json.RawMessage)
	saved := string(old)
	if err := manager.control(job.ID, "archive"); err != nil {
		t.Fatal(err)
	}
	_, _ = manager.snapshotSince("")
	if string(old) != saved {
		t.Fatal("new snapshot mutated already published bytes")
	}
}

func TestNativeDownloadSnapshotMutationEntrypoints(t *testing.T) {
	manager := batchTestManager(t)
	// 保留虚拟满槽，不运行网络 worker，验证 enqueue/metadata/resume/batch 的失效。
	manager.active["occupied"] = func() {}
	before := downloadFingerprint(t, manager)
	input := downloadTestInput(1)
	if _, err := manager.enqueue(input); err != nil {
		t.Fatal(err)
	}
	after := downloadFingerprint(t, manager)
	if after == before {
		t.Fatal("enqueue cache stale")
	}
	id := nativeDownloadID(input.Drama.ID, 1)
	for _, command := range []string{"pause", "resume"} {
		before = after
		if _, err := manager.controlBatch(context.Background(), []string{id}, command); err != nil {
			t.Fatal(err)
		}
		after = downloadFingerprint(t, manager)
		if after == before {
			t.Fatalf("%s cache stale", command)
		}
	}
	input.Force, input.Drama.Title = true, "更新元数据"
	if _, err := manager.enqueue(input); err != nil {
		t.Fatal(err)
	}
	if downloadFingerprint(t, manager) == after {
		t.Fatal("metadata cache stale")
	}
	manager.jobs[id].State = "completed"
	manager.jobs[id].File = "media.mp4"
	manager.jobs[id].Archived = true
	if err := manager.saveLocked(); err != nil {
		t.Fatal(err)
	}
	before = downloadFingerprint(t, manager)
	if _, _, err := manager.localPlan(input.Drama.ID, 1); err == nil {
		t.Fatal("missing local media accepted")
	}
	if downloadFingerprint(t, manager) == before {
		t.Fatal("local invalidation cache stale")
	}
}

func TestNativeDownloadNormalizationHashUnlockAndCache(t *testing.T) {
	manager := downloadTestManager(t)
	id, target, expected := normalizationFixture(t, manager, 1)
	work, err := manager.beginNormalization(id, expected)
	if err != nil {
		t.Fatal(err)
	}
	normalizationWrite(t, work.Output, "new-video")
	before := downloadFingerprint(t, manager)
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	manager.hashFile = func(name string) (string, int64, error) {
		close(entered)
		<-release
		return nativeConversionIdentity(name)
	}
	done := make(chan struct{})
	var finishErr error
	go func() { defer close(done); _, finishErr = manager.finishNormalization(id, expected, "done") }()
	downloadAwait(t, entered)
	downloadQuick(t, func() {
		if downloadFingerprint(t, manager) != before {
			t.Error("uncommitted normalization visible")
		}
		if _, err := manager.beginNormalization(id, expected); err == nil {
			t.Error("duplicate normalization")
		}
		if _, err := manager.finishNormalization(id, expected, "cancel"); err == nil {
			t.Error("duplicate finish")
		}
	})
	once.Do(func() { close(release) })
	downloadAwait(t, done)
	if finishErr != nil || manager.jobs[id].Revision != expected.Revision+1 {
		t.Fatalf("normalization failed: %v", finishErr)
	}
	if downloadFingerprint(t, manager) == before {
		t.Fatal("normalization revision not invalidated")
	}
	normalizationContent(t, target, "new-video")
}

func TestNativeDownloadHashRejectsChangedJobIdentity(t *testing.T) {
	for _, field := range []string{"created", "revision", "record"} {
		t.Run(field, func(t *testing.T) {
			manager := downloadTestManager(t)
			id := convertingFixture(t, manager, nativeDrama{ID: "hongguo:stale", Source: "hongguo", Title: "身份变化"}, 1, false)
			work, err := manager.beginConversion(id)
			if err != nil {
				t.Fatal(err)
			}
			normalizationWrite(t, work.Output, "converted-video")
			entered, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			defer once.Do(func() { close(release) })
			manager.hashFile = func(name string) (string, int64, error) {
				close(entered)
				<-release
				return nativeConversionIdentity(name)
			}
			done := make(chan struct{})
			var finishErr error
			go func() { defer close(done); finishErr = manager.finishConversion(id, "done") }()
			downloadAwait(t, entered)
			manager.mu.Lock()
			switch field {
			case "created":
				manager.jobs[id].Created++
			case "revision":
				manager.jobs[id].Revision++
			case "record":
				copy := *manager.jobs[id]
				manager.jobs[id] = &copy
			}
			manager.mu.Unlock()
			once.Do(func() { close(release) })
			downloadAwait(t, done)
			if !errors.Is(finishErr, errNativeDownloadChanged) || manager.jobs[id].State != "converting" || manager.jobs[id].Output != "" {
				t.Fatalf("stale hash committed: %v", finishErr)
			}
			normalizationContent(t, work.Input, "synthetic-video")
		})
	}
}

func TestDownloadMigrationWaitDoesNotHoldEngineLock(t *testing.T) {
	engine, _ := storageFixture(t)
	manager := engine.downloads
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	manager.active["waiting"] = func() { close(entered) }
	// 迁移按 jobs 取消活动任务，使用已有 ID 挂接模拟 worker。
	for id := range manager.jobs {
		manager.active[id] = manager.active["waiting"]
		break
	}
	delete(manager.active, "waiting")
	manager.workers.Add(1)
	go func() { <-release; manager.workers.Done() }()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	var moveErr error
	parent := t.TempDir()
	go func() { defer close(done); moveErr = engine.moveDownloads(ctx, parent) }()
	downloadAwait(t, entered)
	downloadQuick(t, func() { engine.mu.Lock(); engine.mu.Unlock(); _, _ = manager.snapshotSince(""); cancel() })
	once.Do(func() { close(release) })
	downloadAwait(t, done)
	manager.active = map[string]context.CancelFunc{}
	if moveErr == nil || manager.moving {
		t.Fatal("cancelled wait committed or leaked lease")
	}
}

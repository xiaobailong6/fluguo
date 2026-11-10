package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// 不启动 engine/网络服务；每个测试拥有独立的索引写入钩子，避免全局注入竞争。
func batchTestManager(t *testing.T) *nativeDownloads {
	t.Helper()
	return &nativeDownloads{root: t.TempDir(), jobs: map[string]*nativeDownloadRecord{},
		active: map[string]context.CancelFunc{}, converting: map[string]bool{}, concurrency: 1}
}

func batchTestJob(manager *nativeDownloads, index int, state string, archived bool) *nativeDownloadRecord {
	drama := nativeDrama{ID: "hongguo:9001", Source: "hongguo", Title: "批量测试"}
	job := &nativeDownloadRecord{nativeDownloadJob: nativeDownloadJob{
		ID: nativeDownloadID(drama.ID, index), Drama: drama, Index: index,
		Chapter: Chapter{CurrentEpisode: json.RawMessage("null")},
		State: state, Archived: archived, Created: int64(index)}}
	manager.jobs[job.ID] = job
	return job
}

func batchTestWriteFile(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("synthetic-video"), 0600); err != nil {
		t.Fatal(err)
	}
}

func batchTestIndex(t *testing.T, manager *nativeDownloads) map[string]nativeDownloadRecord {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(manager.root, "index.json"))
	if err != nil {
		t.Fatal(err)
	}
	var records []nativeDownloadRecord
	if err := json.Unmarshal(data, &records); err != nil {
		t.Fatal(err)
	}
	indexed := map[string]nativeDownloadRecord{}
	for _, record := range records {
		indexed[record.ID] = record
	}
	return indexed
}

func batchTestResult(t *testing.T, result nativeDownloadControlResult, err error, completed []string, failures int) {
	t.Helper()
	if err != nil || !reflect.DeepEqual(result.Completed, completed) || len(result.Failures) != failures {
		t.Fatalf("result = %+v, err = %v; want completed %v, %d failures", result, err, completed, failures)
	}
}

func TestNativeDownloadBatchArchive500WritesOnce(t *testing.T) {
	manager := batchTestManager(t)
	ids := []string{}
	for index := 500; index > 0; index-- {
		ids = append(ids, batchTestJob(manager, index, "completed", false).ID)
	}
	writes := 0
	manager.writeIndex = func(path string, data []byte) error {
		writes++
		return nativeDownloadWrite(path, data)
	}
	result, err := manager.controlBatch(context.Background(), ids, "archive")
	batchTestResult(t, result, err, ids, 0)
	if writes != 1 {
		t.Fatalf("500 archives wrote index %d times", writes)
	}
	for _, job := range batchTestIndex(t, manager) {
		if !job.Archived {
			t.Fatal("archive was not persisted")
		}
	}
	result, err = manager.controlBatch(context.Background(), ids, "archive")
	batchTestResult(t, result, err, ids, 0)
	if writes != 1 {
		t.Fatal("no-op archive wrote index")
	}
	reopened := batchTestManager(t)
	reopened.root = manager.root
	if err := reopened.load(); err != nil || len(reopened.jobs) != 500 {
		t.Fatalf("archive restart: %d jobs, %v", len(reopened.jobs), err)
	}
	for _, job := range reopened.jobs {
		if !job.Archived {
			t.Fatal("restart lost archive state")
		}
	}
}

func TestNativeDownloadBatchDuplicatesNoOpsAndPartialInvalid(t *testing.T) {
	manager := batchTestManager(t)
	one := batchTestJob(manager, 1, "completed", false)
	two := batchTestJob(manager, 2, "completed", false)
	unfinished := batchTestJob(manager, 3, "paused", false)
	denied := batchTestJob(manager, 4, "completed", false)
	denied.Chapter.Source = "fanguo" // 即便全站源构建也必须拒绝跨站章节。
	unknown := batchTestJob(manager, 5, "completed", false)
	unknown.Drama.Source = "unknown-source"
	writes := 0
	manager.writeIndex = func(path string, data []byte) error {
		writes++
		return nativeDownloadWrite(path, data)
	}
	ids := []string{two.ID, "missing", one.ID, two.ID, unfinished.ID, denied.ID, unknown.ID, "missing"}
	result, err := manager.controlBatch(context.Background(), ids, "archive")
	batchTestResult(t, result, err, []string{two.ID, one.ID}, 4)
	if writes != 1 || result.Failures[denied.ID] != errNativeBuildSource.Error() ||
		result.Failures[unknown.ID] != errNativeBuildSource.Error() {
		t.Fatalf("validation or duplicate writes: %d, %+v", writes, result)
	}
	for _, command := range []string{"archive", "pause", "resume"} {
		result, err = manager.controlBatch(context.Background(), []string{one.ID, one.ID, two.ID}, command)
		batchTestResult(t, result, err, []string{one.ID, two.ID}, 0)
	}
	if writes != 1 {
		t.Fatal("no-op commands wrote index")
	}
	result, err = manager.controlBatch(context.Background(), []string{one.ID, two.ID, one.ID}, "restore")
	batchTestResult(t, result, err, []string{one.ID, two.ID}, 0)
	result, err = manager.controlBatch(context.Background(), []string{one.ID, two.ID}, "restore")
	batchTestResult(t, result, err, []string{one.ID, two.ID}, 0)
	if writes != 2 {
		t.Fatal("restore did not coalesce changes or skipped no-op detection")
	}
}

func TestNativeDownloadBatchRestoreLimitAndRollback(t *testing.T) {
	for _, fail := range []bool{false, true} {
		t.Run(map[bool]string{false: "commit", true: "rollback"}[fail], func(t *testing.T) {
			manager := batchTestManager(t)
			for index := 1; index <= 4999; index++ {
				batchTestJob(manager, index, "completed", false)
			}
			one := batchTestJob(manager, 5000, "completed", true)
			two := batchTestJob(manager, 5001, "completed", true)
			noop := manager.jobs[nativeDownloadID(one.Drama.ID, 1)].ID
			writes := 0
			manager.writeIndex = func(path string, data []byte) error {
				writes++
				if fail {
					return errors.New("injected index failure")
				}
				return nativeDownloadWrite(path, data)
			}
			result, err := manager.controlBatch(context.Background(), []string{two.ID, two.ID, "missing", one.ID, noop}, "restore")
			want := []string{two.ID, noop}
			failures := 2
			if fail {
				want, failures = []string{noop}, 3
			}
			batchTestResult(t, result, err, want, failures)
			if writes != 1 || !one.Archived || two.Archived != fail {
				t.Fatalf("restore quota/rollback: writes=%d one=%v two=%v", writes, one.Archived, two.Archived)
			}
			if !fail {
				result, err = manager.controlBatch(context.Background(), []string{one.ID, noop}, "restore")
				batchTestResult(t, result, err, []string{noop}, 1)
				if writes != 1 || manager.unarchivedCountLocked() != 5000 {
					t.Fatal("full restore rewrote index or exceeded 5000")
				}
			}
		})
	}
}

func TestNativeDownloadBatchStateRollbackBeforeSideEffects(t *testing.T) {
	for _, command := range []string{"pause", "resume", "archive", "restore", "remove"} {
		t.Run(command, func(t *testing.T) {
			manager := batchTestManager(t)
			state := "completed"
			if command == "pause" || command == "remove" {
				state = "downloading"
			} else if command == "resume" {
				state = "failed"
			}
			one := batchTestJob(manager, 1, state, command == "restore")
			two := batchTestJob(manager, 2, state, command == "restore")
			one.Error, two.Error = "old-one", "old-two"
			beforeOne, beforeTwo := *one, *two
			file := filepath.Join(manager.jobDirectory(one.nativeDownloadJob), "media.mp4")
			batchTestWriteFile(t, file)
			cancelled := 0
			if command == "pause" || command == "remove" {
				manager.active[one.ID] = func() { cancelled++ }
			}
			if err := manager.saveLocked(); err != nil {
				t.Fatal(err)
			}
			writes := 0
			manager.writeIndex = func(string, []byte) error {
				writes++
				if cancelled != 0 {
					t.Error("cancel happened before state commit")
				}
				return errors.New("injected index failure")
			}
			result, err := manager.controlBatch(context.Background(), []string{one.ID, two.ID, one.ID}, command)
			batchTestResult(t, result, err, []string{}, 2)
			if writes != 1 || cancelled != 0 || !reflect.DeepEqual(*one, beforeOne) || !reflect.DeepEqual(*two, beforeTwo) {
				t.Fatalf("failed commit changed memory or effects: writes=%d cancels=%d", writes, cancelled)
			}
			if command == "resume" && len(manager.active) != 0 {
				t.Fatal("resume scheduled before commit")
			}
			if _, err := os.Stat(file); err != nil {
				t.Fatal("failed remove commit deleted media")
			}
			if !reflect.DeepEqual(batchTestIndex(t, manager)[one.ID], beforeOne) {
				t.Fatal("failed save changed durable record")
			}
		})
	}
}

func TestNativeDownloadBatchPauseAndResumeCommitOnce(t *testing.T) {
	manager := batchTestManager(t)
	one := batchTestJob(manager, 1, "downloading", false)
	two := batchTestJob(manager, 2, "queued", false)
	writes, cancelled := 0, 0
	manager.active[one.ID] = func() {
		if writes != 1 || one.State != "paused" || two.State != "paused" {
			t.Error("cancel preceded batch commit")
		}
		cancelled++
	}
	manager.writeIndex = func(path string, data []byte) error {
		writes++
		return nativeDownloadWrite(path, data)
	}
	result, err := manager.controlBatch(context.Background(), []string{two.ID, one.ID, two.ID}, "pause")
	batchTestResult(t, result, err, []string{two.ID, one.ID}, 0)
	result, err = manager.controlBatch(context.Background(), []string{one.ID, two.ID}, "pause")
	batchTestResult(t, result, err, []string{one.ID, two.ID}, 0)
	if writes != 1 || cancelled != 1 {
		t.Fatalf("pause writes=%d cancels=%d", writes, cancelled)
	}
	// 保持一个在途槽位，区分批量状态提交与随后 worker 启动所需的独立提交。
	result, err = manager.controlBatch(context.Background(), []string{two.ID, one.ID}, "resume")
	batchTestResult(t, result, err, []string{two.ID, one.ID}, 0)
	if writes != 2 || one.State != "queued" || two.State != "queued" || cancelled != 1 {
		t.Fatal("resume state phase was not one commit")
	}
	result, err = manager.controlBatch(context.Background(), []string{one.ID, two.ID}, "resume")
	batchTestResult(t, result, err, []string{one.ID, two.ID}, 0)
	if writes != 2 {
		t.Fatal("no-op resume saved")
	}
}

func TestNativeDownloadBatchResumeSchedulesAfterCommit(t *testing.T) {
	manager := batchTestManager(t)
	one := batchTestJob(manager, 1, "paused", false)
	two := batchTestJob(manager, 2, "failed", false)
	started := make(chan string, 2)
	manager.resolve = func(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
		started <- job.ID
		<-ctx.Done()
		return providerMedia{}, ctx.Err()
	}
	writes := 0
	manager.writeIndex = func(path string, data []byte) error {
		writes++
		if writes == 1 && (len(manager.active) != 0 || one.State != "queued" || two.State != "queued") {
			t.Error("resume started a worker before all state changes committed")
		}
		return nativeDownloadWrite(path, data)
	}
	t.Cleanup(manager.close)
	result, err := manager.controlBatch(context.Background(), []string{two.ID, one.ID}, "resume")
	batchTestResult(t, result, err, []string{two.ID, one.ID}, 0)
	manager.mu.Lock()
	count, active := writes, len(manager.active)
	manager.mu.Unlock()
	if count != 2 || active != 1 {
		t.Fatalf("want state commit + one worker commit, got %d writes, %d active", count, active)
	}
	select {
	case id := <-started:
		if id != one.ID {
			t.Fatal("scheduler order changed")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("resume never scheduled")
	}
}

// 在指定的逐项边界取消，避免用 sleep 制造不稳定的并发时序。
type batchTestCancelContext struct {
	context.Context
	checks int
	stopAt int
	cancel context.CancelFunc
}

func (ctx *batchTestCancelContext) Err() error {
	ctx.checks++
	if ctx.checks == ctx.stopAt {
		ctx.cancel()
	}
	return ctx.Context.Err()
}

func TestNativeDownloadBatchCancellationKeepsProcessedPrefix(t *testing.T) {
	for _, stopAt := range []int{1, 2} {
		manager := batchTestManager(t)
		one := batchTestJob(manager, 1, "completed", false)
		two := batchTestJob(manager, 2, "completed", false)
		base, cancel := context.WithCancel(context.Background())
		ctx := &batchTestCancelContext{Context: base, stopAt: stopAt, cancel: cancel}
		writes := 0
		manager.writeIndex = func(path string, data []byte) error {
			writes++
			return nativeDownloadWrite(path, data)
		}
		result, err := manager.controlBatch(ctx, []string{one.ID, one.ID, two.ID, "missing"}, "archive")
		cancel()
		want := []string{}
		if stopAt == 2 {
			want = append(want, one.ID)
		}
		batchTestResult(t, result, err, want, 3-len(want))
		if writes != len(want) || one.Archived != (stopAt == 2) || two.Archived || ctx.checks != 3 {
			t.Fatal("cancellation lost prefix, processed duplicate, or touched suffix")
		}
	}
}

func TestNativeDownloadBatchGuardsDoNotWrite(t *testing.T) {
	for _, guard := range []string{"empty", "too-many", "command", "closed", "moving", "load-error"} {
		t.Run(guard, func(t *testing.T) {
			manager := batchTestManager(t)
			job := batchTestJob(manager, 1, "completed", false)
			manager.writeIndex = func(string, []byte) error {
				t.Error("invalid request wrote index")
				return nil
			}
			ids, command := []string{job.ID, job.ID}, "archive"
			globalError := false
			switch guard {
			case "empty":
				ids, globalError = nil, true
			case "too-many":
				ids, globalError = make([]string, 501), true
			case "command":
				command, globalError = "invalid", true
			case "closed":
				manager.closed = true
			case "moving":
				manager.moving = true
			case "load-error":
				manager.loadErr = errors.New("下载记录无法解析，原文件已保留")
			}
			result, err := manager.controlBatch(context.Background(), ids, command)
			if (err != nil) != globalError || len(result.Completed) != 0 || job.Archived {
				t.Fatalf("invalid guard result: %+v %v", result, err)
			}
			if !globalError && len(result.Failures) != 1 {
				t.Fatal("manager guard lost per-ID failure")
			}
		})
	}
}

func TestNativeDownloadBatchRemoveTwoPhasesAndCancellation(t *testing.T) {
	manager := batchTestManager(t)
	one := batchTestJob(manager, 1, "completed", false)
	two := batchTestJob(manager, 2, "paused", false)
	file := filepath.Join(manager.jobDirectory(one.nativeDownloadJob), "media.mp4")
	batchTestWriteFile(t, file)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	writes := 0
	manager.writeIndex = func(path string, data []byte) error {
		writes++
		var records []nativeDownloadRecord
		if err := json.Unmarshal(data, &records); err != nil {
			return err
		}
		if writes == 1 {
			if len(records) != 2 || records[0].State != "removing" || records[1].State != "removing" {
				t.Error("first phase did not persist all tombstones")
			}
			if _, err := os.Stat(file); err != nil {
				t.Error("file deleted before removing was durable")
			}
			cancel() // 提交开始后取消不能中断必须执行的删除收尾。
		} else if len(records) != 0 {
			t.Error("final index retained removed jobs")
		}
		return nativeDownloadWrite(path, data)
	}
	result, err := manager.controlBatch(ctx, []string{two.ID, one.ID, two.ID}, "remove")
	batchTestResult(t, result, err, []string{two.ID, one.ID}, 0)
	if writes != 2 || len(manager.jobs) != 0 || len(batchTestIndex(t, manager)) != 0 {
		t.Fatal("remove did not coalesce both phases")
	}
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatal("removed file still exists")
	}
}

func TestNativeDownloadBatchRemoveFailureAndRestart(t *testing.T) {
	manager := batchTestManager(t)
	good := batchTestJob(manager, 1, "completed", false)
	blocked := batchTestJob(manager, 2, "completed", false)
	blocked.Output = "批量测试/第2集.mp4"
	// 非空目录占据成品文件路径，跨平台稳定触发 os.Remove 失败（不依赖权限/root）。
	blocker := filepath.Join(manager.outputFile(blocked.Output), "busy")
	batchTestWriteFile(t, blocker)
	writes := 0
	manager.writeIndex = func(path string, data []byte) error {
		writes++
		return nativeDownloadWrite(path, data)
	}
	result, err := manager.controlBatch(context.Background(), []string{good.ID, blocked.ID, good.ID}, "remove")
	batchTestResult(t, result, err, []string{good.ID}, 1)
	if writes != 2 || blocked.State != "removing" || blocked.Error == "" {
		t.Fatal("delete failure lost retry record")
	}
	result, err = manager.controlBatch(context.Background(), []string{blocked.ID, blocked.ID}, "remove")
	batchTestResult(t, result, err, []string{}, 1)
	if writes != 2 {
		t.Fatal("unchanged failed delete rewrote index")
	}
	reopened := batchTestManager(t)
	reopened.root = manager.root
	if err := reopened.load(); err != nil || len(reopened.jobs) != 1 || reopened.jobs[blocked.ID].State != "removing" {
		t.Fatalf("blocked removal poisoned restart: %v", err)
	}
	if err := os.Remove(blocker); err != nil {
		t.Fatal(err)
	}
	result, err = reopened.controlBatch(context.Background(), []string{blocked.ID}, "remove")
	batchTestResult(t, result, err, []string{blocked.ID}, 0)
	if len(batchTestIndex(t, reopened)) != 0 {
		t.Fatal("retry did not clear persisted tombstone")
	}
}

func TestNativeDownloadBatchRemoveFinalSaveFailureIsRetryable(t *testing.T) {
	for _, recovery := range []string{"retry", "restart", "restart-save-failure"} {
		t.Run(recovery, func(t *testing.T) {
			manager := batchTestManager(t)
			one := batchTestJob(manager, 1, "completed", false)
			two := batchTestJob(manager, 2, "paused", false)
			file := filepath.Join(manager.jobDirectory(one.nativeDownloadJob), "media.mp4")
			batchTestWriteFile(t, file)
			writes := 0
			manager.writeIndex = func(path string, data []byte) error {
				writes++
				if writes == 2 {
					return errors.New("injected final save failure")
				}
				return nativeDownloadWrite(path, data)
			}
			result, err := manager.controlBatch(context.Background(), []string{one.ID, two.ID}, "remove")
			batchTestResult(t, result, err, []string{}, 2)
			if writes != 2 || len(manager.jobs) != 2 || one.State != "removing" || !strings.Contains(one.Error, "文件已删除") {
				t.Fatal("final save failure pretended deletion rolled back")
			}
			if _, err := os.Stat(file); !os.IsNotExist(err) {
				t.Fatal("delete did not happen before failed final save")
			}
			for _, record := range batchTestIndex(t, manager) {
				if record.State != "removing" {
					t.Fatal("durable tombstone missing")
				}
			}
			if recovery == "retry" {
				result, err = manager.controlBatch(context.Background(), []string{two.ID, one.ID}, "remove")
				batchTestResult(t, result, err, []string{two.ID, one.ID}, 0)
				if writes != 3 {
					t.Fatal("retry redundantly saved removing phase")
				}
			} else {
				reopened := batchTestManager(t)
				reopened.root = manager.root
				if recovery == "restart-save-failure" {
					reopened.writeIndex = func(string, []byte) error { return errors.New("restart save failure") }
				}
				if err := reopened.load(); err != nil {
					t.Fatal(err)
				}
				if recovery == "restart-save-failure" {
					if len(reopened.jobs) != 2 || reopened.jobs[one.ID].State != "removing" {
						t.Fatal("restart final save failure dropped retry records")
					}
					reopened.writeIndex = nil
					result, err = reopened.controlBatch(context.Background(), []string{one.ID, two.ID}, "remove")
					batchTestResult(t, result, err, []string{one.ID, two.ID}, 0)
				}
				if len(reopened.jobs) != 0 {
					t.Fatal("restart did not finish durable removals")
				}
			}
			if len(batchTestIndex(t, manager)) != 0 {
				t.Fatal("recovered deletion not saved")
			}
		})
	}
}

func TestNativeDownloadBatchRemoveDefersWorkerAndConverter(t *testing.T) {
	manager := batchTestManager(t)
	worker := batchTestJob(manager, 1, "downloading", false)
	converter := batchTestJob(manager, 2, "converting", false)
	for _, record := range []*nativeDownloadRecord{worker, converter} {
		batchTestWriteFile(t, filepath.Join(manager.jobDirectory(record.nativeDownloadJob), "media.mp4"))
	}
	writes, cancelled := 0, 0
	manager.writeIndex = func(path string, data []byte) error {
		writes++
		return nativeDownloadWrite(path, data)
	}
	manager.active[worker.ID] = func() {
		if writes != 1 {
			t.Error("worker cancelled before removing committed")
		}
		cancelled++
	}
	manager.converting[converter.ID] = true
	result, err := manager.controlBatch(context.Background(), []string{converter.ID, worker.ID}, "remove")
	batchTestResult(t, result, err, []string{converter.ID, worker.ID}, 0)
	result, err = manager.controlBatch(context.Background(), []string{worker.ID, converter.ID, worker.ID}, "remove")
	batchTestResult(t, result, err, []string{worker.ID, converter.ID}, 0)
	if writes != 1 || cancelled != 1 || len(manager.jobs) != 2 {
		t.Fatal("in-flight removal wrote redundant state or cleaned early")
	}
	for _, record := range []*nativeDownloadRecord{worker, converter} {
		if _, err := os.Stat(manager.jobDirectory(record.nativeDownloadJob)); err != nil {
			t.Fatal("in-flight workspace deleted")
		}
	}
	delete(manager.active, worker.ID) // 以下同步调用模拟 worker 完成，不启动网络请求。
	manager.resolve = func(context.Context, nativeDownloadJob) (providerMedia, error) {
		return providerMedia{}, context.Canceled
	}
	manager.workers.Add(1)
	manager.run(context.Background(), worker.nativeDownloadJob)
	if err := manager.finishConversion(converter.ID, "cancel"); err != nil {
		t.Fatal(err)
	}
	if len(manager.jobs) != 0 || len(manager.converting) != 0 || len(batchTestIndex(t, manager)) != 0 {
		t.Fatal("existing callbacks did not finish removal")
	}
}

func TestNativeDownloadBatchWorkerFinalSaveFailureKeepsTombstone(t *testing.T) {
	manager := batchTestManager(t)
	job := batchTestJob(manager, 1, "downloading", false)
	file := filepath.Join(manager.jobDirectory(job.nativeDownloadJob), "media.mp4")
	batchTestWriteFile(t, file)
	manager.active[job.ID] = func() {}
	writes := 0
	manager.writeIndex = func(path string, data []byte) error {
		writes++
		if writes == 2 {
			return errors.New("worker final save failure")
		}
		return nativeDownloadWrite(path, data)
	}
	result, err := manager.controlBatch(context.Background(), []string{job.ID}, "remove")
	batchTestResult(t, result, err, []string{job.ID}, 0)
	manager.resolve = func(context.Context, nativeDownloadJob) (providerMedia, error) {
		return providerMedia{}, context.Canceled
	}
	manager.workers.Add(1)
	manager.run(context.Background(), job.nativeDownloadJob)
	if writes != 2 || manager.jobs[job.ID] == nil || job.State != "removing" || !strings.Contains(job.Error, "文件已删除") {
		t.Fatal("worker final save failure lost retry record")
	}
	result, err = manager.controlBatch(context.Background(), []string{job.ID}, "remove")
	batchTestResult(t, result, err, []string{job.ID}, 0)
	if writes != 3 || len(batchTestIndex(t, manager)) != 0 {
		t.Fatal("worker removal could not be retried")
	}
}

func TestNativeDownloadBatchResumePreservesConversionPending(t *testing.T) {
	manager := batchTestManager(t)
	job := batchTestJob(manager, 1, "failed", false)
	job.File, job.Output, job.ConversionPending = "media.mp4", "批量测试/第1集.mp4", true
	job.Key, job.Revision = "old-key", 7
	job.Bytes = int64(len("synthetic-video"))
	batchTestWriteFile(t, filepath.Join(manager.jobDirectory(job.nativeDownloadJob), job.File))
	batchTestWriteFile(t, manager.outputFile(job.Output))
	writes := 0
	manager.writeIndex = func(path string, data []byte) error {
		writes++
		return nativeDownloadWrite(path, data)
	}
	result, err := manager.controlBatch(context.Background(), []string{job.ID, job.ID}, "resume")
	batchTestResult(t, result, err, []string{job.ID}, 0)
	if writes != 1 || job.State != "converting" || !job.ConversionPending || job.Key != "old-key" || job.Revision != 7 {
		t.Fatal("batch resume damaged pending conversion or redownloaded raw media")
	}
	reopened := batchTestManager(t)
	reopened.root = manager.root
	if err := reopened.load(); err != nil {
		t.Fatal(err)
	}
	recovered := reopened.jobs[job.ID]
	if recovered == nil || recovered.State != "completed" || recovered.ConversionPending || recovered.File != "" || recovered.Key != "" {
		t.Fatal("batch resume broke existing pending conversion recovery")
	}
	if _, err := os.Stat(reopened.outputFile(job.Output)); err != nil {
		t.Fatal("pending conversion recovery lost finished media")
	}
}

func TestNativeDownloadBatchWorkerDeleteFailureRemainsRemoving(t *testing.T) {
	manager := batchTestManager(t)
	job := batchTestJob(manager, 1, "downloading", false)
	job.Output = "批量测试/第1集.mp4"
	blocker := filepath.Join(manager.outputFile(job.Output), "busy")
	batchTestWriteFile(t, blocker)
	manager.active[job.ID] = func() {}
	result, err := manager.controlBatch(context.Background(), []string{job.ID}, "remove")
	batchTestResult(t, result, err, []string{job.ID}, 0)
	manager.resolve = func(context.Context, nativeDownloadJob) (providerMedia, error) {
		return providerMedia{}, context.Canceled
	}
	manager.workers.Add(1)
	manager.run(context.Background(), job.nativeDownloadJob)
	if manager.jobs[job.ID] == nil || job.State != "removing" || job.Error == "" || batchTestIndex(t, manager)[job.ID].State != "removing" {
		t.Fatal("worker delete failure lost durable removal intent")
	}
	if err := os.Remove(blocker); err != nil {
		t.Fatal(err)
	}
	reopened := batchTestManager(t)
	reopened.root = manager.root
	if err := reopened.load(); err != nil || len(reopened.jobs) != 0 {
		t.Fatalf("worker delete failure could not recover after restart: %v", err)
	}
}

func TestNativeDownloadBatchRestartLoadsAllRecordsBeforeCleanup(t *testing.T) {
	manager := batchTestManager(t)
	removed := batchTestJob(manager, 1, "removing", false)
	pending := batchTestJob(manager, 2, "converting", false)
	pending.File, pending.Output, pending.ConversionPending = "media.mp4", "批量测试/第2集.mp4", true
	batchTestWriteFile(t, filepath.Join(manager.jobDirectory(pending.nativeDownloadJob), pending.File))
	batchTestWriteFile(t, manager.outputFile(pending.Output))
	paused := batchTestJob(manager, 3, "queued", false)
	denied := batchTestJob(manager, 4, "removing", false)
	denied.Chapter.Source = "fanguo"
	deniedFile := filepath.Join(manager.jobDirectory(denied.nativeDownloadJob), "media.mp4")
	batchTestWriteFile(t, deniedFile)
	if err := manager.saveLocked(); err != nil {
		t.Fatal(err)
	}
	reopened := batchTestManager(t)
	reopened.root = manager.root
	if err := reopened.load(); err != nil {
		t.Fatal(err)
	}
	index := batchTestIndex(t, reopened)
	if len(index) != 3 || index[removed.ID].ID != "" || index[pending.ID].State != "completed" ||
		index[paused.ID].State != "paused" || index[denied.ID].State != "removing" {
		t.Fatalf("restart lost another record or bypassed source authorization: %+v", index)
	}
	if _, err := os.Stat(deniedFile); err != nil {
		t.Fatal("restart deleted unauthorized source files")
	}
}

func TestNativeDownloadBatchConverterRemovalFailuresAreRetryable(t *testing.T) {
	for _, failure := range []string{"delete", "save"} {
		t.Run(failure, func(t *testing.T) {
			manager := batchTestManager(t)
			job := batchTestJob(manager, 1, "converting", false)
			job.Output = "批量测试/第1集.mp4"
			target := manager.outputFile(job.Output)
			if failure == "delete" {
				batchTestWriteFile(t, filepath.Join(target, "busy"))
			} else {
				batchTestWriteFile(t, target)
			}
			manager.converting[job.ID] = true
			writes := 0
			manager.writeIndex = func(path string, data []byte) error {
				writes++
				if failure == "save" && writes == 2 {
					return errors.New("converter final save failure")
				}
				return nativeDownloadWrite(path, data)
			}
			result, err := manager.controlBatch(context.Background(), []string{job.ID}, "remove")
			batchTestResult(t, result, err, []string{job.ID}, 0)
			err = manager.finishConversion(job.ID, "cancel")
			if (failure == "save") != (err != nil) {
				t.Fatalf("unexpected finish result: %v", err)
			}
			if manager.jobs[job.ID] == nil || job.State != "removing" || job.Error == "" || manager.converting[job.ID] {
				t.Fatal("converter failure lost removal intent or retained conversion lease")
			}
			if failure == "delete" {
				if err := os.Remove(filepath.Join(target, "busy")); err != nil {
					t.Fatal(err)
				}
				reopened := batchTestManager(t)
				reopened.root = manager.root
				if err := reopened.load(); err != nil || len(reopened.jobs) != 0 {
					t.Fatalf("converter removal could not recover after restart: %v", err)
				}
			} else {
				if _, err := os.Stat(target); !os.IsNotExist(err) {
					t.Fatal("save failure unexpectedly restored deleted media")
				}
				result, err = manager.controlBatch(context.Background(), []string{job.ID}, "remove")
				batchTestResult(t, result, err, []string{job.ID}, 0)
				if len(batchTestIndex(t, manager)) != 0 {
					t.Fatal("converter removal retry did not clear index")
				}
			}
		})
	}
}

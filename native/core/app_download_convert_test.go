package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func copyConversion(t *testing.T, manager *nativeDownloads, work nativeDownloadConversion, id string) {
	t.Helper()
	data, err := os.ReadFile(work.Input)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(work.Output, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := manager.finishConversion(id, "done"); err != nil {
		t.Fatal(err)
	}
}

func convertingFixture(t *testing.T, manager *nativeDownloads, drama nativeDrama, index int, bySource bool) string {
	t.Helper()
	id := nativeDownloadID(drama.ID, index)
	record := &nativeDownloadRecord{nativeDownloadJob: nativeDownloadJob{ID: id, Index: index, Drama: drama,
		State: "converting", Bytes: 15, Progress: 1}, File: "media.mp4", Key: "00112233445566778899aabbccddeeff"}
	if bySource {
		record.Folder = drama.Source + "/" + id
	}
	directory := manager.jobDirectory(record.nativeDownloadJob)
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "media.mp4"), []byte("synthetic-video"), 0600); err != nil {
		t.Fatal(err)
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	manager.jobs[id] = record
	if err := manager.saveLocked(); err != nil {
		t.Fatal(err)
	}
	return id
}

func convertFixture(t *testing.T, manager *nativeDownloads, id string) string {
	t.Helper()
	work, err := manager.beginConversion(id)
	if err != nil {
		t.Fatal(err)
	}
	copyConversion(t, manager, work, id)
	manager.mu.Lock()
	defer manager.mu.Unlock()
	record := manager.jobs[id]
	if record.State != "completed" || record.File != "" || record.Key != "" || record.Bytes != 15 {
		t.Fatalf("conversion not recorded: %+v", record)
	}
	return record.Output
}

func TestNativeDownloadConversionNamesFoldersByDrama(t *testing.T) {
	manager := downloadTestManager(t)
	first := nativeDrama{ID: "hongguo:801", Source: "hongguo", Title: " 甲:剧/名? "}
	twin := nativeDrama{ID: "hongguo:802", Source: "hongguo", Title: "甲:剧/名?"}
	device := nativeDrama{ID: "hongguo:803", Source: "hongguo", Title: "con.剧"}
	one := convertingFixture(t, manager, first, 1, false)
	two := convertingFixture(t, manager, first, 2, false)
	other := convertingFixture(t, manager, twin, 1, false)
	sourced := convertingFixture(t, manager, device, 3, true)
	for id, want := range map[string]string{one: "甲_剧_名_/第1集.mp4", two: "甲_剧_名_/第2集.mp4"} {
		if got := convertFixture(t, manager, id); got != want {
			t.Fatalf("output %q, want %q", got, want)
		}
	}
	if got := convertFixture(t, manager, other); got != "甲_剧_名_ (2)/第1集.mp4" {
		t.Fatalf("same title must not share folders: %q", got)
	}
	if got := convertFixture(t, manager, sourced); got != "hongguo/_con.剧/第3集.mp4" {
		t.Fatalf("reserved or source folder: %q", got)
	}
	if _, err := os.Stat(filepath.Join(manager.root, "hongguo", sourced)); !os.IsNotExist(err) {
		t.Fatal("source workspace kept")
	}
	manager.close()
	reopened := newNativeDownloads(manager.engine)
	t.Cleanup(reopened.close)
	if reopened.loadErr != nil || len(reopened.jobs) != 4 {
		t.Fatalf("converted records not reloaded: %v", reopened.loadErr)
	}
	folder := filepath.Join(reopened.root, "甲_剧_名_")
	if err := reopened.control(one, "remove"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(folder, "第2集.mp4")); err != nil {
		t.Fatal("removing one episode touched another")
	}
	if err := reopened.control(two, "remove"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(folder); !os.IsNotExist(err) {
		t.Fatal("empty drama folder kept")
	}
}

func TestNativeDownloadConversionRejectsUnsafeOutput(t *testing.T) {
	manager := downloadTestManager(t)
	drama := nativeDrama{ID: "hongguo:804", Source: "hongguo", Title: "样本"}
	id := nativeDownloadID(drama.ID, 1)
	for _, output := range []string{"../样本/第1集.mp4", "样本/第2集.mp4", "huangdou/样本/第1集.mp4", "a/b/c/第1集.mp4", "样本./第1集.mp4", "NUL/第1集.mp4"} {
		records := []nativeDownloadRecord{{nativeDownloadJob: nativeDownloadJob{ID: id, Index: 1, Drama: drama,
			State: "completed", Bytes: 15}, Output: output}}
		data, _ := json.Marshal(records)
		if err := os.WriteFile(filepath.Join(manager.root, "index.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
		reopened := newNativeDownloads(manager.engine)
		reopened.close()
		if reopened.loadErr == nil {
			t.Fatalf("unsafe output accepted: %s", output)
		}
	}
}

func TestNativeDownloadConversionFailureRetryAndRemoval(t *testing.T) {
	manager := downloadTestManager(t)
	drama := nativeDrama{ID: "hongguo:805", Source: "hongguo", Title: "样本"}
	id := convertingFixture(t, manager, drama, 1, false)
	if _, found, err := manager.localPlan(drama.ID, 1); found || err != nil {
		t.Fatal("converting episode must fall back to online playback")
	}
	if _, err := manager.beginConversion(id); err != nil {
		t.Fatal(err)
	}
	if count, err := manager.engine.workLease("", ""); err != nil || count != 1 {
		t.Fatalf("background service cannot see the running conversion: %d %v", count, err)
	}
	if _, err := manager.beginConversion(id); err == nil {
		t.Fatal("same episode converted twice")
	}
	if err := manager.engine.moveDownloads(context.Background(), t.TempDir()); err == nil || !strings.Contains(err.Error(), "处理完成") {
		t.Fatal("download folder moved during conversion")
	}
	if err := manager.finishConversion(id, "failed"); err != nil {
		t.Fatal(err)
	}
	jobs, _ := manager.snapshot()
	if len(jobs) != 1 || jobs[0].State != "failed" || jobs[0].Error != "转换失败，点击重试" {
		t.Fatalf("failure not recorded: %+v", jobs)
	}
	if count, _ := manager.engine.workLease("", ""); count != 0 {
		t.Fatalf("finished conversion still keeps the service alive: %d", count)
	}
	if err := manager.control(id, "resume"); err != nil {
		t.Fatal(err)
	}
	if jobs, _ = manager.snapshot(); jobs[0].State != "converting" {
		t.Fatalf("retry must convert again without downloading: %+v", jobs)
	}
	work, err := manager.beginConversion(id)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(work.Output, []byte("partial"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := manager.control(id, "remove"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(work.Input); err != nil {
		t.Fatal("files removed while conversion was still running")
	}
	if err := manager.finishConversion(id, "cancel"); err != nil {
		t.Fatal(err)
	}
	if jobs, _ = manager.snapshot(); len(jobs) != 0 {
		t.Fatalf("removed episode kept: %+v", jobs)
	}
	if _, err := os.Stat(filepath.Dir(work.Input)); !os.IsNotExist(err) {
		t.Fatal("removed episode files kept")
	}
	broken := convertingFixture(t, manager, drama, 2, false)
	if err := os.Remove(filepath.Join(manager.root, broken, "media.mp4")); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.beginConversion(broken); err == nil {
		t.Fatal("missing download converted")
	}
	manager.resolve = func(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
		<-ctx.Done()
		return providerMedia{}, ctx.Err()
	}
	if err := manager.control(broken, "resume"); err != nil {
		t.Fatal(err)
	}
	if jobs, _ = manager.snapshot(); len(jobs) != 1 || jobs[0].State != "downloading" {
		t.Fatalf("missing download must be fetched again: %+v", jobs)
	}
}

func TestNativeDownloadConversionIndexFailureRecovery(t *testing.T) {
	for _, recovery := range []string{"finish", "begin", "restart"} {
		t.Run(recovery, func(t *testing.T) {
			manager := downloadTestManager(t)
			drama := nativeDrama{ID: "hongguo:806", Source: "hongguo", Title: "保存恢复"}
			id := convertingFixture(t, manager, drama, 1, false)
			other := convertingFixture(t, manager, drama, 2, false)
			work, err := manager.beginConversion(id)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(work.Output, []byte("converted-video"), 0600); err != nil {
				t.Fatal(err)
			}
			index := filepath.Join(manager.root, "index.json")
			renames := 0
			manager.renameFile = func(from, to string) error {
				if err := os.Rename(from, to); err != nil {
					return err
				}
				renames++
				// rename 已成功后才阻断最终索引提交；预提交索引保存在 backup。
				if err := os.Rename(index, index+".backup"); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(index, 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(index, "block"), []byte("block"), 0600); err != nil {
					t.Fatal(err)
				}
				return nil
			}
			if err := manager.finishConversion(id, "done"); err == nil {
				t.Fatal("index failure was ignored")
			}
			record := manager.jobs[id]
			output := "保存恢复/第1集.mp4"
			if renames != 1 || record.State != "converting" || record.Output != output || !record.ConversionPending || record.File == "" || record.Key == "" {
				t.Fatalf("unrecoverable conversion: %+v, renames=%d", record, renames)
			}
			if got, err := os.ReadFile(work.Input); err != nil || string(got) != "synthetic-video" {
				t.Fatalf("original download lost: %q %v", got, err)
			}
			data, err := os.ReadFile(index + ".backup")
			var saved []nativeDownloadRecord
			if err != nil || json.Unmarshal(data, &saved) != nil {
				t.Fatalf("missing write-ahead index: %v", err)
			}
			found := false
			for _, item := range saved {
				if item.ID == id {
					found = item.ConversionPending && item.Output == output && item.File != "" && item.Key != ""
				}
			}
			if !found {
				t.Fatal("rename published an untracked video")
			}
			if err := os.RemoveAll(index); err != nil {
				t.Fatal(err)
			}
			if err := os.Rename(index+".backup", index); err != nil {
				t.Fatal(err)
			}
			manager.renameFile = nil
			switch recovery {
			case "finish":
				if err := manager.finishConversion(id, "done"); err != nil {
					t.Fatal(err)
				}
			case "begin":
				if _, err := manager.beginConversion(id); err == nil {
					t.Fatal("already published video was scheduled for conversion again")
				}
			case "restart":
				// 不调用 close 写回内存，模拟进程在最终提交失败后直接退出。
				manager.loadErr = errors.New("simulated stopped process")
				manager = newNativeDownloads(manager.engine)
				t.Cleanup(manager.close)
				if manager.loadErr != nil {
					t.Fatal(manager.loadErr)
				}
			}
			record = manager.jobs[id]
			if record.State != "completed" || record.Output != output || record.ConversionPending || record.ConversionSHA256 != "" || record.ConversionSize != 0 || record.File != "" || record.Key != "" || len(manager.jobs) != 2 || manager.jobs[other] == nil {
				t.Fatalf("recovery did not commit the same output: %+v", record)
			}
			if got, err := os.ReadFile(manager.outputFile(output)); err != nil || string(got) != "converted-video" {
				t.Fatalf("recovery lost converted data: %q %v", got, err)
			}
			if _, err := os.Stat(filepath.Dir(work.Input)); !os.IsNotExist(err) {
				t.Fatal("committed workspace not cleaned")
			}
			if _, err := os.Stat(filepath.Join(manager.root, "保存恢复 (2)")); !os.IsNotExist(err) {
				t.Fatal("recovery created a duplicate folder")
			}
			files, err := filepath.Glob(filepath.Join(manager.root, "*", "第1集.mp4"))
			if err != nil || len(files) != 1 {
				t.Fatalf("orphan or duplicate video: %v %v", files, err)
			}
		})
	}
}

func TestNativeDownloadConversionDoesNotOverwriteExistingEpisode(t *testing.T) {
	manager := downloadTestManager(t)
	drama := nativeDrama{ID: "hongguo:807", Source: "hongguo", Title: "保留成品"}
	one := convertingFixture(t, manager, drama, 1, false)
	convertFixture(t, manager, one)
	two := convertingFixture(t, manager, drama, 2, false)
	target := manager.outputFile("保留成品/第2集.mp4")
	if err := os.WriteFile(target, []byte("existing-video"), 0600); err != nil {
		t.Fatal(err)
	}
	work, err := manager.beginConversion(two)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(work.Output, []byte("replacement"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := manager.finishConversion(two, "done"); err != nil {
		t.Fatal(err)
	}
	if record := manager.jobs[two]; record.State != "failed" || record.Output != "" || record.ConversionPending {
		t.Fatalf("existing output claimed: %+v", record)
	}
	if got, err := os.ReadFile(target); err != nil || string(got) != "existing-video" {
		t.Fatalf("existing video overwritten: %q %v", got, err)
	}
	if _, err := os.Stat(work.Input); err != nil {
		t.Fatal("failed conversion deleted original download")
	}
	if err := manager.control(two, "remove"); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(target); err != nil || string(got) != "existing-video" {
		t.Fatalf("removing failed task deleted unrelated output: %q %v", got, err)
	}
}

func TestNativeDownloadConversionReservedPathSurvivesRestart(t *testing.T) {
	manager := downloadTestManager(t)
	drama := nativeDrama{ID: "hongguo:808", Source: "hongguo", Title: "预留路径"}
	id := convertingFixture(t, manager, drama, 1, false)
	work, err := manager.beginConversion(id)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(work.Output, []byte("converted-video"), 0600); err != nil {
		t.Fatal(err)
	}
	manager.renameFile = func(string, string) error { return errors.New("injected rename failure") }
	if err := manager.finishConversion(id, "done"); err != nil {
		t.Fatal(err)
	}
	if record := manager.jobs[id]; record.State != "failed" || record.Output != "预留路径/第1集.mp4" || record.ConversionPending || record.ConversionSHA256 != "" || record.ConversionSize != 0 {
		t.Fatalf("failed rename lost its reservation: %+v", record)
	}
	manager.close()
	reopened := newNativeDownloads(manager.engine)
	t.Cleanup(reopened.close)
	if reopened.loadErr != nil {
		t.Fatal(reopened.loadErr)
	}
	if err := reopened.control(id, "resume"); err != nil {
		t.Fatal(err)
	}
	if output := convertFixture(t, reopened, id); output != "预留路径/第1集.mp4" {
		t.Fatalf("retry did not reuse reserved folder: %s", output)
	}
	if _, err := os.Stat(filepath.Join(manager.root, "预留路径 (2)")); !os.IsNotExist(err) {
		t.Fatal("failed rename retry created another directory")
	}
}

// 同长度旧成品也不能冒充新成品；覆盖预提交、替换、失败状态保存三个边界。
func TestNativeDownloadConversionKeepsRawWhenReplacingFails(t *testing.T) {
	for _, failure := range []string{"precommit", "rename", "rename-save", "precommit-crash"} {
		for _, restart := range []bool{false, true} {
			name := failure + "/retry"
			if restart {
				name = failure + "/restart"
			}
			t.Run(name, func(t *testing.T) {
				manager := batchTestManager(t)
				job := batchTestJob(manager, 1, "converting", false)
				job.File, job.Key, job.Output = "media.mp4", "raw-key", "修复恢复/第1集.mp4"
				job.Bytes = int64(len("synthetic-video"))
				raw := filepath.Join(manager.jobDirectory(job.nativeDownloadJob), job.File)
				target := manager.outputFile(job.Output)
				batchTestWriteFile(t, raw)
				batchTestWriteFile(t, target)
				if err := os.WriteFile(target, []byte("obsolete-result"), 0600); err != nil {
					t.Fatal(err)
				}
				if err := manager.saveLocked(); err != nil {
					t.Fatal(err)
				}
				work, err := manager.beginConversion(job.ID)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(work.Output, []byte("converted-video"), 0600); err != nil {
					t.Fatal(err)
				}
				crash := errors.New("crash after durable precommit, before replacement")
				writes := 0
				manager.writeIndex = func(path string, data []byte) error {
					writes++
					if failure == "precommit" || failure == "rename-save" && writes > 1 {
						return errors.New("injected index failure")
					}
					if err := nativeDownloadWrite(path, data); err != nil {
						return err
					}
					if failure == "precommit-crash" {
						panic(crash)
					}
					return nil
				}
				manager.renameFile = func(string, string) error { return errors.New("injected rename failure") }
				func() {
					defer func() {
						if caught := recover(); caught != nil {
							if caught != crash {
								panic(caught)
							}
						} else if failure == "precommit-crash" {
							t.Fatal("crash injection did not run")
						}
					}()
					err = manager.finishConversion(job.ID, "done")
					if (failure != "rename") != (err != nil) {
						t.Fatalf("unexpected failure result: %v", err)
					}
				}()
				pending := failure == "rename-save" || failure == "precommit-crash"
				if job.ConversionPending != pending || batchTestIndex(t, manager)[job.ID].ConversionPending != pending {
					t.Fatalf("incorrect failure rollback: %+v", job)
				}
				if pending && (len(job.ConversionSHA256) != 64 || job.ConversionSize != int64(len("converted-video"))) {
					t.Fatal("precommit did not record new output identity")
				}
				manager.writeIndex, manager.renameFile = nil, nil
				if restart {
					reopened := batchTestManager(t)
					reopened.root = manager.root
					if err := reopened.load(); err != nil {
						t.Fatal(err)
					}
					manager, job = reopened, reopened.jobs[job.ID]
				}
				if got, err := os.ReadFile(target); err != nil || string(got) != "obsolete-result" {
					t.Fatalf("old target was not preserved/restored: %q %v", got, err)
				}
				if got, err := os.ReadFile(raw); err != nil || string(got) != "synthetic-video" {
					t.Fatalf("new raw download lost: %q %v", got, err)
				}
				if job.State == "completed" || job.File == "" || job.Key != "raw-key" {
					t.Fatalf("old output incorrectly committed: %+v", job)
				}
				if err := manager.control(job.ID, "resume"); err != nil {
					t.Fatal(err)
				}
				work, err = manager.beginConversion(job.ID)
				if err != nil {
					t.Fatalf("retry did not retain raw conversion input: %v", err)
				}
				if job.ConversionPending || job.ConversionSHA256 != "" || job.ConversionSize != 0 {
					t.Fatalf("stale commit identity retained on retry: %+v", job)
				}
				copyConversion(t, manager, work, job.ID)
				if got, err := os.ReadFile(target); err != nil || string(got) != "synthetic-video" {
					t.Fatalf("retry did not replace old output: %q %v", got, err)
				}
				if job.State != "completed" || job.ConversionPending || job.ConversionSHA256 != "" || job.ConversionSize != 0 {
					t.Fatalf("retry did not clear commit identity: %+v", job)
				}
			})
		}
	}
}

func TestNativeDownloadConversionLegacyPendingPreservesRaw(t *testing.T) {
	manager := batchTestManager(t)
	job := batchTestJob(manager, 1, "converting", false)
	job.File, job.Output, job.ConversionPending = "media.mp4", "旧索引/第1集.mp4", true
	raw := filepath.Join(manager.jobDirectory(job.nativeDownloadJob), job.File)
	batchTestWriteFile(t, raw)
	batchTestWriteFile(t, manager.outputFile(job.Output))
	if err := manager.saveLocked(); err != nil {
		t.Fatal(err)
	}
	// 撤销无身份旧标记也必须可回滚，索引只读时不得删除原下载。
	manager.writeIndex = func(string, []byte) error { return errors.New("injected reset failure") }
	if err := manager.recoverConversionLocked(job); err == nil || !job.ConversionPending {
		t.Fatal("failed legacy reset did not retain pending state")
	}
	reopened := batchTestManager(t)
	reopened.root = manager.root
	if err := reopened.load(); err != nil {
		t.Fatalf("legacy index rejected: %v", err)
	}
	recovered := reopened.jobs[job.ID]
	if recovered.State != "converting" || recovered.ConversionPending || recovered.File != "media.mp4" {
		t.Fatalf("legacy pending output guessed as new: %+v", recovered)
	}
	if _, err := os.Stat(raw); err != nil {
		t.Fatal("legacy recovery removed raw download")
	}
	work, err := reopened.beginConversion(job.ID)
	if err != nil {
		t.Fatal(err)
	}
	copyConversion(t, reopened, work, job.ID)
}

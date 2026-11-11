package core

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func normalizationFixture(t *testing.T, manager *nativeDownloads, index int) (string, string, *nativeDownloadIdentity) {
	t.Helper()
	id := convertingFixture(t, manager, nativeDrama{ID: "hongguo:normalize", Source: "hongguo", Title: "标准化测试"}, index, false)
	target := manager.outputFile(convertFixture(t, manager, id))
	record := manager.jobs[id]
	record.Created, record.Revision = 100, 7
	if err := manager.saveLocked(); err != nil {
		t.Fatal(err)
	}
	return id, target, &nativeDownloadIdentity{Created: record.Created, Revision: record.Revision}
}

func normalizationWrite(t *testing.T, name, data string) {
	t.Helper()
	if err := os.WriteFile(name, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
}

func normalizationContent(t *testing.T, name, want string) {
	t.Helper()
	got, err := os.ReadFile(name)
	if err != nil || string(got) != want {
		t.Fatalf("%s: got %q, want %q, error %v", name, got, want, err)
	}
}

func normalizationAbsent(t *testing.T, names ...string) {
	t.Helper()
	for _, name := range names {
		if _, err := os.Lstat(name); !os.IsNotExist(err) {
			t.Fatalf("expected absent %s: %v", name, err)
		}
	}
}

func TestNativeNormalizationReplacesOnlySelectedEpisode(t *testing.T) {
	manager := downloadTestManager(t)
	id, target, expected := normalizationFixture(t, manager, 1)
	otherID, otherTarget, _ := normalizationFixture(t, manager, 2)
	other := *manager.jobs[otherID]
	work, err := manager.beginNormalization(id, expected)
	if err != nil {
		t.Fatal(err)
	}
	if work.Input != target || work.Output != target+nativeNormalizationSuffix || work.Key != "" || !manager.converting[id] {
		t.Fatalf("invalid normalization work: %+v", work)
	}
	if _, err := manager.beginNormalization(id, expected); err == nil {
		t.Fatal("duplicate normalization accepted")
	}
	normalizationWrite(t, work.Output, "normalized-video-longer")
	job, err := manager.finishNormalization(id, expected, "done")
	if err != nil {
		t.Fatal(err)
	}
	if job.ID != id || job.Revision != 8 || job.Bytes != 23 || job.Total != 23 || job.State != "completed" || manager.converting[id] || manager.jobs[id].NormalizationPending {
		t.Fatalf("normalization not committed: %+v", job)
	}
	if !reflect.DeepEqual(*manager.jobs[otherID], other) {
		t.Fatal("neighbor record changed")
	}
	normalizationContent(t, target, "normalized-video-longer")
	normalizationContent(t, otherTarget, "synthetic-video")
	normalizationAbsent(t, work.Output, target+nativeNormalizationBackup)
	reopened := newNativeDownloads(manager.engine)
	t.Cleanup(reopened.close)
	if reopened.loadErr != nil || reopened.jobs[id].Revision != 8 || reopened.jobs[id].Output != manager.jobs[id].Output {
		t.Fatalf("commit not persisted: %v", reopened.loadErr)
	}
}

func TestNativeNormalizationCancelFailedKeepOriginal(t *testing.T) {
	for _, result := range []string{"cancel", "failed"} {
		t.Run(result, func(t *testing.T) {
			manager := downloadTestManager(t)
			id, target, expected := normalizationFixture(t, manager, 1)
			previous := *manager.jobs[id]
			work, err := manager.beginNormalization(id, expected)
			if err != nil {
				t.Fatal(err)
			}
			normalizationWrite(t, work.Output, "partial")
			if _, err := manager.finishNormalization(id, expected, result); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(*manager.jobs[id], previous) || manager.converting[id] {
				t.Fatal("cancel/failed changed completed job or retained lock")
			}
			normalizationContent(t, target, "synthetic-video")
			normalizationAbsent(t, work.Output, target+nativeNormalizationBackup)
		})
	}
}

func TestNativeNormalizationRejectsStaleIdentityAndBusy(t *testing.T) {
	manager := downloadTestManager(t)
	id, target, expected := normalizationFixture(t, manager, 1)
	for _, stale := range []*nativeDownloadIdentity{nil, {Created: 99, Revision: 7}, {Created: 100, Revision: 6}} {
		if _, err := manager.beginNormalization(id, stale); err == nil || manager.converting[id] {
			t.Fatal("stale begin accepted")
		}
	}
	manager.moving = true
	if _, err := manager.beginNormalization(id, expected); err == nil {
		t.Fatal("begin during move accepted")
	}
	manager.moving = false
	if _, err := manager.beginNormalization(id, expected); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.finishNormalization(id, &nativeDownloadIdentity{Created: 100, Revision: 6}, "done"); err == nil || !manager.converting[id] {
		t.Fatal("stale finish accepted or released another operation's lock")
	}
	normalizationContent(t, target, "synthetic-video")
	if manager.jobs[id].Revision != 7 {
		t.Fatal("stale finish changed revision")
	}
	if _, err := manager.finishNormalization(id, expected, "cancel"); err != nil || manager.converting[id] {
		t.Fatal("matching cancellation did not release lock")
	}
}

func TestNativeNormalizationRollbackFailures(t *testing.T) {
	for _, failure := range []string{"pending-index", "first-rename", "second-rename", "first-rename-after", "second-rename-after", "commit-index", "rollback-index"} {
		t.Run(failure, func(t *testing.T) {
			manager := downloadTestManager(t)
			id, target, expected := normalizationFixture(t, manager, 1)
			previous := manager.jobs[id].nativeDownloadJob
			work, err := manager.beginNormalization(id, expected)
			if err != nil {
				t.Fatal(err)
			}
			normalizationWrite(t, work.Output, "new-video")
			renames, writes := 0, 0
			manager.renameFile = func(from, to string) error {
				renames++
				fail := failure == "first-rename" && renames == 1 || failure == "second-rename" && renames == 2
				after := failure == "first-rename-after" && renames == 1 || failure == "second-rename-after" && renames == 2
				if fail {
					return errors.New("injected rename failure")
				}
				if err := os.Rename(from, to); err != nil {
					return err
				}
				if after {
					return errors.New("injected error after rename")
				}
				return nil
			}
			manager.writeIndex = func(name string, data []byte) error {
				writes++
				if failure == "pending-index" && writes == 1 || failure == "commit-index" && writes == 2 || failure == "rollback-index" && writes >= 2 {
					return errors.New("injected index failure")
				}
				return nativeDownloadWrite(name, data)
			}
			if _, err := manager.finishNormalization(id, expected, "done"); err == nil {
				t.Fatal("injected failure not reported")
			}
			if manager.converting[id] || !reflect.DeepEqual(manager.jobs[id].nativeDownloadJob, previous) {
				t.Fatalf("failed transaction changed job: %+v", manager.jobs[id])
			}
			normalizationContent(t, target, "synthetic-video")
			normalizationAbsent(t, target+nativeNormalizationBackup)
			manager.renameFile, manager.writeIndex = nil, nil
			reopened := newNativeDownloads(manager.engine)
			t.Cleanup(reopened.close)
			if reopened.loadErr != nil || reopened.jobs[id].NormalizationPending || reopened.jobs[id].Revision != 7 {
				t.Fatalf("rollback restart failed: %v %+v", reopened.loadErr, reopened.jobs[id])
			}
			normalizationContent(t, target, "synthetic-video")
			normalizationAbsent(t, work.Output, target+nativeNormalizationBackup)
		})
	}
}

func TestNativeNormalizationPendingRestartRecovery(t *testing.T) {
	for _, stage := range []string{"pending", "old-moved", "new-moved", "committed"} {
		t.Run(stage, func(t *testing.T) {
			manager := downloadTestManager(t)
			id, target, _ := normalizationFixture(t, manager, 1)
			record := manager.jobs[id]
			temporary, backup := target+nativeNormalizationSuffix, target+nativeNormalizationBackup
			// 与原文件等长，验证恢复不能仅凭长度误认旧视频。
			normalizationWrite(t, temporary, "normalized-data")
			hash, size, err := nativeConversionIdentity(temporary)
			if err != nil {
				t.Fatal(err)
			}
			record.NormalizationPending, record.NormalizationSHA256, record.NormalizationSize = true, hash, size
			if err := manager.saveLocked(); err != nil {
				t.Fatal(err)
			}
			if stage != "pending" {
				if err := os.Rename(target, backup); err != nil {
					t.Fatal(err)
				}
			}
			if stage == "new-moved" || stage == "committed" {
				if err := os.Rename(temporary, target); err != nil {
					t.Fatal(err)
				}
			}
			if stage == "committed" {
				record.Revision++
				record.Bytes, record.Total = size, size
				record.clearNormalizationPending()
				if err := manager.saveLocked(); err != nil {
					t.Fatal(err)
				}
			}
			reopened := newNativeDownloads(manager.engine)
			t.Cleanup(reopened.close)
			if reopened.loadErr != nil || reopened.jobs[id].NormalizationPending {
				t.Fatalf("pending recovery failed: %v %+v", reopened.loadErr, reopened.jobs[id])
			}
			want, revision := "synthetic-video", int64(7)
			if stage == "new-moved" || stage == "committed" {
				want, revision = "normalized-data", 8
			}
			normalizationContent(t, target, want)
			if reopened.jobs[id].Revision != revision || reopened.jobs[id].Bytes != int64(len(want)) || reopened.jobs[id].Total != int64(len(want)) {
				t.Fatalf("wrong recovered job: %+v", reopened.jobs[id])
			}
			normalizationAbsent(t, temporary, backup)
			if err := reopened.recoverNormalizationLocked(reopened.jobs[id]); err != nil || reopened.jobs[id].Revision != revision {
				t.Fatalf("recovery not idempotent: %v", err)
			}
		})
	}
}

func TestNativeNormalizationRemovingCompletesDeletion(t *testing.T) {
	for _, result := range []string{"done", "cancel", "failed"} {
		t.Run(result, func(t *testing.T) {
			manager := downloadTestManager(t)
			id, target, expected := normalizationFixture(t, manager, 1)
			_, neighbor, _ := normalizationFixture(t, manager, 2)
			work, err := manager.beginNormalization(id, expected)
			if err != nil {
				t.Fatal(err)
			}
			normalizationWrite(t, work.Output, "new-video")
			if err := manager.controlExpected(id, "remove", expected); err != nil {
				t.Fatal(err)
			}
			if !manager.converting[id] || manager.jobs[id].State != "removing" {
				t.Fatal("remove did not wait for normalization")
			}
			normalizationContent(t, target, "synthetic-video")
			if _, err := manager.finishNormalization(id, expected, result); err != nil {
				t.Fatal(err)
			}
			if manager.jobs[id] != nil || manager.converting[id] {
				t.Fatal("removing record or lock retained")
			}
			normalizationAbsent(t, target, work.Output, target+nativeNormalizationBackup)
			normalizationContent(t, neighbor, "synthetic-video")
		})
	}
}

func TestNativeNormalizationRejectsNonregularFiles(t *testing.T) {
	for _, kind := range []string{"target", "temporary", "backup", "symlink", "empty"} {
		t.Run(kind, func(t *testing.T) {
			manager := downloadTestManager(t)
			id, target, expected := normalizationFixture(t, manager, 1)
			work, err := manager.beginNormalization(id, expected)
			if err != nil {
				t.Fatal(err)
			}
			normalizationWrite(t, work.Output, "new-video")
			switch kind {
			case "target":
				if err := os.Remove(target); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(target, 0700); err != nil {
					t.Fatal(err)
				}
			case "temporary":
				if err := os.Remove(work.Output); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(work.Output, 0700); err != nil {
					t.Fatal(err)
				}
			case "backup":
				if err := os.Mkdir(target+nativeNormalizationBackup, 0700); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				if err := os.Remove(work.Output); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(target, work.Output); err != nil {
					t.Skipf("symlink unavailable: %v", err)
				}
			case "empty":
				normalizationWrite(t, work.Output, "")
			}
			if _, err := manager.finishNormalization(id, expected, "done"); err == nil || manager.converting[id] {
				t.Fatal("invalid output accepted or lock retained")
			}
			if kind != "target" {
				normalizationContent(t, target, "synthetic-video")
			}
			if manager.jobs[id].Revision != 7 || manager.jobs[id].NormalizationPending {
				t.Fatal("invalid file changed transaction")
			}
		})
	}
}

func TestNativeNormalizationRemovingIndexFailureRecovers(t *testing.T) {
	manager := downloadTestManager(t)
	id, target, expected := normalizationFixture(t, manager, 1)
	work, err := manager.beginNormalization(id, expected)
	if err != nil {
		t.Fatal(err)
	}
	normalizationWrite(t, work.Output, "partial")
	if err := manager.controlExpected(id, "remove", expected); err != nil {
		t.Fatal(err)
	}
	manager.writeIndex = func(string, []byte) error { return errors.New("index unavailable") }
	if _, err := manager.finishNormalization(id, expected, "cancel"); err == nil || manager.converting[id] || manager.jobs[id] == nil || manager.jobs[id].State != "removing" {
		t.Fatal("failed deletion index lost retry state")
	}
	normalizationAbsent(t, target, work.Output)
	manager.writeIndex = nil
	reopened := newNativeDownloads(manager.engine)
	t.Cleanup(reopened.close)
	if reopened.loadErr != nil || reopened.jobs[id] != nil {
		t.Fatalf("removing restart not cleaned: %v", reopened.loadErr)
	}
	// 单集目录允许清理；下载根目录仍应保留索引。
	if _, err := os.Stat(filepath.Join(manager.root, "index.json")); err != nil {
		t.Fatal(err)
	}
}

func TestNativeNormalizationRecoveryCommitFailureKeepsBackup(t *testing.T) {
	manager := downloadTestManager(t)
	id, target, _ := normalizationFixture(t, manager, 1)
	record := manager.jobs[id]
	temporary, backup := target+nativeNormalizationSuffix, target+nativeNormalizationBackup
	normalizationWrite(t, temporary, "normalized-data")
	hash, size, err := nativeConversionIdentity(temporary)
	if err != nil {
		t.Fatal(err)
	}
	record.NormalizationPending, record.NormalizationSHA256, record.NormalizationSize = true, hash, size
	if err := manager.saveLocked(); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(target, backup); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(temporary, target); err != nil {
		t.Fatal(err)
	}
	manager.writeIndex = func(string, []byte) error { return errors.New("index unavailable") }
	if err := manager.recoverNormalizationLocked(record); err == nil || !record.NormalizationPending || record.Revision != 7 {
		t.Fatal("failed recovery lost pending identity")
	}
	normalizationContent(t, backup, "synthetic-video")
	normalizationContent(t, target, "normalized-data")
	manager.writeIndex = nil
	if err := manager.recoverNormalizationLocked(record); err != nil || record.NormalizationPending || record.Revision != 8 {
		t.Fatalf("recovery retry failed: %v %+v", err, record)
	}
	normalizationAbsent(t, backup)
}

func TestNativeNormalizationCleanupOnlyOwnSuffixes(t *testing.T) {
	manager := downloadTestManager(t)
	id, target, expected := normalizationFixture(t, manager, 1)
	foreign := target + ".user.bak"
	normalizationWrite(t, foreign, "unrelated")
	normalizationWrite(t, target+nativeNormalizationSuffix, "orphaned-output")
	work, err := manager.beginNormalization(id, expected)
	if err != nil {
		t.Fatal(err)
	}
	normalizationAbsent(t, work.Output)
	if _, err := manager.finishNormalization(id, expected, "cancel"); err != nil {
		t.Fatal(err)
	}
	if err := manager.controlExpected(id, "remove", expected); err != nil {
		t.Fatal(err)
	}
	normalizationContent(t, foreign, "unrelated")
}

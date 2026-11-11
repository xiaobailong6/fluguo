package core

import (
	"os"
	"testing"
)

func TestExportCleanupChecksDownloadIdentity(t *testing.T) {
	manager := downloadTestManager(t)
	defer manager.close()
	drama := nativeDrama{ID: "hongguo:export-identity", Source: "hongguo", Title: "导出身份"}
	id := convertingFixture(t, manager, drama, 1, false)
	output := convertFixture(t, manager, id)
	manager.mu.Lock()
	record := manager.jobs[id]
	record.Created = 100
	record.Revision = 2
	manager.mu.Unlock()

	for _, old := range []nativeDownloadIdentity{
		{Created: 99, Revision: 2},
		{Created: 100, Revision: 1},
	} {
		if err := manager.controlExpected(id, "remove", &old); err == nil {
			t.Fatal("stale export deleted a replacement download")
		}
		if _, err := os.Stat(manager.outputFile(output)); err != nil {
			t.Fatalf("replacement file changed: %v", err)
		}
	}
	if err := manager.controlExpected(id, "remove", &nativeDownloadIdentity{Created: 100, Revision: 2}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(manager.outputFile(output)); !os.IsNotExist(err) {
		t.Fatalf("matching exported download not removed: %v", err)
	}
	if err := manager.controlExpected(id, "remove", &nativeDownloadIdentity{Created: 100, Revision: 2}); err != nil {
		t.Fatalf("already removed export cleanup is not idempotent: %v", err)
	}
}

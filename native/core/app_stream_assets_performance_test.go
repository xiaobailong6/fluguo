package core

import (
	"fmt"
	"testing"
)

func stableAssetSession(count int) (*nativeStreamSession, []string) {
	session := &nativeStreamSession{index: nativeStreamAssetIndex{roots: map[string]bool{"entry": true}}}
	assets := make(map[string]nativeStreamAsset, count)
	ids := make([]string, count)
	for i := range ids {
		ids[i] = fmt.Sprintf("segment-%d", i)
		assets[ids[i]] = nativeStreamAsset{address: ids[i]}
	}
	release, err := session.commitPlaylist("entry", assets)
	if err != nil {
		panic(err)
	}
	release()
	return session, ids
}

func TestNativeStreamStable4000ReleasesDoNotPrune(t *testing.T) {
	session, ids := stableAssetSession(4000)
	before := session.index.pruneCount
	for round := 0; round < 2; round++ {
		for _, id := range ids {
			_, release, found := session.acquireAsset(id)
			if !found {
				t.Fatal("stable asset disappeared", id)
			}
			release()
		}
	}
	if session.index.pruneCount != before || len(session.assets) != 4000 || len(session.index.active) != 0 {
		t.Fatalf("stable releases scanned index: %d -> %d", before, session.index.pruneCount)
	}
}

func TestNativeStreamRetiredGenerationPrunesOnlyOnLastLease(t *testing.T) {
	session, ids := stableAssetSession(2)
	_, first, _ := session.acquireAsset(ids[0])
	_, last, _ := session.acquireAsset(ids[1])
	for i := 0; i < 3; i++ {
		release, err := session.commitPlaylist("entry", map[string]nativeStreamAsset{fmt.Sprint(i): {}})
		if err != nil {
			t.Fatal(err)
		}
		release()
	}
	before := session.index.pruneCount
	first()
	if session.index.pruneCount != before {
		t.Fatal("pruned before last old lease")
	}
	if _, ok := session.assets[ids[0]]; !ok {
		t.Fatal("lost whole-generation dependency")
	}
	last()
	if session.index.pruneCount != before+1 {
		t.Fatal("last old lease did not collect")
	}
	if _, ok := session.assets[ids[0]]; ok {
		t.Fatal("retired generation survived")
	}
	session.clearAssets()
	session.cacheAsset(ids[0], nativeStreamAsset{}, false)
	if len(session.assets) != 0 {
		t.Fatal("late cache revived closed session")
	}
}

func BenchmarkNativeStreamStable4000AcquireRelease(b *testing.B) {
	session, ids := stableAssetSession(4000)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, release, ok := session.acquireAsset(ids[i%len(ids)])
		if !ok {
			b.Fatal("missing asset")
		}
		release()
	}
	b.StopTimer()
	if session.index.pruneCount != 0 {
		b.Fatal("stable release pruned")
	}
}

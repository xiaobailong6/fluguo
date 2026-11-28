package core

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"
)

func TestNativeFollowSeasonsBackgroundDeadlineAndCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		if request.Context().Value(backgroundCatalogKey{}) != true {
			t.Fatal("follow check did not use background catalog priority")
		}
		deadline, ok := request.Context().Deadline()
		if !ok || time.Until(deadline) > 20*time.Second {
			t.Fatal("follow check is not bounded by its deadline")
		}
		cancel()
		return nil, request.Context().Err()
	})
	engine := &nativeEngine{downloader: d}
	_, err := engine.nativeFollowSeasons(ctx, nativeDrama{ID: "hongguo:101", Source: sourceHongguo})
	if !errors.Is(err, context.Canceled) || calls == 0 || len(engine.seasons) != 0 {
		t.Fatal("cancelled follow check must not populate cache", err, calls)
	}
}

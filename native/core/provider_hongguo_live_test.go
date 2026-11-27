package core

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"testing"
	"time"
)

// Mock responses cannot detect a signature rejected with HTTP 200 and no body.
// This opt-in check uses fresh anonymous devices and temporary application data.
// It follows the production resolver and loopback proxy, reading only 64 KiB per
// episode. It does not claim to validate video decoding or on-device rendering.
func TestHongguoPlaybackLive(t *testing.T) {
	if os.Getenv("VERIFY_HONGGUO_PLAYBACK") != "1" {
		t.Skip("set VERIFY_HONGGUO_PLAYBACK=1 for live catalogue, playback and media checks")
	}
	engine, err := newNativeEngine(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if engine.stream != nil {
			_ = engine.stream.server.Close()
		}
		engine.downloads.close()
	})
	d := engine.downloader
	d.cfg.Retries, d.cfg.MaxPagesPerSort = 1, 1
	for _, category := range []string{"short_play", "comic_series", "ai_series"} {
		t.Run(category, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
			defer cancel()
			dramas, err := d.fetchHongguoAppCatalogCategory(ctx, category)
			if err != nil || len(dramas) == 0 {
				t.Fatalf("catalogue count=%d error=%v", len(dramas), publicError(err))
			}
			drama := dramas[0]
			_, seriesID, _ := splitProviderDramaID(drama.ID)
			detail, err := d.hongguoAppDetail(ctx, seriesID)
			if err != nil || len(detail.Chapters) == 0 {
				t.Fatalf("episodes=%d error=%v", len(detail.Chapters), publicError(err))
			}
			t.Logf("title=%s episodes=%d", drama.DisplayTitle(), len(detail.Chapters))
			indices := []int{0}
			if len(detail.Chapters) > 1 {
				indices = append(indices, len(detail.Chapters)-1)
			}
			for _, index := range indices {
				t.Run(fmt.Sprintf("episode_%d", index+1), func(t *testing.T) {
					media, err := d.resolveHongguoMedia(ctx, Task{DramaID: drama.ID, Chapter: detail.Chapters[index], Index: index + 1})
					if err != nil {
						t.Fatal(publicError(err))
					}
					choice := nativePlaybackChoices(media, 0)
					choice.source = sourceHongguo
					plan, err := engine.nativeOpenPlayback(ctx, choice)
					if err != nil {
						t.Fatal(publicError(err))
					}
					defer engine.nativeReleasePlayback(plan.Session)
					request, err := http.NewRequestWithContext(ctx, http.MethodGet, plan.URL, nil)
					if err != nil {
						t.Fatal(publicError(err))
					}
					request.Header.Set("Range", "bytes=0-65535")
					response, err := http.DefaultClient.Do(request)
					if err != nil {
						t.Fatal(publicError(err))
					}
					defer response.Body.Close()
					prefix, err := io.ReadAll(io.LimitReader(response.Body, 65536))
					if err != nil || response.StatusCode != http.StatusPartialContent || len(prefix) != 65536 {
						t.Fatalf("media HTTP=%d bytes=%d error=%v", response.StatusCode, len(prefix), publicError(err))
					}
					if string(prefix[4:8]) != "ftyp" {
						t.Fatal("response is not an MP4 container")
					}
					t.Logf("quality=%d variants=%d media HTTP=%d bytes=%d MP4=true", media.Quality, len(media.Variants), response.StatusCode, len(prefix))
				})
			}
		})
	}
}

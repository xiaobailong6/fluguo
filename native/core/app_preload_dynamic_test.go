package core

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestNativePrefetchRefreshesDynamicPlaylist(t *testing.T) {
	for _, suffix := range []string{"", "#EXT-X-PLAYLIST-TYPE:EVENT\n", "#EXT-X-ENDLIST\n"} {
		t.Run(strings.TrimSpace(suffix), func(t *testing.T) {
			var requests atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/index.m3u8" {
					_, _ = io.WriteString(w, "segment")
					return
				}
				sequence := requests.Add(1)
				w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
				_, _ = fmt.Fprintf(w, "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:%d\n#EXTINF:4,\nsegment.ts\n%s", sequence, suffix)
			}))
			defer upstream.Close()
			stream := preloadTestStream(t)
			entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/index.m3u8"})
			defer stream.nativeRelease(token)
			stream.nativePrefetch(context.Background(), token, entry, 1080)
			for index := 2; index <= 3; index++ {
				status, _, body := preloadTestGet(t, entry, "")
				want := index
				if suffix == "#EXT-X-ENDLIST\n" {
					want = 1
				}
				if status != 200 || !strings.Contains(string(body), fmt.Sprintf("#EXT-X-MEDIA-SEQUENCE:%d\n", want)) || requests.Load() != int32(want) {
					t.Fatalf("playlist freshness/cache mismatch: %d %q requests=%d", status, body, requests.Load())
				}
			}
		})
	}
}

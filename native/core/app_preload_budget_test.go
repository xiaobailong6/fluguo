package core

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestNativePrefetchStartupWindowAndByteBudget(t *testing.T) {
	for _, seconds := range []int{2, 8} {
		t.Run(fmt.Sprint(seconds), func(t *testing.T) {
			var mu sync.Mutex
			var fetched []string
			var playlist strings.Builder
			playlist.WriteString("#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-MAP:URI=\"init.mp4\"\n")
			for i := 0; i < 10; i++ {
				fmt.Fprintf(&playlist, "#EXTINF:%d,\n%d.ts\n", seconds, i)
			}
			playlist.WriteString("#EXT-X-ENDLIST\n")
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/index.m3u8" {
					w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
					io.WriteString(w, playlist.String())
					return
				}
				mu.Lock()
				fetched = append(fetched, r.URL.Path)
				mu.Unlock()
				w.Header().Set("Content-Type", "application/octet-stream")
				io.WriteString(w, strings.Repeat("x", 32))
			}))
			defer upstream.Close()
			stream := preloadTestStream(t)
			entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/index.m3u8"})
			defer stream.nativeRelease(token)
			bytes := stream.nativePrefetch(context.Background(), token, entry, 0)
			expected := 4
			if seconds == 8 {
				expected = 2
			}
			if bytes <= 0 || bytes > nativePreloadLimit {
				t.Fatalf("invalid bytes %d", bytes)
			}
			mu.Lock()
			count := len(fetched)
			mu.Unlock()
			if count != expected+2 {
				t.Fatalf("fetched %d resources, want %d with key/map", count, expected+2)
			}
			// 断开上游后已缓存的前段必须能直接提供，不能只缓存地址。
			upstream.Close()
			_, _, body := preloadTestGet(t, entry, "")
			segments := 0
			for _, line := range strings.Split(string(body), "\n") {
				if strings.HasPrefix(line, stream.address+"/") && segments < expected {
					status, _, data := preloadTestGet(t, line, "")
					if status != 200 || len(data) != 32 {
						t.Fatalf("cached segment: %d %d", status, len(data))
					}
					segments++
				}
			}
			if segments != expected {
				t.Fatalf("cached %d segments want %d", segments, expected)
			}
		})
	}
	if nativePreloadLimit != 8<<20 {
		t.Fatal("startup byte budget changed")
	}
}

func TestNativePrefetchRejectsOverBudgetBody(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("ETag", "\"fixture\"")
		// 模拟不遵守 Range 的上游，不能把超预算正文放入内存缓存。
		io.WriteString(w, strings.Repeat("x", nativePreloadLimit+1))
	}))
	defer upstream.Close()
	stream := preloadTestStream(t)
	entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/large.mp4"})
	defer stream.nativeRelease(token)
	if got := stream.nativePrefetch(context.Background(), token, entry, 0); got != 0 {
		t.Fatalf("over-budget response cached: %d", got)
	}
	stream.mu.Lock()
	session := stream.sessions[token]
	stream.mu.Unlock()
	session.mu.Lock()
	defer session.mu.Unlock()
	for _, asset := range session.assets {
		if len(asset.data) != 0 {
			t.Fatal("oversized media entered cache")
		}
	}
}

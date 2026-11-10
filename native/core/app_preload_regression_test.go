package core

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func preloadTestStream(t *testing.T) *nativeStreamServer {
	t.Helper()
	manager := downloadTestManager(t)
	stream, err := newNativeStreamServer(manager.engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stream.server.Close() })
	return stream
}

func preloadTestGet(t *testing.T, address, byteRange string) (int, string, []byte) {
	t.Helper()
	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Range", byteRange)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return response.StatusCode, response.Header.Get("Content-Type"), body
}

func TestNativePrefetchRejectsInvalidPlaylistAndRecovers(t *testing.T) {
	for _, mode := range []string{"html", "json", "text", "oversize", "partial"} {
		t.Run(mode, func(t *testing.T) {
			var healthy atomic.Bool
			playlist := " \r\n\ufeff \n#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n"
			segment := []byte("synthetic-transport-segment")
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/segment.ts" {
					w.Header().Set("Content-Type", "video/mp2t")
					_, _ = w.Write(segment)
					return
				}
				if healthy.Load() {
					w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
					_, _ = io.WriteString(w, playlist)
					return
				}
				switch mode {
				case "html":
					w.Header().Set("Content-Type", "text/html")
					_, _ = io.WriteString(w, "<html>upstream error</html>")
				case "json":
					w.Header().Set("Content-Type", "application/json")
					_, _ = io.WriteString(w, `{"error":"expired"}`)
				case "text":
					w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
					_, _ = io.WriteString(w, "access denied")
				case "oversize":
					w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
					_, _ = io.WriteString(w, "#EXTM3U\n"+strings.Repeat("#", nativePlaylistLimit))
				case "partial":
					w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
					w.Header().Set("ETag", "\"v1\"")
					w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-%d/%d", len(playlist)-1, len(playlist)+100))
					w.WriteHeader(http.StatusPartialContent)
					_, _ = io.WriteString(w, playlist)
				}
			}))
			t.Cleanup(upstream.Close)
			stream := preloadTestStream(t)
			entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/index.m3u8"})
			t.Cleanup(func() { stream.nativeRelease(token) })
			if n := stream.nativePrefetch(context.Background(), token, entry, 1080); n != 0 {
				t.Fatalf("invalid playlist counted as prefetched: %d", n)
			}
			stream.mu.Lock()
			session := stream.sessions[token]
			stream.mu.Unlock()
			session.mu.Lock()
			for _, asset := range session.assets {
				if len(asset.data) != 0 {
					t.Error("invalid response polluted session cache")
				}
			}
			session.mu.Unlock()
			if status, _, _ := preloadTestGet(t, entry, ""); status != http.StatusBadGateway {
				t.Fatalf("network path accepted invalid playlist: %d", status)
			}
			healthy.Store(true)
			if n := stream.nativePrefetch(context.Background(), token, entry, 1080); n != int64(len(playlist)+len(segment)) {
				t.Fatalf("prefetch failed to recover: %d", n)
			}
			// 关闭上游后播放列表和分片都必须来自有效缓存。
			upstream.Close()
			status, contentType, body := preloadTestGet(t, entry, "")
			if status != http.StatusOK || !strings.Contains(contentType, "mpegurl") || !bytes.HasPrefix(body, []byte("#EXTM3U")) {
				t.Fatalf("offline playlist invalid: %d %s %q", status, contentType, body)
			}
			segmentURL := ""
			for _, line := range strings.Split(string(body), "\n") {
				if strings.HasPrefix(line, stream.address+"/") {
					segmentURL = line
				}
			}
			if segmentURL == "" {
				t.Fatal("BOM/whitespace playlist did not rewrite segment")
			}
			status, _, body = preloadTestGet(t, segmentURL, "")
			if status != http.StatusOK || !bytes.Equal(body, segment) {
				t.Fatalf("offline segment invalid: %d %q", status, body)
			}
		})
	}
}

func TestNativePrefetchPredictedHLSDowngradesToMP4(t *testing.T) {
	data := []byte("\x00\x00\x00\x18ftypmp42synthetic-mp4")
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("ETag", "\"mp4\"")
		_, _ = w.Write(data)
	}))
	t.Cleanup(upstream.Close)
	stream := preloadTestStream(t)
	entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/predicted.m3u8"})
	t.Cleanup(func() { stream.nativeRelease(token) })
	if n := stream.nativePrefetch(context.Background(), token, entry, 1080); n != int64(len(data)) {
		t.Fatalf("MP4 prefetch failed: %d", n)
	}
	upstream.Close()
	status, contentType, body := preloadTestGet(t, entry, "bytes=2-9")
	if status != http.StatusPartialContent || contentType != "video/mp4" || !bytes.Equal(body, data[2:10]) {
		t.Fatalf("cached predicted HLS did not downgrade: %d %s %q", status, contentType, body)
	}
}

func TestNativeStreamRejectsInvalidCachedPlaylist(t *testing.T) {
	for _, invalid := range []string{"<html>bad</html>", "#EXTM3U\n" + strings.Repeat("#", nativePlaylistLimit)} {
		var healthy atomic.Bool
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			if healthy.Load() {
				_, _ = io.WriteString(w, " \ufeff\n#EXTM3U\n#EXT-X-ENDLIST\n")
			} else {
				_, _ = io.WriteString(w, "upstream error")
			}
		}))
		t.Cleanup(upstream.Close)
		stream := preloadTestStream(t)
		entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/cached.m3u8", Playlist: invalid})
		t.Cleanup(func() { stream.nativeRelease(token) })
		if status, _, _ := preloadTestGet(t, entry, ""); status != http.StatusBadGateway {
			t.Fatalf("invalid embedded/cache body served: %d", status)
		}
		healthy.Store(true)
		status, _, body := preloadTestGet(t, entry, "")
		if status != http.StatusOK || !bytes.HasPrefix(body, []byte("#EXTM3U")) {
			t.Fatalf("invalid cache prevented recovery: %d %q", status, body)
		}
	}
}

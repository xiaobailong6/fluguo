package core

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func cacheTestSession(t *testing.T, pool *nativeCachePool) *nativeMediaCache {
	t.Helper()
	cache := &nativeMediaCache{pool: pool, entries: map[string]*nativeCacheEntry{}}
	t.Cleanup(cache.close)
	return cache
}

func cacheTestCounters(t *testing.T, pool *nativeCachePool, committed, reserved int64) {
	t.Helper()
	pool.mu.Lock()
	defer pool.mu.Unlock()
	if pool.committed != committed || pool.reserved != reserved {
		t.Fatalf("pool committed/reserved = %d/%d, want %d/%d", pool.committed, pool.reserved, committed, reserved)
	}
}

func cacheTestHit(t *testing.T, cache *nativeMediaCache, id, byteRange string, want []byte) {
	t.Helper()
	_, chunks, _, _, release, hit := cache.lease(id, byteRange, "")
	if !hit {
		t.Fatalf("cache miss: %s %s", id, byteRange)
	}
	defer release()
	if got := bytes.Join(chunks, nil); !bytes.Equal(got, want) {
		t.Fatalf("cache bytes differ: got %d want %d", len(got), len(want))
	}
}

func TestNativeStreamCacheNormalPlaybackEpisodeReturnOffline(t *testing.T) {
	data := bytes.Repeat([]byte("normal-playback-media"), 9000)
	var requests atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("ETag", `"same"`)
		http.ServeContent(w, r, "movie.mp4", time.Time{}, bytes.NewReader(data))
	}))
	defer upstream.Close()
	stream := preloadTestStream(t)
	var entries, tokens []string
	for i := 0; i < 3; i++ {
		entry, token := stream.nativeOpen(providerMedia{URL: fmt.Sprintf("%s/%d.mp4", upstream.URL, i)})
		entries, tokens = append(entries, entry), append(tokens, token)
		defer stream.nativeRelease(token)
	}
	for _, i := range []int{1, 2} {
		status, _, body := preloadTestGet(t, entries[i], "")
		if status != 200 || !bytes.Equal(body, data) {
			t.Fatalf("normal playback %d failed", i)
		}
	}
	// Prefetch of an already normally played episode uses the very same bytes.
	if n := stream.nativePrefetch(context.Background(), tokens[1], entries[1], 0); n != 0 {
		t.Fatalf("duplicate prefetch = %d", n)
	}
	upstream.Close()
	for _, byteRange := range []string{"", "bytes=0-511", "bytes=-512", "bytes=65530-65545", "bytes=150000-"} {
		status, _, body := preloadTestGet(t, entries[1], byteRange)
		a, b, _ := nativeCacheRange(byteRange, int64(len(data)))
		wantStatus := 200
		if byteRange != "" {
			wantStatus = 206
		}
		if status != wantStatus || !bytes.Equal(body, data[a:b+1]) {
			t.Fatalf("offline range %q: %d/%d", byteRange, status, len(body))
		}
	}
	if requests.Load() != 2 {
		t.Fatalf("unexpected upstream requests: %d", requests.Load())
	}
}

func TestNativeStreamCacheNormalHLSOfflineAndDynamic(t *testing.T) {
	for _, stable := range []bool{false, true} {
		t.Run(fmt.Sprint(stable), func(t *testing.T) {
			var manifests atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/index.m3u8" {
					n := manifests.Add(1)
					w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
					text := fmt.Sprintf("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:%d\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\nsegment.ts\n", n)
					if stable {
						text += "#EXT-X-ENDLIST\n"
					}
					io.WriteString(w, text)
					return
				}
				w.Header().Set("Content-Type", "application/octet-stream")
				io.WriteString(w, "binary-resource-"+r.URL.Path)
			}))
			defer upstream.Close()
			stream := preloadTestStream(t)
			entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/index.m3u8"})
			defer stream.nativeRelease(token)
			_, _, body := preloadTestGet(t, entry, "")
			urls := streamIndexURLs(string(body))
			if len(urls) != 3 {
				t.Fatal("missing key/map/segment")
			}
			for _, address := range urls {
				if s, _, _ := preloadTestGet(t, address, ""); s != 200 {
					t.Fatal(s)
				}
			}
			if !stable {
				_, _, next := preloadTestGet(t, entry, "")
				if manifests.Load() != 2 || bytes.Equal(body, next) {
					t.Fatal("dynamic manifest cached")
				}
			}
			upstream.Close()
			if stable {
				if status, _, replay := preloadTestGet(t, entry, ""); status != 200 || !bytes.Equal(body, replay) {
					t.Fatal("offline VOD playlist changed")
				}
			}
			for _, address := range urls {
				if status, _, data := preloadTestGet(t, address, ""); status != 200 || !bytes.HasPrefix(data, []byte("binary-resource-")) {
					t.Fatal("offline HLS resource missing")
				}
			}
		})
	}
}

func TestNativeStreamCachePrefixTailVersionAndRange(t *testing.T) {
	var version atomic.Int32
	version.Store(1)
	var requests atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("ETag", fmt.Sprintf(`"v%d"`, version.Load()))
		http.ServeContent(w, r, "movie.mp4", time.Time{}, bytes.NewReader(bytes.Repeat([]byte{byte(version.Load())}, 2<<20)))
	}))
	defer upstream.Close()
	stream := preloadTestStream(t)
	entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/movie.mp4"})
	defer stream.nativeRelease(token)
	for _, byteRange := range []string{"bytes=0-65535", "bytes=-65536", "bytes=32768-98303"} {
		status, _, _ := preloadTestGet(t, entry, byteRange)
		if status != 206 {
			t.Fatal(status)
		}
	}
	cache := stream.sessions[token].cache
	cacheTestHit(t, cache, streamIndexID(entry), "bytes=0-98303", bytes.Repeat([]byte{1}, 98304))
	cacheTestHit(t, cache, streamIndexID(entry), "bytes=-65536", bytes.Repeat([]byte{1}, 65536))
	cache.pool.mu.Lock()
	used := cache.used
	cache.pool.mu.Unlock()
	if used != 98304+65536 {
		t.Fatalf("overlap stored twice: %d", used)
	}
	version.Store(2)
	preloadTestGet(t, entry, "bytes=100000-101023")
	if _, _, _, _, release, hit := cache.lease(streamIndexID(entry), "bytes=0-15", ""); hit {
		release()
		t.Fatal("old prefix survived validator change")
	}
	upstream.Close()
	if status, _, data := preloadTestGet(t, entry, "bytes=100000-101023"); status != 206 || !bytes.Equal(data, bytes.Repeat([]byte{2}, 1024)) {
		t.Fatal("new version not cached")
	}
	if requests.Load() != 4 {
		t.Fatal(requests.Load())
	}
}

func TestNativeStreamCacheConcurrentHardPoolAndRelease(t *testing.T) {
	pool := &nativeCachePool{}
	var caches []*nativeMediaCache
	var writes []*nativeCacheWrite
	data := make([]byte, nativeStreamCacheLimit)
	for i := 0; i < 4; i++ {
		cache := cacheTestSession(t, pool)
		caches = append(caches, cache)
		writes = append(writes, cache.begin("media", nativeStreamAsset{kind: "media", total: int64(len(data)), etag: `"v1"`}))
	}
	var wg sync.WaitGroup
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func(i int) { defer wg.Done(); writes[i].capture(0, data) }(i)
	}
	wg.Wait()
	cacheTestCounters(t, pool, 0, nativeStreamCachePoolLimit)
	writes[3].capture(0, data)
	if writes[3].bytes != 0 {
		t.Fatal("fourth session exceeded global reservation pool")
	}
	for i := 0; i < 3; i++ {
		if caches[i].used != nativeStreamCacheLimit {
			t.Fatalf("session %d used %d", i, caches[i].used)
		}
	}
	writes[0].finish(true, int64(len(data)))
	cacheTestCounters(t, pool, nativeStreamCacheLimit, 2*nativeStreamCacheLimit)
	_, _, _, _, release, hit := caches[0].lease("media", "", "")
	if !hit {
		t.Fatal("missing committed body")
	}
	caches[0].close()
	caches[1].close()
	cacheTestCounters(t, pool, nativeStreamCacheLimit, 2*nativeStreamCacheLimit)
	// Neither the old leased bytes nor a cancelled writer's allocations are
	// reusable until their final consumer relinquishes them.
	writes[3].capture(0, data)
	if writes[3].bytes != 0 {
		t.Fatal("release reclaimed live allocations early")
	}
	writes[1].capture(0, data)
	if n := writes[1].finish(true, int64(len(data))); n != 0 {
		t.Fatal("late refill after close")
	}
	release()
	writes[2].finish(false, 0)
	writes[3].finish(false, 0)
	cacheTestCounters(t, pool, 0, 0)
}

func TestNativeStreamCacheOversizeKeepsPrefixAndTail(t *testing.T) {
	pool := &nativeCachePool{}
	cache := cacheTestSession(t, pool)
	data := bytes.Repeat([]byte("x"), 12<<20)
	meta := nativeStreamAsset{kind: "media", contentType: "video/mp4", total: int64(len(data)), etag: `"same"`}
	n, err := nativeCacheCopy(context.Background(), io.Discard, bytes.NewReader(data), cache, "media", meta, 0, int64(len(data)), 0)
	if err != nil || n != nativeStreamCacheLimit {
		t.Fatalf("oversize stream: %d %v", n, err)
	}
	cacheTestCounters(t, pool, nativeStreamCacheLimit, 0)
	cacheTestHit(t, cache, "media", "bytes=0-1023", data[:1024])
	cacheTestHit(t, cache, "media", "bytes=-1024", data[len(data)-1024:])
	if _, _, _, _, release, hit := cache.lease("media", "", ""); hit {
		release()
		t.Fatal("oversize whole file reported cached")
	}
	cache.close()
	cacheTestCounters(t, pool, 0, 0)
}

type cacheFailureWriter struct{ cancel context.CancelFunc }

func (writer cacheFailureWriter) Write(p []byte) (int, error) {
	if writer.cancel != nil {
		writer.cancel()
		return len(p), nil
	}
	return 0, io.ErrClosedPipe
}

type cacheFailureReader struct{ sent bool }

func (reader *cacheFailureReader) Read(p []byte) (int, error) {
	if reader.sent {
		return 0, io.ErrUnexpectedEOF
	}
	reader.sent = true
	return copy(p, "valid-first-part"), nil
}

func TestNativeStreamCachePartialReadCancellationAndDedupe(t *testing.T) {
	for _, mode := range []string{"short", "error", "write_error", "cancel", "preload_oversize"} {
		t.Run(mode, func(t *testing.T) {
			pool := &nativeCachePool{}
			cache := cacheTestSession(t, pool)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var reader io.Reader = strings.NewReader("short")
			var writer io.Writer = io.Discard
			expected, limit := int64(100), int64(0)
			switch mode {
			case "error":
				reader = &cacheFailureReader{}
				expected = -1
			case "write_error":
				writer = cacheFailureWriter{}
			case "cancel":
				writer = cacheFailureWriter{cancel: cancel}
			case "preload_oversize":
				reader = strings.NewReader("too-large")
				expected = -1
				limit = 4
			}
			if n, err := nativeCacheCopy(ctx, writer, reader, cache, "media", nativeStreamAsset{total: 100, etag: `"v1"`}, 0, expected, limit); n != 0 || err == nil {
				t.Fatalf("failure committed: %d %v", n, err)
			}
			cacheTestCounters(t, pool, 0, 0)
		})
	}
	pool := &nativeCachePool{}
	cache := cacheTestSession(t, pool)
	meta := nativeStreamAsset{total: 8, etag: `"v1"`}
	first := cache.begin("a", meta)
	first.capture(0, []byte("1234"))
	if second := cache.begin("a", meta); second != nil {
		t.Fatal("duplicate in-flight allocation")
	}
	first.finish(true, 8)
	second := cache.begin("a", meta)
	second.capture(2, []byte("345678"))
	if got := second.finish(true, 8); got != 4 {
		t.Fatal("overlap not deduped", got)
	}
	cacheTestCounters(t, pool, 8, 0)
	cacheTestHit(t, cache, "a", "", []byte("12345678"))
	late := cache.begin("a", meta)
	cache.remove("a")
	late.capture(0, []byte("old-data"))
	if n := late.finish(true, 8); n != 0 {
		t.Fatal("invalidated request repopulated cache")
	}
	if cache.begin("a", meta) != nil {
		t.Fatal("late response headers admitted after invalidation")
	}
	cacheTestCounters(t, pool, 0, 0)
}

func TestNativeStreamCacheRejectsInvalidNormalResponses(t *testing.T) {
	for _, mode := range []string{"html", "json", "xml", "text", "disguised", "status", "bad_range", "wrong_range", "length", "short"} {
		t.Run(mode, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "video/mp4")
				w.Header().Set("ETag", `"v1"`)
				switch mode {
				case "html":
					w.Header().Set("Content-Type", "text/html")
					io.WriteString(w, "<html>denied</html>")
				case "json":
					w.Header().Set("Content-Type", "application/problem+json")
					io.WriteString(w, `{"error":"denied"}`)
				case "xml":
					w.Header().Set("Content-Type", "application/xml")
					io.WriteString(w, "<error/>")
				case "text":
					w.Header().Set("Content-Type", "text/plain")
					io.WriteString(w, "access denied")
				case "disguised":
					io.WriteString(w, "<!DOCTYPE html><html>denied</html>")
				case "status":
					w.WriteHeader(403)
					io.WriteString(w, "denied")
				case "bad_range":
					w.Header().Set("Content-Range", "bytes 0-3/*")
					w.WriteHeader(206)
					io.WriteString(w, "1234")
				case "wrong_range":
					w.Header().Set("Content-Range", "bytes 1-4/8")
					w.WriteHeader(206)
					io.WriteString(w, "1234")
				case "length":
					w.Header().Set("Content-Range", "bytes 0-3/8")
					w.Header().Set("Content-Length", "8")
					w.WriteHeader(206)
					io.WriteString(w, "12345678")
				case "short":
					w.Header().Set("Content-Length", "1000")
					io.WriteString(w, "short")
				}
			}))
			defer upstream.Close()
			stream := preloadTestStream(t)
			entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/movie.mp4"})
			defer stream.nativeRelease(token)
			request, _ := http.NewRequest(http.MethodGet, entry, nil)
			request.Header.Set("Range", "bytes=0-3")
			response, err := http.DefaultClient.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			io.Copy(io.Discard, response.Body)
			response.Body.Close()
			cache := stream.sessions[token].cache
			cache.pool.mu.Lock()
			used := cache.used
			cache.pool.mu.Unlock()
			if used != 0 {
				t.Fatalf("invalid response cached %d bytes", used)
			}
			if mode != "short" && response.StatusCode < 400 {
				t.Fatalf("invalid status = %d", response.StatusCode)
			}
		})
	}
}

func TestNativeStreamCachePlaybackOwnershipDoesNotUseStreamLRU(t *testing.T) {
	engine := sourceFixtureEngine(t, func(r *http.Request) (*http.Response, error) {
		response := sourceFixtureResponse(r, 200, "retained-media")
		response.Header.Set("Content-Type", "video/mp4")
		return response, nil
	})
	var plans []nativePlan
	for i := 0; i < 3; i++ {
		plan, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoice{media: []providerMedia{{URL: fmt.Sprintf("https://cdn.example.com/%d.mp4", i)}}})
		if err != nil {
			t.Fatal(err)
		}
		plans = append(plans, plan)
		defer engine.nativeReleasePlayback(plan.Session)
	}
	defer engine.stream.server.Close()
	stream := engine.stream
	stream.mu.Lock()
	for _, session := range stream.sessions {
		session.lastUsed = time.Now().Add(-time.Hour)
	}
	stream.mu.Unlock()
	for i := 0; i < 12; i++ {
		_, token := stream.nativeOpen(providerMedia{URL: "https://cdn.example.com/other.mp4"})
		defer stream.nativeRelease(token)
	}
	for _, plan := range plans {
		if status, _, body := preloadTestGet(t, plan.URL, ""); status != 200 || string(body) != "retained-media" {
			t.Fatal("stream LRU killed playback owner")
		}
	}
	engine.nativeReleasePlayback(plans[0].Session)
	if status, _, _ := preloadTestGet(t, plans[0].URL, ""); status != 410 {
		t.Fatal("owner release ignored")
	}
	if status, _, _ := preloadTestGet(t, plans[1].URL, ""); status != 200 {
		t.Fatal("neighbour release killed current")
	}
}

func TestNativeStreamCachePlaylistReservationAndFailures(t *testing.T) {
	pool := &nativeCachePool{}
	cache := cacheTestSession(t, pool)
	body, release, err := cache.readPlaylist(strings.NewReader("#EXTM3U\n"), 8, nativePlaylistLimit)
	if err != nil || string(body) != "#EXTM3U\n" {
		t.Fatal(err)
	}
	cacheTestCounters(t, pool, 0, 8)
	cache.close()
	cacheTestCounters(t, pool, 0, 8)
	body = nil
	release()
	release()
	cacheTestCounters(t, pool, 0, 0)
	cache = cacheTestSession(t, pool)
	_, release, err = cache.readPlaylist(strings.NewReader("short"), 100, nativePlaylistLimit)
	release()
	if !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("short playlist: %v", err)
	}
	cacheTestCounters(t, pool, 0, 0)
}

func TestNativeStreamCacheGapFetchesOnlyMissingBytesAndNeverMixesVersions(t *testing.T) {
	for _, change := range []bool{false, true} {
		t.Run(fmt.Sprint(change), func(t *testing.T) {
			var version atomic.Int32
			version.Store(1)
			var mu sync.Mutex
			var ranges, validators []string
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				ranges = append(ranges, r.Header.Get("Range"))
				validators = append(validators, r.Header.Get("If-Range"))
				mu.Unlock()
				w.Header().Set("Content-Type", "video/mp4")
				w.Header().Set("ETag", fmt.Sprintf(`"v%d"`, version.Load()))
				http.ServeContent(w, r, "movie.mp4", time.Time{}, bytes.NewReader(bytes.Repeat([]byte{byte(version.Load())}, 4096)))
			}))
			defer upstream.Close()
			stream := preloadTestStream(t)
			entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/movie.mp4"})
			defer stream.nativeRelease(token)
			preloadTestGet(t, entry, "bytes=0-1023")
			preloadTestGet(t, entry, "bytes=3072-4095")
			if change {
				version.Store(2)
			}
			status, _, body := preloadTestGet(t, entry, "")
			if status != 200 || !bytes.Equal(body, bytes.Repeat([]byte{byte(version.Load())}, 4096)) {
				t.Fatal("mixed versions in gap response")
			}
			mu.Lock()
			if len(ranges) < 3 || ranges[2] != "bytes=1024-3071" || validators[2] != `"v1"` {
				t.Errorf("gap headers: %v / %v", ranges, validators)
			}
			want := 3
			if change {
				want = 4
			}
			if len(ranges) != want {
				t.Errorf("requests=%d want=%d", len(ranges), want)
			}
			mu.Unlock()
			upstream.Close()
			if s, _, data := preloadTestGet(t, entry, ""); s != 200 || !bytes.Equal(data, body) {
				t.Fatal("filled gap not cached offline")
			}
		})
	}
}

func TestNativeStreamCacheValidatorFallbackAndConcurrentSupersession(t *testing.T) {
	pool := &nativeCachePool{}
	cache := cacheTestSession(t, pool)
	meta := nativeStreamAsset{total: 8, modified: "Wed, 21 Oct 2015 07:28:00 GMT", etag: `W/"weak"`}
	first := cache.begin("a", meta)
	first.capture(0, []byte("1234"))
	first.finish(true, 8)
	second := cache.begin("a", meta)
	second.capture(4, []byte("5678"))
	second.finish(true, 8)
	cacheTestHit(t, cache, "a", "", []byte("12345678"))
	old := cache.begin("a", meta)
	old.capture(0, []byte("1234"))
	updated := meta
	updated.modified = "Thu, 22 Oct 2015 07:28:00 GMT"
	newer := cache.begin("a", updated)
	newer.capture(4, []byte("ABCD"))
	newer.finish(true, 8)
	if n := old.finish(true, 8); n != 0 {
		t.Fatal("late old version committed")
	}
	if _, _, _, _, release, hit := cache.lease("a", "", ""); hit {
		release()
		t.Fatal("combined old and new ranges")
	}
	cacheTestCounters(t, pool, 4, 0)
}

type cacheSignalWriter struct {
	*httptest.ResponseRecorder
	started chan struct{}
	once    sync.Once
}

func (writer *cacheSignalWriter) Write(data []byte) (int, error) {
	n, err := writer.ResponseRecorder.Write(data)
	writer.once.Do(func() { close(writer.started) })
	return n, err
}

func TestNativeStreamCacheReleaseDuringNormalReadCannotRefill(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("ETag", `"v1"`)
		w.Header().Set("Content-Length", "1048576")
		w.Write(bytes.Repeat([]byte("x"), 65536))
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer upstream.Close()
	stream := preloadTestStream(t)
	entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/movie.mp4"})
	session := stream.sessions[token]
	writer := &cacheSignalWriter{ResponseRecorder: httptest.NewRecorder(), started: make(chan struct{})}
	done := make(chan struct{})
	go func() { stream.nativeServe(writer, httptest.NewRequest(http.MethodGet, entry, nil)); close(done) }()
	select {
	case <-writer.started:
	case <-time.After(3 * time.Second):
		t.Fatal("normal playback did not stream before EOF")
	}
	session.cache.pool.mu.Lock()
	used := session.cache.used
	session.cache.pool.mu.Unlock()
	if used == 0 {
		t.Fatal("normal read had no reservation")
	}
	stream.nativeRelease(token)
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("release did not cancel upstream body")
	}
	session.cache.pool.mu.Lock()
	defer session.cache.pool.mu.Unlock()
	if session.cache.used != 0 || len(session.cache.entries) != 0 {
		t.Fatal("released reader refilled cache")
	}
}

func TestNativeStreamCacheHundredEpisodeWindowLifecycle(t *testing.T) {
	pool := &nativeCachePool{}
	var window []*nativeMediaCache
	for episode := 0; episode < 100; episode++ {
		if len(window) == 3 {
			window[0].close()
			window = window[1:]
		}
		cache := cacheTestSession(t, pool)
		cache.put("media", nativeStreamAsset{etag: `"v1"`}, []byte("episode-data"))
		window = append(window, cache)
		cacheTestCounters(t, pool, int64(len(window)*12), 0)
	}
	for _, cache := range window {
		cache.close()
	}
	cacheTestCounters(t, pool, 0, 0)
}

type cacheCancelAfterWriter struct {
	count  int
	cancel context.CancelFunc
}

func (writer *cacheCancelAfterWriter) Write(data []byte) (int, error) {
	writer.count += len(data)
	if writer.count >= 3*nativeStreamCacheChunk/2 {
		writer.cancel()
	}
	return len(data), nil
}

func TestNativeStreamCachePlayerStopsLongReadRetainsCompletedChunks(t *testing.T) {
	pool := &nativeCachePool{}
	cache := cacheTestSession(t, pool)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	data := bytes.Repeat([]byte("x"), 4*nativeStreamCacheChunk)
	meta := nativeStreamAsset{kind: "media", total: int64(len(data)), etag: `"v1"`}
	n, err := nativeCacheCopy(ctx, &cacheCancelAfterWriter{cancel: cancel}, bytes.NewReader(data), cache, "a", meta, 0, int64(len(data)), 0)
	if !errors.Is(err, context.Canceled) || n != nativeStreamCacheChunk {
		t.Fatalf("interrupted normal read: %d %v", n, err)
	}
	cacheTestCounters(t, pool, nativeStreamCacheChunk, 0)
	cacheTestHit(t, cache, "a", "bytes=0-65535", data[:65536])
	if _, _, _, _, release, hit := cache.lease("a", "bytes=65536-98303", ""); hit {
		release()
		t.Fatal("partial chunk retained")
	}
}

func TestNativeStreamCacheHeadAndMultipartPassThrough(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("ETag", `"v1"`)
		http.ServeContent(w, r, "movie.mp4", time.Time{}, strings.NewReader("0123456789"))
	}))
	defer upstream.Close()
	stream := preloadTestStream(t)
	entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/movie.mp4"})
	defer stream.nativeRelease(token)
	status, contentType, _ := preloadTestGet(t, entry, "bytes=0-1,8-9")
	if status != 206 || !strings.HasPrefix(contentType, "multipart/byteranges;") {
		t.Fatalf("multipart pass through: %d %s", status, contentType)
	}
	cache := stream.sessions[token].cache
	cache.pool.mu.Lock()
	used := cache.used
	cache.pool.mu.Unlock()
	if used != 0 {
		t.Fatal("multipart framing cached as bytes")
	}
	preloadTestGet(t, entry, "")
	upstream.Close()
	request, _ := http.NewRequest(http.MethodHead, entry, nil)
	request.Header.Set("Range", "bytes=2-5")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if response.StatusCode != 206 || response.Header.Get("Content-Length") != "4" || len(body) != 0 {
		t.Fatal("cached HEAD invalid")
	}
}

func TestNativeStreamCacheUnvalidatedRangeIsAtomicSnapshot(t *testing.T) {
	var requests atomic.Int32
	var version atomic.Int32
	version.Store(1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("Content-Type", "video/mp4")
		http.ServeContent(w, r, "movie.mp4", time.Time{}, bytes.NewReader(bytes.Repeat([]byte{byte(version.Load())}, 4096)))
	}))
	defer upstream.Close()
	stream := preloadTestStream(t)
	entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/movie.mp4"})
	defer stream.nativeRelease(token)
	status, _, first := preloadTestGet(t, entry, "bytes=0-1023")
	if status != 206 {
		t.Fatal(status)
	}
	_, _, replay := preloadTestGet(t, entry, "bytes=0-1023")
	if requests.Load() != 1 || !bytes.Equal(first, replay) {
		t.Fatal("single response range was not reused")
	}
	version.Store(2)
	_, _, tail := preloadTestGet(t, entry, "bytes=1024-2047")
	if !bytes.Equal(tail, bytes.Repeat([]byte{2}, 1024)) {
		t.Fatal("wrong new snapshot")
	}
	// 两段没有验证器，不能把旧头部和新尾部混成一份响应。
	_, _, joined := preloadTestGet(t, entry, "bytes=0-2047")
	if requests.Load() != 3 || !bytes.Equal(joined, bytes.Repeat([]byte{2}, 2048)) {
		t.Fatal("mixed unvalidated responses")
	}
	upstream.Close()
	status, _, replay = preloadTestGet(t, entry, "bytes=512-1535")
	if status != 206 || !bytes.Equal(replay, bytes.Repeat([]byte{2}, 1024)) {
		t.Fatal("atomic snapshot unavailable offline")
	}
}

package core

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func streamIndexPlaylist(sequence int) string {
	return fmt.Sprintf("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:%d\n#EXT-X-KEY:METHOD=AES-128,URI=\"key-%d.key\"\n#EXT-X-MAP:URI=\"map-%d.mp4\"\n#EXTINF:4,\nseg-%d.ts\n", sequence, sequence, sequence, sequence)
}

func streamIndexURLs(body string) []string {
	var addresses []string
	for _, match := range nativePlaylistURI.FindAllStringSubmatch(body, -1) {
		addresses = append(addresses, match[1])
	}
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "http:") {
			addresses = append(addresses, line)
		}
	}
	return addresses
}

func streamIndexID(address string) string {
	parsed, _ := url.Parse(address)
	return path.Base(parsed.Path)
}

func TestNativeStreamAssetIndexDynamicRefreshAndInFlight(t *testing.T) {
	var sequence atomic.Int32
	entered, finish := make(chan struct{}), make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/index.m3u8":
			n := sequence.Add(1)
			http.Redirect(w, r, fmt.Sprintf("/live.m3u8?signature=%d", n), http.StatusFound)
		case "/live.m3u8":
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			_, _ = io.WriteString(w, streamIndexPlaylist(int(sequence.Load())))
		case "/seg-1.ts":
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			close(entered)
			select {
			case <-finish:
			case <-r.Context().Done():
				return
			}
			_, _ = io.WriteString(w, "in-flight-segment")
		default:
			_, _ = io.WriteString(w, r.URL.Path)
		}
	}))
	defer upstream.Close()
	stream := preloadTestStream(t)
	stream.readTimeout = time.Minute
	entry, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/index.m3u8"})
	defer stream.nativeRelease(token)
	session := stream.sessions[token]
	status, _, body := preloadTestGet(t, entry, "")
	if status != 200 {
		t.Fatalf("first playlist: %d %s", status, body)
	}
	first := streamIndexURLs(string(body))
	if len(first) != 3 {
		t.Fatalf("missing key/map/segment: %q", first)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, first[2], nil)
	done := make(chan error, 1)
	go func() {
		response, err := http.DefaultClient.Do(request)
		if err == nil {
			var data []byte
			data, err = io.ReadAll(response.Body)
			response.Body.Close()
			if err == nil && (response.StatusCode != 200 || string(data) != "in-flight-segment") {
				err = fmt.Errorf("in-flight response: %d %q", response.StatusCode, data)
			}
		}
		done <- err
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("segment not entered")
	}
	var recent [][]string
	for i := 2; i <= 2500; i++ {
		status, _, body = preloadTestGet(t, entry, "")
		if status != 200 {
			t.Fatalf("refresh %d: %d %s", i, status, body)
		}
		if i >= 2498 {
			recent = append(recent, streamIndexURLs(string(body)))
		}
		session.mu.Lock()
		count, playlists := len(session.assets), len(session.index.playlists)
		session.mu.Unlock()
		if count > 13 || playlists != 1 {
			t.Fatalf("refresh %d grew index: assets=%d playlists=%d", i, count, playlists)
		}
	}
	// 三个最近代次可回看；旧分片在途时，其 KEY/MAP 也不能被淘汰。
	for _, addresses := range append(recent, first[:2]) {
		for _, address := range addresses {
			if status, _, _ := preloadTestGet(t, address, ""); status != 200 {
				t.Fatalf("retained asset unavailable: %d %s", status, address)
			}
		}
	}
	session.invalidate(upstream.URL + "/index.m3u8")
	close(finish)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("in-flight segment did not finish")
	}
	// 下一次提交也负责清理，避免依赖 HTTP handler defer 与客户端 EOF 的调度先后。
	preloadTestGet(t, entry, "")
	session.mu.Lock()
	count := len(session.assets)
	session.mu.Unlock()
	if count > 10 {
		t.Fatalf("completed old generation retained: %d", count)
	}
	stream.nativeRelease(token)
	session.mu.Lock()
	cleared := len(session.assets) == 0 && len(session.index.playlists) == 0 && len(session.index.active) == 0 && session.index.closed
	session.mu.Unlock()
	if !cleared {
		t.Fatal("release did not clear index")
	}
	if status, _, _ := preloadTestGet(t, first[0], ""); status != http.StatusGone {
		t.Fatalf("released URL returned %d", status)
	}
}

func TestNativeStreamAssetIndexCapacityIsAtomic(t *testing.T) {
	stream := &nativeStreamServer{address: "http://127.0.0.1"}
	session := &nativeStreamSession{origin: stream.address, index: nativeStreamAssetIndex{limit: 10}}
	entry := stream.nativeAsset("token", session, nativeStreamAsset{address: "http://fixture.invalid/index.m3u8", contentType: "application/vnd.apple.mpegurl"})
	id := streamIndexID(entry)
	rewrite := func(sequence int) (string, error) {
		body, release, err := stream.nativeRewrite("token", session, id, streamIndexPlaylist(sequence), "http://fixture.invalid/index.m3u8")
		if release != nil {
			release()
		}
		return body, err
	}
	first, err := rewrite(1)
	if err != nil {
		t.Fatal(err)
	}
	_, release, found := session.acquireAsset(streamIndexID(streamIndexURLs(first)[2]))
	if !found {
		t.Fatal("missing first segment")
	}
	for i := 2; i <= 3; i++ {
		if _, err := rewrite(i); err != nil {
			t.Fatal(err)
		}
	}
	if body, err := rewrite(4); !errors.Is(err, errNativeStreamCapacity) || body != "" {
		t.Fatalf("capacity should fail before publishing: %q %v", body, err)
	}
	if len(session.assets) != 10 || len(session.index.playlists[id]) != 3 {
		t.Fatal("capacity failure mutated index")
	}
	for _, address := range streamIndexURLs(first) {
		if _, found := session.assets[streamIndexID(address)]; !found {
			t.Fatal("capacity failure evicted in-flight dependencies")
		}
	}
	release()
	if _, err := rewrite(4); err != nil || len(session.assets) != 10 {
		t.Fatalf("capacity did not recover after lease: %v", err)
	}
	before := len(session.assets)
	_, _, err = stream.nativeRewrite("token", session, id, "#EXTM3U\nvalid.ts\nftp://bad.invalid/bad.ts\n", "http://fixture.invalid/index.m3u8")
	if err == nil || len(session.assets) != before {
		t.Fatal("invalid rewrite partially populated index")
	}
	session.clearAssets()
	session.cacheAsset(id, nativeStreamAsset{data: []byte("late prefetch")}, false)
	if _, err := rewrite(5); !errors.Is(err, context.Canceled) || len(session.assets) != 0 {
		t.Fatal("late rewrite/cache revived released session")
	}
}

func TestNativeStreamAssetIndexStableVODAndOversize(t *testing.T) {
	stream := preloadTestStream(t)
	makePlaylist := func(count int) string {
		var body strings.Builder
		body.WriteString("#EXTM3U\n")
		for i := 0; i < count; i++ {
			fmt.Fprintf(&body, "#EXTINF:4,\nsegment-%d.ts\n", i)
		}
		body.WriteString("#EXT-X-ENDLIST\n")
		return body.String()
	}
	entry, token := stream.nativeOpen(providerMedia{URL: "http://fixture.invalid/vod.m3u8", Playlist: makePlaylist(4000)})
	defer stream.nativeRelease(token)
	var first []byte
	for i := 0; i < 4; i++ {
		status, _, body := preloadTestGet(t, entry, "")
		if status != 200 || len(streamIndexURLs(string(body))) != 4000 {
			t.Fatalf("stable VOD truncated: %d", status)
		}
		if i > 0 && string(first) != string(body) {
			t.Fatal("stable VOD URLs changed")
		}
		first = body
	}
	session := stream.sessions[token]
	session.mu.Lock()
	count, generations := len(session.assets), len(session.index.playlists[streamIndexID(entry)])
	session.mu.Unlock()
	if count != 4001 || generations != 1 {
		t.Fatalf("stable VOD retained duplicate generations: %d / %d", count, generations)
	}
	large, largeToken := stream.nativeOpen(providerMedia{URL: "http://fixture.invalid/large.m3u8", Playlist: makePlaylist(nativeStreamAssetLimit)})
	defer stream.nativeRelease(largeToken)
	status, _, body := preloadTestGet(t, large, "")
	if status != http.StatusBadGateway || !strings.Contains(string(body), "容量") {
		t.Fatalf("oversize VOD silently damaged: %d %q", status, body)
	}
	largeSession := stream.sessions[largeToken]
	largeSession.mu.Lock()
	count = len(largeSession.assets)
	largeSession.mu.Unlock()
	if count != 1 {
		t.Fatalf("oversize VOD partially indexed: %d", count)
	}
}

func TestNativeStreamAssetIndexPlaylistAndGenerationHardLimits(t *testing.T) {
	for _, mode := range []string{"playlists", "generations", "references"} {
		t.Run(mode, func(t *testing.T) {
			session := &nativeStreamSession{}
			var releases []func()
			defer func() {
				for _, release := range releases {
					release()
				}
			}()
			for i := 0; i < 200; i++ {
				id := "entry"
				assets := map[string]nativeStreamAsset{fmt.Sprint(i): {address: fmt.Sprint(i)}}
				if mode == "playlists" {
					id = fmt.Sprint(i)
				} else if mode == "references" {
					for n := 0; n < 1000; n++ {
						assets[fmt.Sprintf("shared-%d", n)] = nativeStreamAsset{}
					}
				}
				release, err := session.commitPlaylist(id, assets)
				if err != nil {
					if !errors.Is(err, errNativeStreamCapacity) {
						t.Fatal(err)
					}
					if len(session.assets) > nativeStreamAssetLimit || len(session.index.playlists) > nativeStreamPlaylistLimit {
						t.Fatal("hard capacity exceeded")
					}
					return
				}
				releases = append(releases, release)
			}
			t.Fatal("metadata capacity was only a soft limit")
		})
	}
}

func TestNativeStreamAssetIndexRotatingChildPlaylists(t *testing.T) {
	stream := &nativeStreamServer{address: "http://127.0.0.1"}
	session := &nativeStreamSession{origin: stream.address}
	entry := stream.nativeAsset("token", session, nativeStreamAsset{address: "http://fixture.invalid/master.m3u8", contentType: "application/vnd.apple.mpegurl"})
	for i := 0; i < 1000; i++ {
		master := fmt.Sprintf("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild-%d.m3u8\n", i)
		body, releaseMaster, err := stream.nativeRewrite("token", session, streamIndexID(entry), master, "http://fixture.invalid/master.m3u8")
		if err != nil {
			t.Fatal(err)
		}
		child := streamIndexID(streamIndexURLs(body)[0])
		_, releaseChild, err := stream.nativeRewrite("token", session, child, streamIndexPlaylist(i), "http://fixture.invalid/child.m3u8")
		if err != nil {
			t.Fatal(err)
		}
		releaseChild()
		releaseMaster()
		if len(session.index.playlists) > 4 || len(session.assets) > 13 {
			t.Fatalf("orphan child retained at %d: playlists=%d assets=%d", i, len(session.index.playlists), len(session.assets))
		}
	}
}

func TestNativeStreamAssetIndexConcurrentDeliveryAndRelease(t *testing.T) {
	stream := &nativeStreamServer{address: "http://127.0.0.1"}
	session := &nativeStreamSession{origin: stream.address}
	entry := stream.nativeAsset("token", session, nativeStreamAsset{address: "http://fixture.invalid/index.m3u8", contentType: "application/vnd.apple.mpegurl"})
	id := streamIndexID(entry)
	var workers sync.WaitGroup
	var sequence atomic.Int32
	for worker := 0; worker < 8; worker++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for i := 0; i < 100; i++ {
				body, releasePlaylist, err := stream.nativeRewrite("token", session, id, streamIndexPlaylist(int(sequence.Add(1))), "http://fixture.invalid/index.m3u8")
				if errors.Is(err, context.Canceled) {
					return
				}
				if err != nil {
					t.Error(err)
					return
				}
				for _, address := range streamIndexURLs(body) {
					_, releaseAsset, found := session.acquireAsset(streamIndexID(address))
					if !found {
						session.mu.Lock()
						closed := session.index.closed
						session.mu.Unlock()
						if !closed {
							t.Error("concurrent refresh evicted a playlist being delivered")
						}
						continue
					}
					releaseAsset()
				}
				releasePlaylist()
				if sequence.Load() > 600 {
					session.clearAssets()
				}
			}
		}()
	}
	workers.Wait()
	if len(session.assets) != 0 || len(session.index.playlists) != 0 {
		t.Fatal("concurrent release repopulated index")
	}
}

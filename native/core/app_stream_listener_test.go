package core

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestNativePlaybackReopensUnreachableLoopback(t *testing.T) {
	engine := &nativeEngine{downloader: &Downloader{}}
	choice := nativePlaybackChoices(providerMedia{
		URL: "https://fixture.invalid/index.m3u8", Playlist: "#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n",
	}, 0)
	before, err := engine.nativeOpenPlayback(context.Background(), choice)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = engine.stream.server.Close() })
	defer engine.nativeReleasePlayback(before.Session)
	previous := engine.stream.server
	if err := previous.Close(); err != nil {
		t.Fatal(err)
	}
	after, err := engine.nativeOpenPlayback(context.Background(), choice)
	if err != nil {
		t.Fatal(err)
	}
	defer engine.nativeReleasePlayback(after.Session)
	if previous == engine.stream.server {
		t.Fatal("new playback reused a closed loopback listener")
	}
	status, _, body := preloadTestGet(t, after.URL, "")
	parsed, _ := url.Parse(after.URL)
	if status != http.StatusOK || len(streamIndexURLs(string(body))) != 1 {
		t.Fatalf("recovered playlist failed: %d %s", status, body)
	}
	segment, _ := url.Parse(streamIndexURLs(string(body))[0])
	if segment.Host != parsed.Host {
		t.Fatalf("recovered playlist points to a different listener: %s", segment.Host)
	}
}

func TestNativeLoopbackConcurrentRecoveryAndCancellation(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	engine.downloader.trace.Store(true)
	choice := nativePlaybackChoices(providerMedia{URL: "https://fixture.invalid/video.mp4"}, 0)
	first, err := engine.nativeOpenPlayback(context.Background(), choice)
	if err != nil {
		t.Fatal(err)
	}
	defer engine.nativeReleasePlayback(first.Session)
	stream := engine.stream
	t.Cleanup(func() { _ = stream.server.Close() })
	previous := stream.server
	if err := stream.ensureLoopback(context.Background()); err != nil || stream.server != previous {
		t.Fatalf("healthy listener was replaced: %v", err)
	}
	_ = previous.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := stream.ensureLoopback(ctx); !errors.Is(err, context.Canceled) || stream.server != previous {
		t.Fatalf("cancelled probe replaced listener: %v", err)
	}
	if _, err := engine.nativeOpenPlayback(ctx, choice); !errors.Is(err, context.Canceled) || len(engine.playbacks) != 1 {
		t.Fatalf("cancelled open registered playback: %v", err)
	}

	const count = 6
	plans := make(chan nativePlan, count)
	errorsFound := make(chan error, count)
	var workers sync.WaitGroup
	for i := 0; i < count; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			plan, err := engine.nativeOpenPlayback(context.Background(), choice)
			if err != nil {
				errorsFound <- err
				return
			}
			plans <- plan
		}()
	}
	workers.Wait()
	close(plans)
	close(errorsFound)
	for err := range errorsFound {
		t.Error(err)
	}
	if len(plans) != count || stream.server == previous {
		t.Fatalf("recovery did not publish %d plans", count)
	}
	for plan := range plans {
		if !strings.HasPrefix(plan.URL, stream.address+"/") {
			t.Errorf("plan points to a different listener: %s", plan.URL)
		}
		engine.nativeReleasePlayback(plan.Session)
	}
	events, _ := streamDiagnosticEvents(t, stream)
	starts, failures := 0, 0
	for _, event := range events {
		if event.Event == "stream.listen_started" {
			starts++
		}
		if event.Event == "stream.listen_probe_failed" {
			failures++
		}
	}
	if starts != 2 || failures != 1 {
		t.Fatalf("parallel opens rebuilt listener repeatedly: starts=%d failed probes=%d", starts, failures)
	}
}

func TestNativeLoopbackSessionOriginAndMediaAfterRecovery(t *testing.T) {
	playlist := "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.key\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/child.m3u8":
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			_, _ = io.WriteString(w, playlist)
		case "/video.mp4":
			w.Header().Set("Content-Type", "video/mp4")
			http.ServeContent(w, r, "video.mp4", time.Time{}, strings.NewReader("0123456789"))
		default:
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = io.WriteString(w, "synthetic-media")
		}
	}))
	defer upstream.Close()
	engine, err := newNativeEngine(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	media := providerMedia{URL: upstream.URL + "/index.m3u8", Playlist: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild.m3u8\n#EXT-X-ENDLIST\n"}
	old, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(media, 0))
	if err != nil {
		t.Fatal(err)
	}
	defer engine.nativeReleasePlayback(old.Session)
	stream := engine.stream
	t.Cleanup(func() { _ = stream.server.Close() })
	oldToken := engine.playbacks[old.Session].streamSession
	oldSession := stream.sessions[oldToken]
	origin := oldSession.origin
	// 先绑定再关闭旧端口，保证不同端口，确定性验证旧会话不会漂移到新端口。
	stream.listenerMu.Lock()
	err = stream.startLoopback()
	stream.listenerMu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if origin == stream.address || oldSession.origin != origin {
		t.Fatal("old session origin changed with listener")
	}
	asset := nativeStreamAsset{address: upstream.URL + "/extra.ts"}
	if address := stream.nativeAsset(oldToken, oldSession, asset); !strings.HasPrefix(address, origin+"/") {
		t.Fatal("old session asset migrated to new listener")
	}
	body, release, err := stream.nativeRewrite(oldToken, oldSession, streamIndexID(old.URL), media.Playlist, media.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	for _, address := range streamIndexURLs(body) {
		if !strings.HasPrefix(address, origin+"/") {
			t.Fatal("old session playlist migrated to new listener")
		}
	}
	if size := stream.nativePrefetch(context.Background(), oldToken, old.URL, 0); size <= 0 {
		t.Fatal("in-flight old prefetch lost its own origin")
	}

	fresh, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(media, 0))
	if err != nil {
		t.Fatal(err)
	}
	defer engine.nativeReleasePlayback(fresh.Session)
	engine.nativeReleasePlayback(old.Session)
	status, _, master := preloadTestGet(t, fresh.URL, "")
	children := streamIndexURLs(string(master))
	if status != http.StatusOK || len(children) != 1 {
		t.Fatalf("new master failed after old release: %d %s", status, master)
	}
	status, _, child := preloadTestGet(t, children[0], "")
	assets := streamIndexURLs(string(child))
	if status != http.StatusOK || len(assets) != 3 {
		t.Fatalf("child/key/map/segment rewrite failed: %d %s", status, child)
	}
	for _, address := range assets {
		if !strings.HasPrefix(address, stream.address+"/") {
			t.Fatalf("new asset uses old origin: %s", address)
		}
		status, _, data := preloadTestGet(t, address, "")
		if status != http.StatusOK || string(data) != "synthetic-media" {
			t.Fatalf("new HLS asset unavailable: %d %q", status, data)
		}
	}
	mp4, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(providerMedia{URL: upstream.URL + "/video.mp4"}, 0))
	if err != nil {
		t.Fatal(err)
	}
	defer engine.nativeReleasePlayback(mp4.Session)
	status, _, data := preloadTestGet(t, mp4.URL, "bytes=2-5")
	if status != http.StatusPartialContent || string(data) != "2345" {
		t.Fatalf("MP4 range failed after recovery: %d %q", status, data)
	}
}

func TestNativePreloadListenerLifecycle(t *testing.T) {
	for _, mode := range []string{"healthy", "closed", "recovered", "cancelled_after_recovery"} {
		t.Run(mode, func(t *testing.T) {
			started, unblock := make(chan struct{}), make(chan struct{})
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/preload.mp4" {
					close(started)
					select {
					case <-unblock:
					case <-r.Context().Done():
						return
					}
				}
				w.Header().Set("Content-Type", "video/mp4")
				_, _ = io.WriteString(w, "synthetic-mp4")
			}))
			defer upstream.Close()
			defer func() {
				select {
				case <-unblock:
				default:
					close(unblock)
				}
			}()
			model := strings.ReplaceAll(hongguoFreshModel, "https://cdn.example.com/fresh.mp4", upstream.URL+"/preload.mp4")
			engine := sourceFixtureEngine(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == hongguoVideoTabPath {
					return sourceFixtureResponse(r, 200, hongguoTabFixture("2222", model)), nil
				}
				return upstream.Client().Transport.RoundTrip(r)
			})
			input := nativeInput{Drama: nativeDrama{ID: "hongguo:11", Source: sourceHongguo}, Chapter: Chapter{Source: sourceHongguo, VideoURL: "hongguo-cenc://2222"}, Index: 1, Force: true}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			type outcome struct {
				plan nativePlan
				err  error
			}
			done := make(chan outcome, 1)
			go func() { plan, err := engine.nativePreload(ctx, input); done <- outcome{plan, err} }()
			select {
			case <-started:
			case <-ctx.Done():
				t.Fatal("nativePreload did not reach blocked media upstream")
			}
			engine.mu.Lock()
			stream := engine.stream
			var oldPlan, oldToken string
			for token, choice := range engine.playbacks {
				oldPlan, oldToken = token, choice.streamSession
			}
			engine.mu.Unlock()
			defer func() { _ = stream.server.Close() }()
			defer engine.nativeReleasePlayback(oldPlan)
			stream.mu.Lock()
			oldSession := stream.sessions[oldToken]
			stream.mu.Unlock()
			if oldSession == nil {
				t.Fatal("preload did not register its stream session")
			}
			origin, previous := oldSession.origin, oldSession.listener
			if mode != "healthy" {
				if err := previous.Close(); err != nil {
					t.Fatal(err)
				}
			}
			var fresh nativePlan
			if mode == "recovered" || mode == "cancelled_after_recovery" {
				var err error
				fresh, err = engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(providerMedia{URL: upstream.URL + "/fresh.mp4"}, 0))
				if err != nil {
					t.Fatal(err)
				}
				defer engine.nativeReleasePlayback(fresh.Session)
				if stream.server == previous {
					t.Fatal("fresh playback did not rebuild the closed listener")
				}
			}
			current := stream.server
			if mode == "cancelled_after_recovery" {
				cancel()
			}
			close(unblock)
			var result outcome
			select {
			case result = <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("preload did not settle after releasing upstream")
			}
			if mode == "healthy" {
				if result.err != nil || result.plan.Session != oldPlan || result.plan.PrefetchedBytes != int64(len("synthetic-mp4")) {
					t.Fatalf("healthy preload failed: plan=%+v err=%v", result.plan, result.err)
				}
				// 关闭上游后仍可读取预取数据，证明正常路径保留了缓存和会话。
				upstream.Close()
				status, _, body := preloadTestGet(t, result.plan.URL, "")
				if status != http.StatusOK || string(body) != "synthetic-mp4" {
					t.Fatalf("healthy preloaded plan unavailable: %d %q", status, body)
				}
				return
			}
			wantErr := errNativePlaybackListener
			if mode == "cancelled_after_recovery" {
				wantErr = context.Canceled
			}
			if !errors.Is(result.err, wantErr) || result.plan.URL != "" || result.plan.Session != "" {
				t.Fatalf("obsolete preload returned a plan/wrong error: %+v, %v", result.plan, result.err)
			}
			engine.mu.Lock()
			_, retained := engine.playbacks[oldPlan]
			engine.mu.Unlock()
			stream.mu.Lock()
			_, streamRetained := stream.sessions[oldToken]
			stream.mu.Unlock()
			oldSession.cache.pool.mu.Lock()
			cached := oldSession.cache.used
			oldSession.cache.pool.mu.Unlock()
			if retained || streamRetained || oldSession.ctx.Err() == nil || cached != 0 {
				t.Fatalf("obsolete preload leaked ownership/cache: playback=%v stream=%v ctx=%v bytes=%d", retained, streamRetained, oldSession.ctx.Err(), cached)
			}
			if oldSession.origin != origin || oldSession.listener != previous || stream.server != current {
				t.Fatal("preload changed old origin/identity or rebuilt the listener again")
			}
			if fresh.Session != "" {
				status, _, body := preloadTestGet(t, fresh.URL, "")
				if status != http.StatusOK || string(body) != "synthetic-mp4" {
					t.Fatalf("old preload cleanup broke fresh playback: %d %q", status, body)
				}
			}
		})
	}
}

func TestNativePlaybackListenerIdentityNotJustOrigin(t *testing.T) {
	engine := &nativeEngine{downloader: &Downloader{}}
	plan, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(providerMedia{URL: "https://fixture.invalid/video.mp4"}, 0))
	if err != nil {
		t.Fatal(err)
	}
	defer engine.nativeReleasePlayback(plan.Session)
	defer engine.stream.server.Close()
	stream := engine.stream
	stream.mu.Lock()
	session := stream.sessions[engine.playbacks[plan.Session].streamSession]
	stream.mu.Unlock()
	// 合成同 origin、不同代的登记竞态：仅比较 URL/端口会错误接受此会话。
	session.listener = &http.Server{}
	if err := engine.nativeValidatePlayback(context.Background(), plan.Session); !errors.Is(err, errNativePlaybackListener) {
		t.Fatalf("accepted a different listener identity at the same origin: %v", err)
	}
}

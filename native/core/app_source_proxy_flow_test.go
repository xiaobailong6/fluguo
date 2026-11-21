package core

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
)

func TestSourceProxyNativeCatalogDetailResolveAndCover(t *testing.T) {
	var calls atomic.Int32
	engine := sourceFixtureEngine(t, func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		if got := r.Context().Value(proxySourceKey{}); got != sourceHongguo {
			t.Errorf("lost native operation source: %v", got)
		}
		return nil, errors.New("offline fixture stops request")
	})
	for _, operation := range []func(){
		func() {
			_, _ = engine.nativeCatalog(context.Background(), nativeInput{Source: "hongguoduanju.com", Force: true})
		},
		func() {
			_, _ = engine.nativeCatalog(context.Background(), nativeInput{Source: sourceHongguo, Query: "fixture"})
		},
		func() { _, _ = engine.nativeDetail(context.Background(), nativeDrama{ID: "hongguo:1001"}) },
		func() {
			_, _ = engine.downloader.resolveProviderMedia(context.Background(), Task{DramaID: "hongguo:1001", Chapter: Chapter{VideoURL: "hongguo-cenc://2222"}})
		},
		func() {
			_, _ = engine.covers.loadAddress(context.Background(), nativeDrama{ID: "hongguo:1001", Cover: "https://shared.invalid/cover.jpg"}, true)
		},
	} {
		before := calls.Load()
		operation()
		if calls.Load() == before {
			t.Fatal("operation did not reach controlled transport")
		}
	}
}

func TestSourceProxyPlaybackPrefetchAndCENC(t *testing.T) {
	for _, kind := range []string{"mp4", "hls", "cenc"} {
		t.Run(kind, func(t *testing.T) {
			var calls atomic.Int32
			d := sourceFixtureDownloader(t, func(r *http.Request) (*http.Response, error) {
				calls.Add(1)
				if r.Context().Value(proxySourceKey{}) != sourceHongguo {
					t.Errorf("lost stream source: %v", r.Context().Value(proxySourceKey{}))
				}
				if r.Header.Get("Cookie") != "fixture=secret" {
					t.Error("lost scoped credentials")
				}
				body, contentType := strings.Repeat("media", 200), "video/mp4"
				if strings.HasSuffix(r.URL.Path, ".m3u8") {
					body, contentType = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n", "application/vnd.apple.mpegurl"
				}
				if strings.HasSuffix(r.URL.Path, "key.bin") {
					body, contentType = "0123456789abcdef", "application/octet-stream"
				}
				response := sourceFixtureResponse(r, 200, body)
				response.Header.Set("Content-Type", contentType)
				return response, nil
			})
			engine := &nativeEngine{downloader: d}
			media := providerMedia{URL: "https://shared.invalid/media.mp4", credentials: &providerMediaCredentials{origin: "https://shared.invalid", cookie: "fixture=secret"}}
			if kind == "hls" {
				media.URL = "https://shared.invalid/index.m3u8"
			}
			if kind == "cenc" {
				media.CENCKey = []byte("0123456789abcdef")
			}
			choice := nativePlaybackChoices(media, 0)
			choice.source = sourceHongguo
			plan, err := engine.nativeOpenPlayback(context.Background(), choice)
			if err != nil {
				t.Fatal(err)
			}
			defer engine.stream.server.Close()
			defer engine.nativeReleasePlayback(plan.Session)
			stored := engine.playbacks[plan.Session]
			session := engine.stream.sessions[stored.streamSession]
			if session.source != sourceHongguo || !session.managed || session.ctx.Value(proxySourceKey{}) != sourceHongguo {
				t.Fatal("session lost source or ownership")
			}
			if kind == "cenc" && plan.Key == "" {
				t.Fatal("CENC key dropped")
			}
			// 即使预加载调用方错误地带另一来源，会话身份仍然是唯一权威。
			if n := engine.stream.nativePrefetch(withProxySource(context.Background(), "sorani"), stored.streamSession, plan.URL, 0); n == 0 {
				t.Fatal("prefetch did not cache fixture")
			}
			if calls.Load() < 1 {
				t.Fatal("missing upstream fetch")
			}
			// 清除预加载内容后走播放器 HTTP 路径，不能依赖请求本身的来源。
			entry, _ := url.Parse(plan.URL)
			session.cache.remove(strings.TrimPrefix(entry.Path, "/"+stored.streamSession+"/"))
			response, err := http.Get(plan.URL)
			if err != nil {
				t.Fatal(err)
			}
			_, _ = io.Copy(io.Discard, response.Body)
			response.Body.Close()
			if response.StatusCode != 200 {
				t.Fatal("stream failed", response.StatusCode)
			}
		})
	}
}

func TestSourceProxyDownloadUsesJobIdentity(t *testing.T) {
	for _, hls := range []bool{false, true} {
		manager := downloadTestManager(t)
		var calls atomic.Int32
		manager.engine.downloader.client.Transport = sourceFixtureTransport(func(r *http.Request) (*http.Response, error) {
			calls.Add(1)
			if r.Context().Value(proxySourceKey{}) != sourceHongguo {
				t.Errorf("download source=%v", r.Context().Value(proxySourceKey{}))
			}
			body, contentType := strings.Repeat("media", 100), "video/mp4"
			if strings.HasSuffix(r.URL.Path, ".m3u8") {
				body, contentType = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n", "application/vnd.apple.mpegurl"
			}
			if strings.HasSuffix(r.URL.Path, "key.bin") {
				body = "0123456789abcdef"
			}
			response := sourceFixtureResponse(r, 200, body)
			response.Header.Set("Content-Type", contentType)
			return response, nil
		})
		manager.resolve = func(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
			if ctx.Value(proxySourceKey{}) != sourceHongguo {
				t.Error("resolve lost job source")
			}
			if hls {
				return providerMedia{URL: "https://shared.invalid/index.m3u8"}, nil
			}
			return providerMedia{URL: "https://shared.invalid/movie.mp4", CENCKey: []byte("0123456789abcdef")}, nil
		}
		if _, err := manager.enqueue(downloadTestInput(1)); err != nil {
			t.Fatal(err)
		}
		waitDownloads(t, manager, func(jobs []nativeDownloadJob) bool { return len(jobs) == 1 && jobs[0].State == "converting" })
		if calls.Load() == 0 || hls && calls.Load() < 3 {
			t.Fatal("missing download media/key/playlist requests")
		}
		manager.close()
	}
}

func TestSourceProxyActualHTTPProxyAndRedirect(t *testing.T) {
	var calls atomic.Int32
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Host == "catalog.invalid" {
			w.Header().Set("Location", "http://shared.invalid/asset")
			w.WriteHeader(302)
			return
		}
		if r.URL.Host != "shared.invalid" {
			t.Error("unexpected request", r.URL)
		}
		_, _ = io.WriteString(w, "fixture")
	}))
	defer proxy.Close()
	address, _ := url.Parse(proxy.URL)
	router := &proxyRouter{mode: "direct", sources: map[string]proxyRoute{"hongguo": {mode: "manual", manual: address}}}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = router.proxy
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	r, _ := http.NewRequestWithContext(withProxySource(context.Background(), "hongguo"), http.MethodGet, "http://catalog.invalid/start", nil)
	response, err := client.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if calls.Load() != 2 {
		t.Fatal("redirect lost proxy source", calls.Load())
	}
}

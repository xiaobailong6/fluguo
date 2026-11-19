package core

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func pacTestRequest(t *testing.T, address string) *http.Request {
	t.Helper()
	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		t.Fatal(err)
	}
	return request
}

func TestProxyPACSuccess(t *testing.T) {
	for _, address := range []string{"http://pac-user:pac-pass@pac-proxy.test:8080", ""} {
		name := "proxy"
		var want *url.URL
		var bypass []string
		if address == "" {
			name = "DIRECT"
		} else {
			want, _ = url.Parse(address)
			bypass = []string{"*.test"}
		}
		t.Run(name, func(t *testing.T) {
			request := pacTestRequest(t, "https://video.test/watch")
			calls := 0
			router := &proxyRouter{
				systemOverride: true,
				system: nativeSystemProxy{PAC: true, PACURL: "http://pac.test/proxy.pac",
					HTTP: "http://static.test:8080", HTTPS: "http://static.test:8081", Bypass: bypass},
				pacResolver: func(script string, target *url.URL) (*url.URL, error) {
					calls++
					if script != "http://pac.test/proxy.pac" || target != request.URL {
						t.Errorf("wrong PAC inputs: %q %v", script, target)
					}
					return want, nil
				},
				record: func(event diagnosticEvent) { t.Errorf("successful PAC emitted %+v", event) },
			}
			got, err := router.proxy(request)
			if err != nil || got != want || calls != 1 || len(router.pacFailures) != 0 {
				t.Fatalf("PAC result=%v err=%v calls=%d failures=%d", got, err, calls, len(router.pacFailures))
			}
		})
	}
}

func TestProxyPACFailureFallback(t *testing.T) {
	for _, sample := range []struct {
		name, target, want string
		bypass             []string
	}{
		{"HTTP", "http://video.test/watch", "http://static-user:static-pass@static.test:8080", nil},
		{"HTTPS", "https://video.test/watch", "socks5://secure-user:secure-pass@secure.test:1080", nil},
		{"wildcard_bypass", "https://video.test/watch", "", []string{" *.test "}},
		{"local_bypass", "http://intranet/watch", "", []string{"<local>"}},
		{"local_IP_not_bypassed", "http://192.0.2.1/watch", "http://static-user:static-pass@static.test:8080", []string{"<local>"}},
	} {
		t.Run(sample.name, func(t *testing.T) {
			var events []diagnosticEvent
			calls := 0
			router := &proxyRouter{
				systemOverride: true,
				system: nativeSystemProxy{PAC: true, PACURL: "http://pac-user:pac-pass@pac.test/proxy.pac?token=pac-query",
					HTTP: "http://static-user:static-pass@static.test:8080", HTTPS: "socks5://secure-user:secure-pass@secure.test:1080", Bypass: sample.bypass},
				pacResolver: func(string, *url.URL) (*url.URL, error) {
					calls++
					return &url.URL{Scheme: "http", Host: "ignored.test:8080"}, errors.New("PAC resolution failed")
				},
				record: func(event diagnosticEvent) { events = append(events, event) },
			}
			got, err := router.proxy(pacTestRequest(t, sample.target))
			if err != nil || sample.want == "" && got != nil || sample.want != "" && (got == nil || got.String() != sample.want) {
				t.Fatalf("fallback=%v err=%v want=%q", got, err, sample.want)
			}
			if calls != 1 || len(events) != 1 || events[0].Event != "proxy.pac_failed" || events[0].Level != "warning" ||
				events[0].Host != pacTestRequest(t, sample.target).URL.Hostname() || !strings.Contains(events[0].Message, "PAC resolution failed") {
				t.Fatalf("calls=%d events=%+v", calls, events)
			}
			for _, secret := range []string{"static-user", "static-pass", "secure-user", "secure-pass", "pac-user", "pac-pass", "pac-query"} {
				if strings.Contains(events[0].Message, secret) {
					t.Fatalf("fallback diagnostic leaked %q", secret)
				}
			}
		})
	}
}

func TestProxyPACEnvironmentFallback(t *testing.T) {
	// net/http 会全局缓存代理环境变量；用独立子进程验证，避免依赖测试顺序或重置私有全局变量。
	if scenario := os.Getenv("FLUGUO_PAC_ENV_TEST"); scenario != "" {
		var events []diagnosticEvent
		calls := 0
		router := &proxyRouter{
			systemOverride: true,
			system:         nativeSystemProxy{PAC: true, PACURL: "http://pac.test/proxy.pac"},
			pacResolver: func(string, *url.URL) (*url.URL, error) {
				calls++
				return nil, errors.New("PAC unavailable")
			},
			record: func(event diagnosticEvent) { events = append(events, event) },
		}
		for _, scheme := range []string{"http", "https"} {
			got, err := router.proxy(pacTestRequest(t, scheme+"://video.test/watch"))
			want := ""
			if scenario == "proxy" {
				want = os.Getenv(strings.ToUpper(scheme) + "_PROXY")
			}
			if err != nil || want == "" && got != nil || want != "" && (got == nil || got.String() != want) {
				t.Fatalf("%s fallback=%v err=%v want=%q", scheme, got, err, want)
			}
		}
		if calls != 2 || len(events) != 1 {
			t.Fatalf("calls=%d diagnostics=%+v", calls, events)
		}
		if strings.Contains(events[0].Message, "env-user") || strings.Contains(events[0].Message, "env-pass") {
			t.Fatal("environment proxy credentials leaked")
		}
		return
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, scenario := range []string{"proxy", "direct", "no_proxy"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, executable, "-test.run=^TestProxyPACEnvironmentFallback$", "-test.count=1")
			for _, entry := range os.Environ() {
				name, _, _ := strings.Cut(entry, "=")
				switch strings.ToUpper(name) {
				case "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "REQUEST_METHOD", "FLUGUO_PAC_ENV_TEST":
					continue
				}
				command.Env = append(command.Env, entry)
			}
			command.Env = append(command.Env, "FLUGUO_PAC_ENV_TEST="+scenario)
			if scenario != "direct" {
				command.Env = append(command.Env, "HTTP_PROXY=http://env-user:env-pass@env.test:8080", "HTTPS_PROXY=http://env-user:env-pass@env.test:8081")
			}
			if scenario == "no_proxy" {
				command.Env = append(command.Env, "NO_PROXY=video.test")
			}
			if output, err := command.CombinedOutput(); err != nil {
				t.Fatalf("environment fallback subprocess: %v\n%s", err, output)
			}
		})
	}
}

func TestProxyPACSkippedModesAndLoopback(t *testing.T) {
	for _, sample := range []struct {
		name, mode, target, want string
	}{
		{"direct", "direct", "https://video.test/watch", ""},
		{"manual", "manual", "https://video.test/watch", "http://manual.test:8080"},
		{"IPv4_loopback", "auto", "http://127.0.0.1/watch", ""},
		{"localhost", "auto", "http://localhost/watch", ""},
		{"IPv6_loopback", "auto", "http://[::1]/watch", ""},
	} {
		t.Run(sample.name, func(t *testing.T) {
			manual, _ := url.Parse("http://manual.test:8080")
			router := &proxyRouter{
				mode: sample.mode, manual: manual, systemOverride: true,
				system: nativeSystemProxy{PAC: true, PACURL: "http://pac.test/proxy.pac"},
				pacResolver: func(string, *url.URL) (*url.URL, error) {
					t.Error("PAC should not be called")
					return nil, errors.New("unexpected PAC call")
				},
				record: func(event diagnosticEvent) { t.Errorf("unexpected diagnostic: %+v", event) },
			}
			got, err := router.proxy(pacTestRequest(t, sample.target))
			if err != nil || sample.want == "" && got != nil || sample.want != "" && (got == nil || got.String() != sample.want) {
				t.Fatalf("proxy=%v err=%v want=%q", got, err, sample.want)
			}
		})
	}
}

func TestProxyPACMissingScript(t *testing.T) {
	router := &proxyRouter{
		systemOverride: true,
		system:         nativeSystemProxy{PAC: true},
		pacResolver: func(string, *url.URL) (*url.URL, error) {
			t.Error("empty script should not invoke resolver")
			return nil, nil
		},
		record: func(event diagnosticEvent) { t.Errorf("unexpected diagnostic: %+v", event) },
	}
	request := pacTestRequest(t, "https://video.test/watch")
	if got, err := router.proxy(request); got != nil || err == nil {
		t.Fatalf("missing-script failure changed: %v %v", got, err)
	}
	router.system.HTTPS = "http://static.test:8080"
	if got, err := router.proxy(request); err != nil || got == nil || got.String() != router.system.HTTPS {
		t.Fatalf("static fallback without script changed: %v %v", got, err)
	}
}

func TestProxyPACFailureDedupWindow(t *testing.T) {
	base := time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC)
	current := base
	var events []diagnosticEvent
	router := &proxyRouter{
		pacNow: func() time.Time { return current },
		record: func(event diagnosticEvent) { events = append(events, event) },
	}
	for _, sample := range []struct {
		at      time.Duration
		host    string
		message string
		count   int
	}{
		{0, "first.test", "error A", 1},
		{0, "second.test", "error A", 1},
		{0, "first.test", "error B", 2},
		{5*time.Minute - time.Nanosecond, "first.test", "error A", 2},
		{5 * time.Minute, "second.test", "error A", 3},
		{5 * time.Minute, "third.test", "error A", 3},
		{10*time.Minute - time.Nanosecond, "first.test", "error A", 3},
		{10 * time.Minute, "first.test", "error A", 4},
	} {
		current = base.Add(sample.at)
		router.reportPACFailure(sample.host, errors.New(sample.message))
		if len(events) != sample.count {
			t.Fatalf("at=%v message=%q events=%d want=%d", sample.at, sample.message, len(events), sample.count)
		}
	}
	if len(router.pacFailures) != 2 {
		t.Fatalf("unexpected cache size: %d", len(router.pacFailures))
	}
}

func TestProxyPACFailureCacheBound(t *testing.T) {
	current := time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC)
	count := 0
	router := &proxyRouter{pacNow: func() time.Time { return current }, record: func(diagnosticEvent) { count++ }}
	for index := 0; index < 64; index++ {
		current = current.Add(time.Second)
		router.reportPACFailure("video.test", fmt.Errorf("error %d", index))
	}
	// 满额时重复或到期重报现有键都不应清空其他仍在窗口内的错误。
	router.reportPACFailure("other.test", errors.New("error 63"))
	if count != 64 || len(router.pacFailures) != 64 {
		t.Fatalf("full-cache dedup count=%d size=%d", count, len(router.pacFailures))
	}
	current = current.Add(time.Second)
	router.reportPACFailure("video.test", errors.New("error 64"))
	if count != 65 || len(router.pacFailures) != 64 {
		t.Fatalf("overflow count=%d size=%d", count, len(router.pacFailures))
	}
	if _, exists := router.pacFailures[sha256.Sum256([]byte("error 0"))]; exists {
		t.Fatal("oldest error was not evicted")
	}
	for index := 1; index <= 64; index++ {
		router.reportPACFailure("other.test", fmt.Errorf("error %d", index))
	}
	if count != 65 {
		t.Fatal("overflow lost retained dedup entries")
	}
	current = current.Add(5 * time.Minute)
	router.reportPACFailure("video.test", errors.New("error 64"))
	if count != 66 || len(router.pacFailures) != 64 {
		t.Fatalf("expired existing entry count=%d size=%d", count, len(router.pacFailures))
	}
	for index := 65; index < 512; index++ {
		current = current.Add(time.Second)
		router.reportPACFailure("video.test", fmt.Errorf("error %d", index))
		if len(router.pacFailures) != 64 {
			t.Fatalf("cache not bounded at error %d: %d", index, len(router.pacFailures))
		}
	}
}

func TestProxyPACFailureNilRecorder(t *testing.T) {
	router := &proxyRouter{
		systemOverride: true,
		system:         nativeSystemProxy{PAC: true, PACURL: "http://pac.test/proxy.pac", HTTPS: "http://static.test:8080"},
		pacResolver: func(string, *url.URL) (*url.URL, error) {
			return nil, errors.New("PAC failed")
		},
	}
	if got, err := router.proxy(pacTestRequest(t, "https://video.test/watch")); err != nil || got == nil || got.String() != router.system.HTTPS {
		t.Fatalf("nil recorder changed fallback: %v %v", got, err)
	}
	router.reportPACFailure("video.test", nil)
	if len(router.pacFailures) != 0 {
		t.Fatal("unrecorded errors occupied cache")
	}
	count := 0
	router.record = func(diagnosticEvent) { count++ }
	router.reportPACFailure("video.test", errors.New("PAC failed"))
	if count != 1 {
		t.Fatal("nil recorder suppressed a later real diagnostic")
	}
}

func TestProxyPACFailureConcurrentDedup(t *testing.T) {
	var records, calls atomic.Int32
	current := time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC)
	router := &proxyRouter{
		systemOverride: true,
		system:         nativeSystemProxy{PAC: true, PACURL: "http://pac.test/proxy.pac", HTTPS: "http://static.test:8080"},
		pacResolver: func(string, *url.URL) (*url.URL, error) {
			calls.Add(1)
			return nil, errors.New("concurrent PAC failure")
		},
		pacNow: func() time.Time { return current },
		record: func(diagnosticEvent) { records.Add(1) },
	}
	request := pacTestRequest(t, "https://video.test/watch")
	var workers sync.WaitGroup
	start := make(chan struct{})
	for index := 0; index < 128; index++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			if got, err := router.proxy(request); err != nil || got == nil || got.String() != "http://static.test:8080" {
				t.Errorf("concurrent fallback: %v %v", got, err)
			}
		}()
	}
	close(start)
	workers.Wait()
	if records.Load() != 1 || calls.Load() != 128 || len(router.pacFailures) != 1 {
		t.Fatalf("records=%d resolver calls=%d cache=%d", records.Load(), calls.Load(), len(router.pacFailures))
	}
	for index := 0; index < 128; index++ {
		workers.Add(1)
		go func(index int) {
			defer workers.Done()
			router.reportPACFailure("video.test", fmt.Errorf("distinct failure %d", index))
		}(index)
	}
	workers.Wait()
	if records.Load() != 129 || len(router.pacFailures) != 64 {
		t.Fatalf("distinct concurrent records=%d cache=%d", records.Load(), len(router.pacFailures))
	}
}

func TestProxyPACFailureRecorderOutsideLock(t *testing.T) {
	router := &proxyRouter{systemOverride: true}
	var records atomic.Int32
	router.record = func(diagnosticEvent) {
		records.Add(1)
		if !router.mu.TryLock() {
			t.Error("diagnostic callback ran under router lock")
			return
		}
		router.mu.Unlock()
		// 重入去重和系统设置读取都必须安全，并且回调前已登记当前错误。
		router.reportPACFailure("reentrant.test", errors.New("outer failure"))
		_ = router.systemSettings()
	}
	router.reportPACFailure("video.test", errors.New("outer failure"))
	if records.Load() != 1 {
		t.Fatalf("reentrant callback recorded %d events", records.Load())
	}
}

func TestProxyPACFailureRedaction(t *testing.T) {
	var events []diagnosticEvent
	router := &proxyRouter{
		systemOverride: true,
		system:         nativeSystemProxy{PAC: true, PACURL: "http://script-user:script-pass@pac.test/proxy.pac?token=script-query#script-fragment", HTTPS: "http://static.test:8080"},
		pacResolver: func(script string, target *url.URL) (*url.URL, error) {
			return nil, fmt.Errorf("PAC fetch %s target %s proxy socks5h://proxy-user:proxy-pass@proxy.test:1080?password=proxy-query#proxy-fragment malformed http://%%zz/invalid-secret", script, target)
		},
		record: func(event diagnosticEvent) { events = append(events, event) },
	}
	request := pacTestRequest(t, "https://target-user:target-pass@video.test:8443/watch?token=target-query#target-fragment")
	if _, err := router.proxy(request); err != nil {
		t.Fatal(err)
	}
	// 脱敏后相同的不同原始错误仍分别计数，而完全相同的错误跨 host 去重。
	for _, query := range []string{"first-secret", "second-secret", "first-secret"} {
		router.reportPACFailure("other.test", fmt.Errorf("fetch https://pac.test/proxy.pac?token=%s", query))
	}
	if len(events) != 3 || events[0].Host != "video.test" || events[1].Message != events[2].Message {
		t.Fatalf("unexpected redacted events: %+v", events)
	}
	data, err := json.Marshal(events)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{
		"script-user", "script-pass", "script-query", "script-fragment", "target-user", "target-pass", "target-query", "target-fragment",
		"proxy-user", "proxy-pass", "proxy-query", "proxy-fragment", "invalid-secret", "first-secret", "second-secret",
	} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("PAC diagnostic leaked %q", secret)
		}
	}
	for _, marker := range []string{"redacted", "pac.test", "proxy.test", "无效 URL 已隐藏"} {
		if !strings.Contains(string(data), marker) {
			t.Fatalf("missing existing redaction marker %q", marker)
		}
	}
}

func TestProxyPACDiagnosticsWiring(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	d := engine.downloader
	t.Cleanup(d.client.CloseIdleConnections)
	d.cfg.Token, d.cfg.AESKeyHex = "configured-token", "configured-aes-key"
	d.cfg.InterfaceKey, d.cfg.ParamKey, d.cfg.ParamIV = "configured-interface-key", "configured-param-key", "configured-param-iv"
	router := d.proxyRouter
	router.mu.Lock()
	router.mode = "auto"
	router.systemOverride = true
	router.system = nativeSystemProxy{PAC: true, PACURL: "http://script-user:script-pass@pac.test/proxy.pac?token=script-secret", HTTPS: "http://static-user:static-pass@static.test:8080"}
	router.pacResolver = func(script string, target *url.URL) (*url.URL, error) {
		return nil, fmt.Errorf("fetch %s for %s: %s %s %s %s %s", script, target, d.cfg.Token, d.cfg.AESKeyHex, d.cfg.InterfaceKey, d.cfg.ParamKey, d.cfg.ParamIV)
	}
	router.mu.Unlock()
	request := pacTestRequest(t, "https://target-user:target-pass@configured-token.video.test:8443/watch?key=target-secret")
	for index := 0; index < 2; index++ {
		if got, err := router.proxy(request); err != nil || got == nil || got.String() != "http://static-user:static-pass@static.test:8080" {
			t.Fatalf("engine fallback=%v err=%v", got, err)
		}
	}
	data, err := os.ReadFile(d.diagnostics.path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	var event diagnosticEvent
	if len(lines) != 1 || json.Unmarshal([]byte(lines[0]), &event) != nil {
		t.Fatalf("expected one persisted PAC warning: %s", data)
	}
	if event.Event != "proxy.pac_failed" || event.Level != "warning" || event.Host != "[redacted].video.test" || event.Time.IsZero() {
		t.Fatalf("wrong persisted event: %+v", event)
	}
	for _, secret := range []string{d.cfg.Token, d.cfg.AESKeyHex, d.cfg.InterfaceKey, d.cfg.ParamKey, d.cfg.ParamIV,
		"script-user", "script-pass", "script-secret", "target-user", "target-pass", "target-secret", "static-user", "static-pass"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("persisted warning exposed %q", secret)
		}
	}
}

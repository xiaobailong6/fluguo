package core

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func sourceProxyTestEngine(t *testing.T) *nativeEngine {
	t.Helper()
	return &nativeEngine{directory: t.TempDir(), downloader: &Downloader{client: &http.Client{}, proxyRouter: &proxyRouter{}, limiter: newRequestLimiter(3, 0)}}
}

func sourceProxyAddress(t *testing.T, router *proxyRouter, source, target string) string {
	t.Helper()
	r, err := http.NewRequestWithContext(withProxySource(context.Background(), source), http.MethodGet, target, nil)
	if err != nil {
		t.Fatal(err)
	}
	proxy, err := router.proxy(r)
	if err != nil {
		t.Fatal(err)
	}
	if proxy == nil {
		return ""
	}
	return proxy.String()
}

func TestSourceProxyRoutesInheritanceGroupsAndPAC(t *testing.T) {
	engine := sourceProxyTestEngine(t)
	settings := defaultResourceSettings()
	settings.ProxyMode, settings.ProxyURL = "manual", "http://global.invalid:7890"
	settings.CatalogIntervalMS, settings.TraceEnabled = 721, true
	settings.SourceProxies = map[string]nativeSourceProxy{
		"huangguo": {Mode: "manual", URL: "socks5://group.invalid:1080"},
		"hongguo":  {Mode: "direct"}, "sorani": {Mode: "auto"},
	}
	if err := settings.validate(); err != nil {
		t.Fatal(err)
	}
	router := engine.downloader.proxyRouter
	router.systemOverride = true
	router.system = nativeSystemProxy{PAC: true, PACURL: "http://pac.invalid/script"}
	pacCalls := 0
	router.pacResolver = func(string, *url.URL) (*url.URL, error) { pacCalls++; return url.Parse("http://system.invalid:7891") }
	engine.applyResourceSettings(settings)
	for _, source := range []string{"huangguo", "huangguoai", "huangguo.video", "cloudfront", " HUANGGUOAI.COM "} {
		if got := sourceProxyAddress(t, router, source, "https://shared-cdn.invalid/media"); got != "socks5://group.invalid:1080" {
			t.Fatalf("%s: %s", source, got)
		}
	}
	for source, want := range map[string]string{"hongguoduanju.com": "", "sorani": "http://system.invalid:7891", "": settings.ProxyURL, "unknown": settings.ProxyURL} {
		if got := sourceProxyAddress(t, router, source, "https://shared-cdn.invalid/media"); got != want {
			t.Fatalf("%s: %s want %s", source, got, want)
		}
	}
	if pacCalls != 1 || engine.downloader.limiter.interval != 721*time.Millisecond || !engine.downloader.trace.Load() {
		t.Fatal("lost PAC, interval or diagnostics")
	}
	for _, host := range []string{"127.0.0.1", "127.3.2.1", "localhost", "LOCALHOST.", "[::1]", "[::ffff:127.0.0.2]"} {
		if got := sourceProxyAddress(t, router, "huangguoai", "http://"+host+":9876/media"); got != "" {
			t.Fatal("loopback proxied", host)
		}
	}
	delete(settings.SourceProxies, "huangguo")
	engine.applyResourceSettings(settings)
	if got := sourceProxyAddress(t, router, "cloudfront", "https://shared-cdn.invalid/media"); got != settings.ProxyURL {
		t.Fatal("removed override did not inherit", got)
	}
}

func TestSourceProxyValidationMigrationAndIsolation(t *testing.T) {
	for _, proxy := range []nativeSourceProxy{{Mode: "follow"}, {Mode: "manual"}, {Mode: "manual", URL: "ftp://proxy.invalid"}, {Mode: "manual", URL: "http://proxy.invalid:0"}, {Mode: "manual", URL: "http://proxy.invalid:65536"}, {Mode: "manual", URL: "http://proxy.invalid?"}, {Mode: "manual", URL: "http://proxy.invalid/path"}, {Mode: "manual", URL: "http://" + strings.Repeat("x", 2048)}} {
		settings := defaultResourceSettings()
		settings.SourceProxies = map[string]nativeSourceProxy{"hongguo": proxy}
		if settings.validate() == nil {
			t.Fatalf("accepted proxy %+v", proxy)
		}
	}
	for _, group := range []string{"", "unknown", "../hongguo", "hongguo\n", strings.Repeat("x", 65)} {
		settings := defaultResourceSettings()
		settings.SourceProxies = map[string]nativeSourceProxy{group: {Mode: "direct"}}
		if settings.validate() == nil {
			t.Fatalf("accepted group %q", group)
		}
	}
	settings := defaultResourceSettings()
	settings.SourceProxies = map[string]nativeSourceProxy{}
	for i := 0; i < 201; i++ {
		settings.SourceProxies[fmt.Sprint(i)] = nativeSourceProxy{Mode: "auto"}
	}
	if normalizeSourceProxies(&settings) == nil {
		t.Fatal("accepted too many entries")
	}
	engine := sourceProxyTestEngine(t)
	file := filepath.Join(engine.directory, "resource-settings.json")
	legacy := `{"proxyMode":"direct","catalogConcurrency":4,"catalogIntervalMs":0,"downloadConcurrency":5,"traceEnabled":true,"sourceProxies":{"huangguo.video":{"mode":"manual","url":" http://proxy.invalid:7890 "},"cloudfront":{"mode":"manual","url":"http://proxy.invalid:7890"}}}`
	if err := os.WriteFile(file, []byte(legacy), 0600); err != nil {
		t.Fatal(err)
	}
	engine.loadResourceSettings()
	loaded := engine.resourceSettings()
	if loaded.Warning != "" || len(loaded.SourceProxies) != 1 || loaded.SourceProxies["huangguo"].URL != "http://proxy.invalid:7890" || loaded.CatalogIntervalMS != 0 || !loaded.TraceEnabled {
		t.Fatalf("migration failed: %+v", loaded)
	}
	saved, err := engine.saveResourceSettings(loaded)
	if err != nil {
		t.Fatal(err)
	}
	loaded.SourceProxies["hongguo"] = nativeSourceProxy{Mode: "direct"}
	saved.SourceProxies["hongguo"] = nativeSourceProxy{Mode: "auto"}
	if len(engine.resourceSettings().SourceProxies) != 1 {
		t.Fatal("caller mutated stored settings")
	}
	conflict := defaultResourceSettings()
	conflict.SourceProxies = map[string]nativeSourceProxy{"huangguo": {Mode: "direct"}, "cloudfront": {Mode: "auto"}}
	before, _ := os.ReadFile(file)
	if _, err := engine.saveResourceSettings(conflict); err == nil {
		t.Fatal("conflicting migration accepted")
	}
	after, _ := os.ReadFile(file)
	if string(before) != string(after) {
		t.Fatal("invalid save overwrote config")
	}
	if err := os.WriteFile(file, []byte(`{"proxyMode":"direct"}`), 0600); err != nil {
		t.Fatal(err)
	}
	engine.loadResourceSettings()
	if got := engine.resourceSettings(); got.CatalogIntervalMS != 250 || got.ProxyMode != "direct" || len(got.SourceProxies) != 0 {
		t.Fatal("legacy defaults lost", got)
	}
	if err := os.WriteFile(file, []byte(strings.Repeat(" ", maxResourceSettingsBytes+1)), 0600); err != nil {
		t.Fatal(err)
	}
	engine.loadResourceSettings()
	if engine.resourceSettings().Warning == "" {
		t.Fatal("oversized config accepted")
	}
}

func TestSourceProxyConcurrentApplyAndRead(t *testing.T) {
	engine := sourceProxyTestEngine(t)
	settings := defaultResourceSettings()
	settings.SourceProxies = map[string]nativeSourceProxy{"hongguo": {Mode: "direct"}}
	engine.applyResourceSettings(settings)
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < 100; n++ {
				engine.applyResourceSettings(settings)
				sourceProxyAddress(t, engine.downloader.proxyRouter, "hongguo", "https://cdn.invalid/test")
			}
		}()
	}
	wg.Wait()
	if _, err := json.Marshal(settings); err != nil {
		t.Fatal(err)
	}
}

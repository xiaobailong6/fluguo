package core

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

func TestImportedSourceRegistration(t *testing.T) {
	previous := buildAllSources
	defer func() { buildAllSources = previous }()
	for source, spec := range importedSites {
		if !isHuangguoProviderSource(source) || providerSourceForURL(spec.Base+"/detail") != source || !validNativeCategory(source, "") {
			t.Fatalf("incomplete registration: %s", source)
		}
		buildAllSources = "false"
		if nativeSourceAvailable(source) {
			t.Fatalf("restricted build leaked %s", source)
		}
		buildAllSources = "true"
		if !nativeSourceAvailable(source) {
			t.Fatalf("full build missing %s", source)
		}
	}
	if isImportedSource(sourceHongguo) || isImportedSource("wuguo") || isImportedSource("heguo") {
		t.Fatal("existing or failed source registered")
	}
	if importedAbsolute("https://example.test", "") != "" {
		t.Fatal("empty cover became site URL")
	}
	if validImportedCategory("shuangguo", "都市") || !validImportedCategory("shuangguo", "现代都市") {
		t.Fatal("invalid site categories")
	}
}

func TestImportedWebCatalog(t *testing.T) {
	body := `<a href="/vod/12.html" title="测试剧"><img data-original="/cover.jpg"></a><a href="/vod/12.html">测试剧</a><a href="/vod/13.html" title="第二部">第二部</a>`
	items := parseImportedWebCatalog("shuangguo", body)
	if len(items) != 2 || items[0].SourceID != "12" || items[0].Title != "测试剧" || nativeText(items[0].Cover) != "https://www.duanju2.com/cover.jpg" {
		t.Fatalf("items=%+v", items)
	}
}

func TestImportedJSONObject(t *testing.T) {
	body := `var player_aaaa={"vod_data":{"name":"a}b"},"url":"https://example.test/live.m3u8?token=a+b","encrypt":0}; other={};`
	location := importedPlayerStart.FindStringIndex(body)
	data := importedJSONObject(body, location[1])
	if importedText(data, "url") != "https://example.test/live.m3u8?token=a+b" {
		t.Fatalf("data=%+v", data)
	}
	if importedJSONObject("{broken", 0) != nil {
		t.Fatal("invalid JSON accepted")
	}
}

// 跟随 HLS 子清单到真实分片；只下载有限前缀，不访问任何封面。
func verifyImportedMedia(ctx context.Context, address, referer string, depth int) (string, error) {
	if depth > 4 {
		return "", fmt.Errorf("too many HLS levels")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("Referer", referer)
	request.Header.Set("Range", "bytes=0-65535")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	prefix, err := io.ReadAll(io.LimitReader(response.Body, 65536))
	if err != nil {
		return "", err
	}
	if response.StatusCode != 200 && response.StatusCode != 206 {
		return "", fmt.Errorf("media HTTP %d", response.StatusCode)
	}
	if bytes.HasPrefix(bytes.TrimSpace(prefix), []byte("#EXTM3U")) {
		for _, line := range strings.Split(string(prefix), "\n") {
			line = strings.TrimSpace(line)
			// CMAF 的初始化分片同样必须可访问。
			if strings.HasPrefix(line, "#EXT-X-MAP:") {
				if _, rest, ok := strings.Cut(line, `URI="`); ok {
					line, _, _ = strings.Cut(rest, `"`)
				}
			}
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			base := response.Request.URL
			child, err := url.Parse(line)
			if err != nil {
				return "", err
			}
			result, err := verifyImportedMedia(ctx, base.ResolveReference(child).String(), referer, depth+1)
			return "HLS -> " + result, err
		}
		return "", fmt.Errorf("HLS has no playable segment")
	}
	mp4 := len(prefix) >= 8 && (string(prefix[4:8]) == "ftyp" || string(prefix[4:8]) == "styp")
	ts := len(prefix) > 376 && prefix[0] == 0x47 && prefix[188] == 0x47 && prefix[376] == 0x47
	if !mp4 && !ts {
		return "", fmt.Errorf("unrecognized media prefix (%s): %x", response.Header.Get("Content-Type"), prefix[:min(32, len(prefix))])
	}
	return fmt.Sprintf("HTTP %d bytes=%d type=%s", response.StatusCode, len(prefix), response.Header.Get("Content-Type")), nil
}

// 显式启用真实网络验证，普通单元测试不依赖站点在线。
func TestImportedSourcesLive(t *testing.T) {
	if os.Getenv("VERIFY_IMPORTED_SOURCES") != "1" {
		t.Skip("set VERIFY_IMPORTED_SOURCES=1")
	}
	for _, source := range []string{"fanguo", "shuangguo"} {
		t.Run(source, func(t *testing.T) {
			engine, err := newNativeEngine(t.TempDir(), "")
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
			defer cancel()
			items, _, err := engine.downloader.importedCatalog(ctx, source, 1, "", "")
			if err != nil || len(items) == 0 {
				t.Fatalf("catalog count=%d error=%v", len(items), err)
			}
			t.Logf("catalog=%d first=%s", len(items), items[0].SourceID)
			if source == "shuangguo" {
				next, _, err := engine.downloader.importedCatalog(ctx, source, 2, "", "")
				if err != nil || len(next) == 0 || next[0].ID == items[0].ID {
					t.Fatalf("pagination not verified: %v", err)
				}
				category, _, err := engine.downloader.importedCatalog(ctx, source, 1, "现代都市", "")
				if err != nil || len(category) == 0 {
					t.Fatalf("category not verified: %v", err)
				}
				t.Logf("page2=%d category=%d", len(next), len(category))
			}
			var lastErr error
			for _, item := range items[:min(3, len(items))] {
				drama, chapters, err := engine.downloader.importedDetail(ctx, source, item.SourceID)
				if err != nil || len(chapters) == 0 {
					lastErr = err
					continue
				}
				media, err := engine.downloader.resolveImportedMedia(ctx, Task{DramaID: drama.ID, Chapter: chapters[0], Index: 1})
				if err != nil {
					lastErr = err
					continue
				}
				result, err := verifyImportedMedia(ctx, media.URL, media.Referer, 0)
				if err != nil {
					lastErr = err
					continue
				}
				t.Logf("PASS title=%s episodes=%d %s", drama.Title, len(chapters), result)
				return
			}
			t.Fatalf("no verified playback among first candidates: %v", lastErr)
		})
	}
}
